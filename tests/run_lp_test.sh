#!/bin/sh
# The in-game library (native/rscompanion.c) in RS Re-ARMed Learn & Play, without the game: against
# tests/standin_lp.c, which plays RS Re-ARMed's part (its mod interface, the 32-bit guest window) and
# the game's (the opened .sng, the Play_ event, a song timer, decoy clocks and play records), with
# tools/event_listener.py receiving the events. Checks, in about 45 s:
#   - Learn & Play loads the library (it defines rc_mod_abi) and the library knows where it runs,
#   - the song comes from the .sng the game opens (18 And Life, a Windows archive in Learn & Play's
#     dlc folder: its table of contents and its PC-keyed .sng) and that arrangement is selected,
#   - the play record locks the song timer (not the decoy 0.42 s ahead, not the stale record),
#   - the starting tone, then the first change from the timer, on time;
# then (about 30 s) an arrangement without tone changes whose timer copy is freed 8 s in: the play
# record locks the timer again, in its new copy.
# Needs Learn & Play's game folder with skid18an_p.psarc (LP_GAME_DIR, default RS Re-ARMed's); skipped
# without it. Everything else goes to a temporary folder.
set -e
cd "$(dirname "$0")/.."
GAME_DIR=${LP_GAME_DIR:-"$HOME/Library/Application Support/RS Re-ARMed/learn-play/game"}
if [ ! -f "$GAME_DIR/dlc/skid18an_p.psarc" ]; then echo "skipped: no $GAME_DIR/dlc/skid18an_p.psarc"; exit 0; fi
mkdir -p build
clang -arch arm64 -O2 -Wall -dynamiclib -o build/librscompanion-lp-test.dylib native/rscompanion.c native/rscore.c \
  native/rsfile.c -lz
codesign -s - -f build/librscompanion-lp-test.dylib 2> /dev/null
clang -arch arm64 -O1 -Wall -o build/rs-standin-lp tests/standin_lp.c

HOME_DIR=$(mktemp -d /tmp/rsl.XXXXXX)  # short: socket paths are limited to 104 characters
DATA="$HOME_DIR/Library/Application Support/rs-mac-companion"
mkdir -p "$DATA"
LISTENER=
trap 'kill $LISTENER 2>/dev/null || true; wait 2>/dev/null; rm -rf "$HOME_DIR"' EXIT
LOG="$DATA/rscompanion.log" EVENTS="$DATA/events.jsonl"
python3 tools/event_listener.py --socket "$DATA/events.sock" --out "$EVENTS" > /dev/null 2>&1 &
LISTENER=$!
sleep 1
HOME="$HOME_DIR" LP_GAME_DIR="$GAME_DIR" build/rs-standin-lp "$PWD/build/librscompanion-lp-test.dylib" \
  skid18an_lead2 Skid18an 32 > "$HOME_DIR/standin.out"
kill $LISTENER; wait $LISTENER 2>/dev/null || true
sed 's/^/  standin: /' "$HOME_DIR/standin.out"
grep -v '^\S* EVENT' "$LOG" | grep -v '^\S*   ' | sed 's/^/  log: /'
python3 - "$LOG" "$EVENTS" "$HOME_DIR/standin.out" <<'EOF'
import json, re, sys
log, events_file, standin = sys.argv[1:4]
lines = open(log).read().splitlines()
events = [json.loads(l) for l in open(events_file)]
problems = []
def has(text, what):
    if not any(text in l for l in lines):
        problems.append(f"log: expected {what} ({text!r})")
has("RS Re-ARMed Learn & Play, game folder", "Learn & Play recognised")
has("song skid18an loaded by the game from", "the song from the opened .sng")
has("skid18an_lead2: Base=", "the arrangements read (PC .sng)")
has("selected arrangement skid18an_lead2", "the opened arrangement selected")
has("the game posted Play_Skid18an", "the song's Play_ event")
has("play record (Learn & Play): position float at", "the play record found")
has("note statistics: not on Learn & Play yet", "note statistics off")
slide = int(re.search(r"slide 0x([0-9a-f]+)", open(standin).read()).group(1), 16)
lock = [l for l in lines if "play record: song timer is the double at" in l]
want = f"{slide + 0x50400008:x}"
if not lock or want not in lock[0]:
    problems.append(f"log: expected the play record to lock the timer at {want}: {lock[:1]}")
tones = [(e["source"], e["arrangement"], e["slot"], e.get("time")) for e in events if e["event"] == "tone"]
print("  ", tones)
# skid18an_lead2: Base, then C at 23.213 s (on the timer, which starts at 3 s with the Play_ event)
if not tones or tones[0][:3] != ("song-start", "skid18an_lead2", "Base"):
    problems.append("tones: expected the starting tone of skid18an_lead2")
timed = [t for t in tones if t[0] == "timer"]
if not timed or timed[0][2] != "C" or abs(timed[0][3] - 23.213) > 0.3:
    problems.append(f"tones: expected the change at 23.2 s from the timer: {timed[:1]}")
for p in problems:
    print("   FAIL:", p)
print("run 1:", "FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)
EOF

echo "run 2: no tone changes, the timer moves"
rm -f "$LOG" "$EVENTS"
python3 tools/event_listener.py --socket "$DATA/events.sock" --out "$EVENTS" > /dev/null 2>&1 &
LISTENER=$!
sleep 1
HOME="$HOME_DIR" LP_GAME_DIR="$GAME_DIR" build/rs-standin-lp "$PWD/build/librscompanion-lp-test.dylib" \
  skid18an_bass Skid18an 25 moves > "$HOME_DIR/standin.out"
kill $LISTENER; wait $LISTENER 2>/dev/null || true
grep -v '^\S* EVENT' "$LOG" | grep -v '^\S*   ' | grep -v 'timer search' | sed 's/^/  log: /'
python3 - "$LOG" "$HOME_DIR/standin.out" <<'EOF'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
slide = int(re.search(r"slide 0x([0-9a-f]+)", open(sys.argv[2]).read()).group(1), 16)
locks = [l for l in lines if "play record: song timer is the double at" in l]
gone = [l for l in lines if "song timer unreadable" in l]
first, second = f"{slide + 0x50400008:x}", f"{slide + 0x50480008:x}"
ok = len(locks) >= 2 and first in locks[0] and second in locks[-1] and bool(gone)
print("  ", [l.split(" ", 1)[1] for l in locks])
if not ok:
    print(f"   FAIL: expected a lock at {first}, the timer unreadable, then a lock at {second}")
print("run 2:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
EOF
echo PASS
