#!/bin/sh
# End-to-end test of the in-game dylib (native/rscompanion.c) without the game, against
# tests/standin_dylib.c (two runs of about 60 s), with tools/event_listener.py receiving the
# events on the socket as the companion app would. Checks:
#   - the song is detected from the stand-in's file reads of the game's own songs.psarc (Self
#     Trap, which comes with the game), the selected arrangement is picked (not a stale one), and
#     the song event lists its tones and parts,
#   - starting tone, first change from the banner (which also locks the song timer while
#     ignoring decoy clocks), next change from the timer, on time,
#   - a state heartbeat about every second,
#   - run 2 reuses the memory tags learned in run 1 (narrow scans) and a lead time of 500 ms
#     set in rscompanion.json.
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
trap 'kill $STANDIN $LISTENER 2>/dev/null; wait 2>/dev/null; rm -rf "$HOME_DIR"' EXIT

for RUN in 1 2; do
  LOG="$DATA/rscompanion.log" EVENTS="$DATA/events.jsonl"
  rm -f "$LOG" "$EVENTS"
  [ $RUN = 2 ] && echo '{"lead_ms": 500}' > "$DATA/rscompanion.json"
  python3 tools/event_listener.py --socket "$DATA/events.sock" --out "$EVENTS" > /dev/null 2>&1 &
  LISTENER=$!
  sleep 1
  HOME="$HOME_DIR" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
    build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" &
  STANDIN=$!
  sleep 60
  kill $STANDIN $LISTENER; wait $STANDIN $LISTENER 2>/dev/null || true
  echo "run $RUN:"
  grep -v '^\S* EVENT' "$LOG" | grep -v '^\S*   ' | grep -v 'banner seen' | sed 's/^/  log: /'
  python3 - "$LOG" "$EVENTS" "$RUN" <<'EOF'
import json, sys
log, events_file, run = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(log).read().splitlines()
events = [json.loads(l) for l in open(events_file)]
problems = []

tones = [(e["source"], e["arrangement"], e["slot"], e["tone"], e.get("time")) for e in events if e["event"] == "tone"]
for t in tones:
    print("  ", t)
expect = [("song-start", "selftrap_rhythm", "Base", "SelfTrap_clean"), ("banner", "selftrap_rhythm", "B", "SelfTrap_dist"),
          ("timer", "selftrap_rhythm", "A", "SelfTrap_clean")]
# The timer change to Clean is at 63.023 s, reported lead_ms early (checked every 50 ms).
lo, hi = (62.7, 63.1) if run == 1 else (62.3, 62.7)
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
if not 50 <= len(states) <= 62 or last.get("protocol") != 1 or last.get("song") != "Self Trap" \
        or not last.get("timer_locked") or last.get("lead_ms") != (100 if run == 1 else 500):
    problems.append("heartbeats: expected ~1 per second, ending with the song, a locked timer and the lead time")

if run == 2 and not (any("arrangement scan (narrow)" in l and "-> selftrap_rhythm" in l for l in lines)
                     and any("timer search (narrow" in l for l in lines)):
    problems.append("expected narrow arrangement and timer scans in run 2")

for p in problems:
    print("   FAIL:", p)
print(f"run {run}:", "FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)
EOF
done
