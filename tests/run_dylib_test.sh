#!/bin/sh
# End-to-end test of the in-game dylib (native/rscompanion.c) without the game, against
# tests/standin_dylib.c (two runs of about 60 s, one of 30 s and one of 55 s), with tools/event_listener.py receiving the
# events on the socket as the companion app would. Checks:
#   - the song is detected from the stand-in's file reads of the game's own songs.psarc (Self
#     Trap, which comes with the game), the selected arrangement is picked (not a stale one), and
#     the song event lists its tones and parts,
#   - starting tone, first change from the banner (which also locks the song timer while
#     ignoring decoy clocks), next change from the timer, on time,
#   - a state heartbeat about every second,
#   - run 2 reuses the memory tags learned in run 1 (narrow scans) and a lead time of 500 ms
#     set in rscompanion.json,
#   - run 3 (stand-in "notones": Self Trap's bass, no tone changes, no banners): the game's play
#     record "Play_SelfTrap" locks the song timer within seconds of the song starting, ignoring a
#     stale record and a clock started when the song was picked. With overlay_enabled set in
#     rscompanion.json for this run, the note-stats and Score Attack objects are found by type
#     pointer (not the freed copy) and reported in stats events; runs 1-2 send none,
#   - run 4 (stand-in "unseen"): run 3's song is restarted (the timer goes back; the play record
#     shows the song again, so tone changes go on), then another song starts whose files the game
#     doesn't read: tone changes stop at once, and once its play record stays gone the song is
#     dropped (heartbeats without a song),
#   - run 5: run 1's song with no app listening for the first 12 s: the dylib pauses its memory
#     scans (none before the listener appears), then finds the arrangement and reports the same
#     tones on time.
# Needs the game installed (songs.psarc). Everything goes to a temporary folder, so your own data
# is not touched.
set -e
cd "$(dirname "$0")/.."
[ -x build/rstool ] && [ -f build/librscompanion.dylib ] || { echo "run ./build.sh first" >&2; exit 1; }
GAME_DIR=${RS_GAME_DIR:-"$HOME/Library/Application Support/Steam/steamapps/common/Rocksmith2014"}
ARCHIVE="$GAME_DIR/songs.psarc"
[ -f "$ARCHIVE" ] || { echo "Rocksmith's songs.psarc not found at $ARCHIVE (set RS_GAME_DIR)" >&2; exit 1; }
SNG=$(build/rstool toc "$ARCHIVE" | awk '$4 == "songs/bin/macos/selftrap_rhythm.sng" {print $1}')
AUDIO=$(build/rstool toc "$ARCHIVE" | awk '$4 ~ /\.wem$/ {print $1; exit}')
clang -arch x86_64 -O1 -o build/rs-standin-dylib tests/standin_dylib.c

HOME_DIR=$(mktemp -d /tmp/rsc.XXXXXX)  # short: socket paths are limited to 104 characters
DATA="$HOME_DIR/Library/Application Support/rs-mac-companion"
mkdir -p "$DATA"
STANDIN= LISTENER=
trap 'kill $STANDIN $LISTENER 2>/dev/null || true; wait 2>/dev/null; rm -rf "$HOME_DIR"' EXIT

for RUN in 1 2 3 4 5; do
  LOG="$DATA/rscompanion.log" EVENTS="$DATA/events.jsonl"
  rm -f "$LOG" "$EVENTS"
  [ $RUN = 2 ] && echo '{"lead_ms": 500}' > "$DATA/rscompanion.json"
  [ $RUN = 3 ] && echo '{"lead_ms": 500, "overlay_enabled": true}' > "$DATA/rscompanion.json"
  [ $RUN = 4 ] && echo '{"lead_ms": 500}' > "$DATA/rscompanion.json"
  [ $RUN = 5 ] && rm -f "$DATA/rscompanion.json" "$DATA/events.sock"
  listen() {
    python3 tools/event_listener.py --socket "$DATA/events.sock" --out "$EVENTS" > /dev/null 2>&1 &
    LISTENER=$!
  }
  [ $RUN != 5 ] && listen && sleep 1
  HOME="$HOME_DIR" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
    build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" $([ $RUN = 3 ] && echo notones) $([ $RUN = 4 ] && echo unseen) &
  STANDIN=$!
  [ $RUN = 5 ] && sleep 12 && listen && sleep 48
  case $RUN in 3) sleep 30 ;; 4) sleep 55 ;; 5) ;; *) sleep 60 ;; esac
  kill $STANDIN $LISTENER; wait $STANDIN $LISTENER 2>/dev/null || true
  echo "run $RUN:"
  grep -v '^\S* EVENT' "$LOG" | grep -v '^\S*   ' | grep -v 'banner seen' | sed 's/^/  log: /'
  python3 - "$LOG" "$EVENTS" "$RUN" <<'EOF'
import json, sys
log, events_file, run = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(log).read().splitlines()
events = [json.loads(l) for l in open(events_file)]
problems = []

if run == 4:
    tones = [(e["source"], e["arrangement"], e["slot"], e["tone"]) for e in events if e["event"] == "tone"]
    print("  ", tones)
    if tones != [("song-start", "selftrap_bass", "Base", "SelfTrap_bass")]:
        problems.append("tones: expected only the starting tone of selftrap_bass")
    at = lambda text: next((i for i, l in enumerate(lines) if text in l), None)
    lock, back = at("play record: song timer is the double"), at("song timer went back")
    goes_on, dropped = at("play record shows SelfTrap playing"), at("no live play record of SelfTrap")
    backs = [i for i, l in enumerate(lines) if "song timer went back" in l]
    if None in (lock, back, goes_on, dropped) or len(backs) != 2 or not lock < backs[0] < goes_on < backs[1] < dropped:
        problems.append("log: expected lock, timer back (restart), play record goes on, timer back (other song), dropped")
    states = [e for e in events if e["event"] == "state"]
    with_song = [i for i, e in enumerate(states) if e.get("song")]
    last = states[-1] if states else {}
    print(f"   {len(states)} heartbeats, {len(with_song)} with the song; last: song {last.get('song')!r}")
    # Song from ~3 s (picked) until dropped ~10-15 s after the other song starts at 32 s.
    if not with_song or last.get("song") or not 35 <= len(with_song) <= 50 \
            or with_song != list(range(with_song[0], with_song[-1] + 1)):
        problems.append("heartbeats: expected the song until it is dropped (~42-48 s), none after")
    for p in problems:
        print("   FAIL:", p)
    print(f"run {run}:", "FAIL" if problems else "PASS")
    sys.exit(1 if problems else 0)

if run == 5:
    at = lambda text: next((i for i, l in enumerate(lines) if text in l), None)
    paused, resumed = at("no app listening: memory scans paused"), at("the app is listening: memory scans on")
    scans = [i for i, l in enumerate(lines) if "arrangement scan" in l or "timer search" in l]
    print(f"   paused at log line {paused}, resumed at {resumed}, first scan at {scans[0] if scans else None}")
    if paused is None or resumed is None or not paused < resumed or not scans or scans[0] < resumed:
        problems.append("log: expected scans paused, no scan until the app listens, then scans")

if run == 3:
    tones = [(e["source"], e["arrangement"], e["slot"], e["tone"]) for e in events if e["event"] == "tone"]
    print("  ", tones)
    if tones != [("song-start", "selftrap_bass", "Base", "SelfTrap_bass")]:
        problems.append("tones: expected only the starting tone of selftrap_bass")
    states = [e for e in events if e["event"] == "state"]
    locked = [e for e in states if e.get("timer_locked")]
    first = locked[0].get("time") if locked else None
    last = states[-1] if states else {}
    print(f"   {len(states)} heartbeats; first locked one at song time {first}; last: locked "
          f"{last.get('timer_locked')}, time {last.get('time')}")
    # The song starts 5 s into the run; the run is 30 s, so the song is ~24 s in at the end.
    if first is None or first > 12 or not last.get("timer_locked") or not 22 <= (last.get("time") or 0) <= 26:
        problems.append("expected the timer locked within 12 s of the song start, at the song time")
    stats = [e for e in events if e["event"] == "stats"]
    last = stats[-1] if stats else {}
    print(f"   {len(stats)} stats events; last: {last}")
    # Objects from e = 5 s, one hit per second of song time; 4 events a second once found.
    if len(stats) < 40 or last.get("mode") != "sa" or not 20 <= last.get("hits", 0) <= 26 \
            or last.get("score") != last.get("hits", 0) * 100 or last.get("multiplier") != 1 \
            or abs(last.get("time", 0) - last.get("hits", 0)) > 1.5 or any(e.get("hits") == 999 for e in stats):
        problems.append("stats: expected Score Attack stats ~4/s with hits = song seconds, score = 100 per hit")
    lock = [i for i, l in enumerate(lines) if "play record: song timer is the double" in l]
    if not lock or any("timer search" in l for l in lines[lock[0] + 1:]):
        problems.append("expected a lock by the play record and no timer search after it")
    for p in problems:
        print("   FAIL:", p)
    print(f"run {run}:", "FAIL" if problems else "PASS")
    sys.exit(1 if problems else 0)

tones = [(e["source"], e["arrangement"], e["slot"], e["tone"], e.get("time")) for e in events if e["event"] == "tone"]
for t in tones:
    print("  ", t)
expect = [("song-start", "selftrap_rhythm", "Base", "SelfTrap_clean"), ("banner", "selftrap_rhythm", "B", "SelfTrap_dist"),
          ("timer", "selftrap_rhythm", "A", "SelfTrap_clean")]
# The timer change to Clean is at 63.023 s, reported lead_ms early (checked every 50 ms).
lo, hi = (62.7, 63.1) if run in (1, 5) else (62.3, 62.7)
if [t[:4] for t in tones] != expect or not lo <= (tones[2][4] or 0) <= hi:
    problems.append(f"tones: expected song-start Clean, banner Distortion, timer Clean at {lo}-{hi} s")

songs = [e for e in events if e["event"] == "song"]
want_tones = [("Base", "SelfTrap_clean", ["CLEAN"]), ("A", "SelfTrap_clean", ["CLEAN"]),
              ("B", "SelfTrap_dist", ["DISTORTION"])]
got_tones = [(t["slot"], t["tone"], t["descriptors"]) for t in songs[0]["tones"]] if songs else None
print("   song event tones:", got_tones)
if len(songs) != 1 or songs[0]["arrangement"] != "selftrap_rhythm" or got_tones != want_tones:
    problems.append(f"song event: expected one for selftrap_rhythm with tones {want_tones}")
gear = {(e.get("amp"), e.get("gain")) for e in events if e["event"] == "tone"}
gear |= {(t.get("amp"), t.get("gain")) for t in songs[0]["tones"]} if songs else set()
if gear != {("Amp_TW40", 83)}:
    problems.append(f"tone gear: expected amp Amp_TW40 gain 83 on every tone, got {gear}")
parts = {p["arrangement"]: p["slots"] for p in songs[0].get("parts", [])} if songs else {}
print("   song event parts:", {k: len(v) for k, v in parts.items()})
if parts.get("selftrap_rhythm") != {"Base": "SelfTrap_clean", "A": "SelfTrap_clean", "B": "SelfTrap_dist"} \
        or len(parts) != 4:
    problems.append("song event: expected all 4 parts of Self Trap with their slots")

states = [e for e in events if e["event"] == "state"]
last = states[-1] if states else {}
print(f"   {len(states)} heartbeats; last: song {last.get('song')!r}, slot {last.get('slot')}, "
      f"locked {last.get('timer_locked')}, time {last.get('time')}, lead {last.get('lead_ms')} ms")
if not (36 if run == 5 else 50) <= len(states) <= 62 or last.get("protocol") != 1 or last.get("song") != "Self Trap" \
        or not last.get("timer_locked") or last.get("lead_ms") != (500 if run in (2, 3, 4) else 100):
    problems.append("heartbeats: expected ~1 per second, ending with the song, a locked timer and the lead time")

if any(e["event"] == "stats" for e in events):
    problems.append("stats events without overlay_enabled")

if run == 2 and not (any("arrangement scan (narrow)" in l and "-> selftrap_rhythm" in l for l in lines)
                     and any("timer search (narrow" in l for l in lines)):
    problems.append("expected narrow arrangement and timer scans in run 2")

for p in problems:
    print("   FAIL:", p)
print(f"run {run}:", "FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)
EOF
done
