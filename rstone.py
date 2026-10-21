#!/usr/bin/env python3
"""rstone: real-time Rocksmith 2014 (macOS) tone changes.

How it works:
  1. rsprobe (started here) reads the game's memory, read-only and data only.
  2. The selected arrangement is the one whose description object exists twice in memory.
  3. The song timer is found automatically: a value advancing 1 s per second while playing.
     When several candidates survive, the game's own tone banner ("<Song> - <Tone>") at the
     first tone change picks the one that matches the song file's timeline.
  4. The tone at the current song time comes from the arrangement's timeline (tones_index.jsonl).

Each tone change prints one JSON line (and optionally sends it over UDP):
  {"event": "tone", "song": "18 And Life", "arrangement": "skid18an_lead", "slot": "B",
   "tone": "skid18an_dist", "descriptors": ["DISTORTION"], "preset": "Distortion", "time": 41.1}

Usage: rstone.py [--udp HOST:PORT] [--lead-ms N] [--log FILE]
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

import paths
from presets import Presets

HERE = paths.ROOT
SOCK = "/tmp/rsprobe.sock"
SLOTS = ["Base", "A", "B", "C", "D"]

# Values tied to this Rocksmith build (unslid addresses in its x86_64 image): game_profile.json.
PROFILE = paths.game_profile()
IMAGE_BASE = PROFILE["image_base"]
ARRANGEMENT_VTABLE = PROFILE["arrangement_vtable"]  # arrangement description objects
ARR_NAME, ARR_TONES = PROFILE["arrangement_name_offset"], PROFILE["arrangement_tones_offset"]
ARR_STRIDE = PROFILE["arrangement_tone_stride"]  # 32-byte small-buffer strings, slots Base..D

TIMER_FORMATS = {"f32": ("<f", 4, 1.0), "f64": ("<d", 8, 1.0), "i32ms": ("<i", 4, 0.001),
                 "f32ms": ("<f", 4, 0.001), "f64ms": ("<d", 8, 0.001)}


# ---------------------------------------------------------------- rsprobe connection

def send(line, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(line.encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        part = s.recv(65536)
        if not part:
            break
        data += part
    s.close()
    return data.decode(errors="replace")


def read(addr, n):
    out = b""
    while len(out) < n:
        k = min(2000, n - len(out))
        h = send(f"read {addr + len(out):x} {k}").strip()
        if not h or h == "err":
            return None
        out += bytes.fromhex(h)
    return out


def q(addr):
    b = read(addr, 8)
    return struct.unpack("<Q", b)[0] if b else 0


def sso(addr):
    """Read a 32-byte small-buffer string {char buf[16] | char *ptr, char *end, char *cap}."""
    b = read(addr, 32)
    if not b:
        return ""
    end = struct.unpack_from("<Q", b, 16)[0]
    p = addr if addr <= end <= addr + 16 else struct.unpack_from("<Q", b, 0)[0]
    if not 0 <= end - p < 256:
        return ""
    s = read(p, end - p) if end > p else b""
    return (s or b"").decode(errors="replace")


# ---------------------------------------------------------------- game process

PROCESS = "Rocksmith2014"


def game_pid():
    r = subprocess.run(["pgrep", "-x", PROCESS], capture_output=True, text=True)
    return int(r.stdout.split()[0]) if r.stdout.strip() else None


class Probe:
    """Keeps rsprobe attached to the running game."""

    def __init__(self, log):
        self.pid, self.proc, self.log = None, None, log

    def ensure(self):
        pid = game_pid()
        if pid is None:
            return False
        if pid != self.pid or self.proc is None or self.proc.poll() is not None:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                self.proc.wait()
            subprocess.run(["pkill", "-f", paths.RSPROBE])  # a reader left over from a crashed run
            self.proc = subprocess.Popen([paths.RSPROBE, str(pid)],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(50):
                try:
                    if send("ping").startswith("pong"):
                        break
                except OSError:
                    time.sleep(0.1)
            self.pid = pid
            self.log(f"attached to Rocksmith pid {pid}")
            return "new"
        return True


def find_slide():
    for a in range(IMAGE_BASE, IMAGE_BASE + 0x10000000, 0x1000):
        b = read(a, 16)
        if b and struct.unpack_from("<I", b)[0] == 0xFEEDFACF and struct.unpack_from("<I", b, 12)[0] == 2:
            return a - IMAGE_BASE
    return None


def current_arrangement(slide):
    """Name and tone slots of the selected arrangement (its description object exists twice)."""
    hits = [int(h, 16) for h in send(f"findptr {ARRANGEMENT_VTABLE + slide:x} 500").split()
            if len(h) > 6 and h != "end"]
    seen = {}
    for h in hits:
        name = sso(h + ARR_NAME)
        if name:
            seen.setdefault(name, []).append(h)
    dups = [(n, a) for n, a in seen.items() if len(a) > 1]
    if not dups:
        return None, sorted(seen)
    name, addrs = dups[0]
    return {"name": name, "slots": [sso(addrs[0] + ARR_TONES + i * ARR_STRIDE) for i in range(5)]}, sorted(seen)


# ---------------------------------------------------------------- timer discovery

# Rocksmith's song timer is a double in seconds (group 2: small and fast); the broader groups
# (0: float seconds + int ms, 1: float/double ms) are tried every few rounds as a fallback.
GROUP_ORDER = [2, 2, 2, 0, 1]
_group = [0]


def find_timers(log, stop):
    """Candidates advancing at 1.0 s/s over 3 checks a second apart. Returns [(kind, addr)].

    The two groups of timer forms (seconds / milliseconds as floats) are searched alternately
    to keep the reader's peak memory to a few hundred MB.
    """
    group = GROUP_ORDER[_group[0] % len(GROUP_ORDER)]
    _group[0] += 1
    send(f"snapt {group}", timeout=120)
    for _ in range(3):
        if stop():
            send("tfree")
            return []
        time.sleep(1.0)
        counts = [int(x) for x in send("ratet 0.97 1.03", timeout=120).split()[1:]]
        log(f"timer search group {group} pass {_ + 1}: candidates per form {counts}")
        if sum(counts) == 0:
            send("tfree")
            return []
    cands = [l.split() for l in send("tlist").splitlines() if l and not l.startswith("end")]
    send("tfree")
    return [(k, int(a, 16)) for k, a, _ in cands]


def timer_value(kind, addr):
    fmt, size, scale = TIMER_FORMATS[kind]
    b = read(addr, size)
    return struct.unpack(fmt, b)[0] * scale if b else None


# ---------------------------------------------------------------- tones and presets

def load_index():
    idx = {}
    with open(paths.INDEX) as f:
        for line in f:
            a = json.loads(line)
            idx[a["arrangement"].lower()] = a
    return idx


def slot_at(arr, t):
    """Tone slot index (0 = Base, 1..4 = A..D) at song time t."""
    slot = 0
    for ct, tone_id in arr["changes"]:
        if ct <= t:
            slot = int(tone_id) + 1
        else:
            break
    return slot


def tone_info(arr, slot):
    key = arr["slots"][slot] or arr["slots"][0]
    return key, tone_def(arr, key).get("descriptors", [])


def tone_def(arr, key):
    """The tone's entry in the index ({key, descriptors, amp, gain, ...}), or {}."""
    return next((t for t in arr["tones"] if t["key"].lower() == key.lower()), {})


# ---------------------------------------------------------------- banner calibration

def banner_matches(text, key, descriptors):
    """The banner shows a tone's tags joined, e.g. CLEAN + CHORUS -> 'Clean Chorus'."""
    t = text.lower().split()
    tags = " ".join(descriptors).lower().split()
    return (t and sorted(t) == sorted(tags)) or any(d.lower() == text.lower() for d in descriptors) \
        or text.lower() in key.lower()


def banner_slot(arr, text):
    """Slot whose tone the banner text names (by descriptor, else by tone key)."""
    for slot in range(5):
        key, desc = tone_info(arr, slot)
        if arr["slots"][slot] and banner_matches(text, key, desc):
            return slot
    return None


class BannerWatch(threading.Thread):
    """Finds new '<Song> - <Tone>' banner strings, which the game creates at each tone change."""

    def __init__(self, song, log):
        super().__init__(daemon=True)
        self.prefix, self.log = f"{song} - ", log
        self.seen, self.events, self.running, self.interval = None, [], True, 0.5

    def run(self):
        while self.running:
            try:
                hits = {int(h, 16) for h in send(f"findhex {self.prefix.encode().hex()} 300").split()
                        if len(h) > 6 and h != "end"}
            except OSError:
                time.sleep(1)
                continue
            now = time.time()
            if self.seen is not None:
                for a in hits - self.seen:
                    b = read(a, 96) or b""
                    text = b.split(b"\0")[0].decode(errors="replace")
                    if text.startswith(self.prefix):
                        self.events.append((now, text[len(self.prefix):]))
                        self.log(f"banner seen: {text!r}")
            self.seen = hits if self.seen is None else self.seen | hits
            time.sleep(self.interval)


# ---------------------------------------------------------------- main loop

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udp", help="also send each event as a UDP datagram to HOST:PORT")
    ap.add_argument("--lead-ms", type=int, default=100, help="report tone changes this many ms early (default 100)")
    ap.add_argument("--log", default=paths.LOG, help="diagnostic log file")
    ap.add_argument("--port", type=int, default=8765, help="live window at http://localhost:PORT")
    ap.add_argument("--no-open", action="store_true", help="do not open the live window in the browser")
    ap.add_argument("--no-index-refresh", action="store_true", help="use the song index as is")
    ap.add_argument("--arrangement", help="testing: use this arrangement instead of detecting it")
    ap.add_argument("--process", default="Rocksmith2014", help="testing: attach to this process name")
    args = ap.parse_args()

    global PROCESS
    PROCESS = args.process
    # Only one rstone at a time: two would keep restarting each other's rsprobe.
    import fcntl
    lock_file = open("/tmp/rstone.lock", "w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("rstone is already running")
    paths.ensure_data_dir()
    logf = open(args.log, "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        logf.write(line + "\n")
        logf.flush()
        print(line, file=sys.stderr, flush=True)

    udp = None
    if args.udp:
        host, port = args.udp.rsplit(":", 1)
        udp = (socket.socket(socket.AF_INET, socket.SOCK_DGRAM), (host, int(port)))

    ui = {"attached": False, "song": None, "tone": None, "history": [], "seq": 0, "timer_confirmed": False,
          "warning": None}

    def emit(event):
        kind = event["event"]
        if kind == "attached":  # new game process: forget the previous song
            ui.update(attached=True, song=None, tone=None, history=[])
        elif kind == "song":
            ui.update(song=event, tone=None, history=[])
        elif kind == "tone":
            ui["tone"] = event
            ui["history"] = (ui["history"] + [dict(event, clock=time.strftime("%H:%M:%S"))])[-30:]
            ui["seq"] += 1
        line = json.dumps(event)
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()
        if udp:
            udp[0].sendto(line.encode(), udp[1])

    def emit_tone(arr, slot, source, time_s=None):
        key, desc = tone_info(arr, slot)
        t = tone_def(arr, key)
        preset, why = presets.get(arr["arrangement"], SLOTS[slot], key, desc,
                                  artist=arr["artist"], amp=t.get("amp", ""), gain=t.get("gain"))
        event = {"event": "tone", "song": arr["song"], "artist": arr["artist"],
                 "arrangement": arr["arrangement"], "slot": SLOTS[slot], "tone": key,
                 "descriptors": desc, "preset": preset, "preset_reason": why, "source": source}
        if time_s is not None:
            event["time"] = time_s
        emit(event)
        st.last_slot, st.last_key = slot, key.lower()

    start_ui(ui, lambda: st.confirmed, args.port, log)
    if not args.no_open:
        subprocess.run(["open", f"http://localhost:{args.port}"])

    check_executable(log, ui)

    if not args.no_index_refresh:
        log("refreshing song index")
        subprocess.run([sys.executable, os.path.join(HERE, "index_songs.py")])
    index = load_index()
    presets = Presets(paths.PRESETS)
    log(f"{len(index)} arrangements indexed")

    probe = Probe(log)
    st = State()
    lock = threading.Lock()

    def reset_song(found, names):
        """Selected arrangement changed: look it up and start over with timers and banner."""
        nonlocal index
        arr = index.get(found["name"].lower())
        if arr is None:  # maybe a new song: refresh the index once
            subprocess.run([sys.executable, os.path.join(HERE, "index_songs.py")])
            index = load_index()
            arr = index.get(found["name"].lower())
        log(f"arrangement {found['name']} slots {found['slots']} "
            f"(in memory: {', '.join(names)}); index: {'found' if arr else 'MISSING'}")
        with lock:
            if st.banner:
                st.banner.running = False
            # The song timer is one object for the whole game session, so a confirmed timer stays.
            st.arr_name, st.arr = found["name"], arr
            if not st.confirmed:
                st.timers, st.timer = [], None
            st.last_slot, st.last_key, st.banner, st.gen = None, None, None, st.gen + 1
            _group[0] = 0
            if arr:
                st.banner = BannerWatch(arr["song"], log)
                st.banner.start()
        if arr:
            emit({"event": "song", "song": arr["song"], "artist": arr["artist"],
                  "arrangement": arr["arrangement"], "path": arr["path"]})
            emit_tone(arr, 0, source="song-start")

    def searcher():
        """Background: watch the selected arrangement and look for song timers, so the main loop
        never stalls. Searching stops once a banner has confirmed the timer."""
        last_check = 0
        while True:
            try:
                if st.slide is None:
                    time.sleep(0.5)
                    continue
                if time.time() - last_check > 5:
                    last_check = time.time()
                    if args.arrangement:
                        found, names = {"name": args.arrangement, "slots": ["(test)"]}, [args.arrangement]
                    else:
                        found, names = current_arrangement(st.slide)
                    if found and found["name"] != st.arr_name:
                        reset_song(found, names)
                if st.arr and not st.confirmed:
                    gen = st.gen
                    found = find_timers(log, lambda: st.gen != gen or st.confirmed)
                    with lock:
                        new = [c for c in found if c not in st.timers] if st.gen == gen else []
                        st.timers += new
                    if new:
                        log(f"timer candidates +{len(new)} (pool {len(st.timers)}): "
                            f"{ {f'{k}@{a:x}': round(timer_value(k, a) or -1, 2) for k, a in new[:12]} }")
                time.sleep(1)
            except OSError:
                time.sleep(1)  # reader restarting (game relaunched)

    threading.Thread(target=searcher, daemon=True).start()
    last_value, last_progress = None, 0
    pending, logged_unmatched, seen_gen = [], set(), -1

    while True:
        state = probe.ensure()
        if not state:
            ui["attached"] = False  # game not running
            time.sleep(1)
            continue
        if state == "new":
            with lock:
                if st.banner:
                    st.banner.running = False
                gen = st.gen
                st.__init__()
                st.gen = gen + 1
            st.slide = find_slide()
            log(f"image slide 0x{st.slide:x}" if st.slide is not None else "image not found yet")
            emit({"event": "attached"})
        if st.slide is None:
            st.slide = find_slide()
            time.sleep(1)
            continue
        arr = st.arr
        if st.gen != seen_gen:  # new song or new game process: forget old banners
            seen_gen = st.gen
            pending.clear()
        if arr is None:
            time.sleep(0.2)
            continue

        try:
            # Banners (the game's own "<Song> - <Tone>" text) serve twice: until a song timer is
            # confirmed they are the event source (up to ~1 s late), and they confirm which timer
            # candidate is the song timer by matching its value against the song's change times.
            banner = st.banner
            fresh = []
            if banner and banner.events:
                fresh = list(banner.events)
                banner.events.clear()
                pending.extend(fresh)
            if st.confirmed and fresh:
                t_now = timer_value(*st.timer)
                for seen_at, text in fresh:
                    slot = banner_slot(arr, text)
                    if slot is None or t_now is None:
                        continue
                    # The banner appears at the change; allow for the scan delay since then.
                    key = tone_info(arr, slot)[0].lower()
                    ok = any(tone_info(arr, slot_at(arr, t_now - back))[0].lower() == key
                             for back in (0, 0.5, 1, 1.5, 2, 2.5, 3))
                    if not ok:
                        log(f"banner {text!r} disagrees with song timer at {t_now:.2f}s; re-locking")
                        st.confirmed = False
                        emit_tone(arr, slot, source="banner")
                fresh = [] if st.confirmed else fresh
            if not st.confirmed:
                for _, text in fresh:
                    slot = banner_slot(arr, text)
                    if slot is None:
                        log(f"banner {text!r} matches no tone of {arr['arrangement']}")
                    elif tone_info(arr, slot)[0].lower() != st.last_key:
                        emit_tone(arr, slot, source="banner")
                pending[:] = [(w, x) for w, x in pending if time.time() - w < 60]
                for seen_at, text in list(pending):
                    best = None
                    for c in list(st.timers):
                        v = timer_value(*c)
                        if v is None:
                            continue
                        for ct, tone_id in arr["changes"]:
                            key, desc = tone_info(arr, int(tone_id) + 1)
                            if banner_matches(text, key, desc):
                                lag = v - (time.time() - seen_at) - ct  # candidate time at banner discovery minus change time
                                if -0.5 <= lag <= 3.5 and (best is None or abs(lag) < abs(best[0])):
                                    best = (lag, c, ct)
                    if best:
                        st.timer, st.confirmed = best[1], True
                        log(f"banner {text!r}: song timer is {best[1][0]}@{best[1][1]:x} "
                            f"(change at {best[2]:.1f}s, lag {best[0]:.2f}s)")
                        banner.interval = 2.0  # keep verifying, less often
                        pending.clear()
                        break
                    if (seen_at, text) not in logged_unmatched:
                        logged_unmatched.add((seen_at, text))
                        log(f"banner {text!r}: no timer candidate matched yet; values "
                            f"{[(c[0], round(timer_value(*c) or -1, 2)) for c in list(st.timers)[:20]]}")
                if not st.confirmed:
                    time.sleep(0.1)
                    continue

            t = timer_value(*st.timer)
            if t is None:
                log("song timer unreadable; searching again")
                with lock:
                    st.timers = [c for c in st.timers if c != st.timer]
                    st.timer, st.confirmed = None, False
                continue
            if last_value is None or abs(t - last_value) > 1e-4:
                last_progress = time.time()
            last_value = t
            st.idle = time.time() - last_progress > 3

            slot = slot_at(arr, t + args.lead_ms / 1000)
            if slot != st.last_slot:
                st.last_slot = slot
                if tone_info(arr, slot)[0].lower() != st.last_key:  # same tone in another slot: no change
                    emit_tone(arr, slot, source="timer", time_s=round(t, 2))
        except OSError:
            time.sleep(0.5)  # reader restarting
            continue
        time.sleep(0.05)


def check_executable(log, ui):
    """Warn when the game executable is not the build game_profile.json was made for."""
    import hashlib
    try:
        h = hashlib.sha256(open(paths.GAME_EXECUTABLE, "rb").read()).hexdigest()
    except OSError as e:
        log(f"cannot read the game executable to check its version: {e}")
        return
    if h != PROFILE["executable_sha256"]:
        msg = ("Rocksmith's executable has changed since game_profile.json was made. Song detection may "
               "fail; see docs/when-the-game-updates.md.")
        log(f"WARNING: {msg} (sha256 {h})")
        ui["warning"] = msg


def start_ui(ui, confirmed, port, log):
    """Live window: serves ui.html and the current state as JSON."""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    allowed_hosts = {f"localhost:{port}", f"127.0.0.1:{port}"}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # Only pages opened as localhost: a website re-pointing its own name at 127.0.0.1
            # (DNS rebinding) sends its own name as Host and gets nothing.
            if self.headers.get("Host", "") not in allowed_hosts:
                self.send_error(403)
                return
            if self.path.startswith("/state"):
                try:
                    locked = confirmed()
                except NameError:  # still starting up
                    locked = False
                body = json.dumps(dict(ui, timer_confirmed=locked)).encode()
                ctype = "application/json"
            else:
                body = open(os.path.join(paths.ROOT, "ui.html"), "rb").read()
                ctype = "text/html; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"live window at http://localhost:{port}")


class State:
    """Shared between the main loop and the background searcher."""

    def __init__(self):
        self.slide, self.arr_name, self.arr = None, None, None
        self.timers, self.timer, self.confirmed, self.idle = [], None, False, True
        self.last_slot, self.last_key, self.banner, self.gen = None, None, None, 0


def _stop(*_):
    raise KeyboardInterrupt


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, _stop)  # stopped by kill: shut down like Ctrl+C
    try:
        main()
    except KeyboardInterrupt:
        subprocess.run(["pkill", "-f", paths.RSPROBE])
