#!/bin/sh
# End-to-end test of the RockNRoller library (native/rnrcompanion.c) without RockNRoller, against
# tests/standin_rnr.c (about 18 s), with tools/event_listener.py receiving the events on the
# socket as the companion app would. Checks:
#   - the song (Self Trap, from the game's songs.psarc as "songs.psarc#selftrap") is read when the
#     play screen opens, and the panel's part (RHYTHM) is followed: a song event with its tones
#     and parts, then its tone at the start position,
#   - tone changes on time (lead 100 ms before the song file's change time), also after a seek
#     (which itself changes nothing here: the tone at both positions is the same),
#   - the panel switching to BASS: a song event for selftrap_bass and its tone,
#   - heartbeats with "game": "rocknroller", without the song once the play screen closes.
# Needs the game installed (songs.psarc). Everything goes to a temporary folder.
set -e
cd "$(dirname "$0")/.."
[ -f build/librnrcompanion.dylib ] || { echo "run ./build.sh first" >&2; exit 1; }
GAME_DIR=${RS_GAME_DIR:-"$HOME/Library/Application Support/Steam/steamapps/common/Rocksmith2014"}
ARCHIVE="$GAME_DIR/songs.psarc"
[ -f "$ARCHIVE" ] || { echo "Rocksmith's songs.psarc not found at $ARCHIVE (set RS_GAME_DIR)" >&2; exit 1; }
mkdir -p build/rnr-standin
clang -arch arm64 -O1 -o build/rnr-standin/RockNRoller tests/standin_rnr.c

HOME_DIR=$(mktemp -d /tmp/rnr.XXXXXX)  # short: socket paths are limited to 104 characters
DATA="$HOME_DIR/Library/Application Support/rs-mac-companion"
mkdir -p "$DATA"
LISTENER=
trap 'kill $LISTENER 2>/dev/null || true; wait 2>/dev/null; rm -rf "$HOME_DIR"' EXIT
LOG="$DATA/rnrcompanion.log" EVENTS="$DATA/events.jsonl"
python3 tools/event_listener.py --socket "$DATA/events.sock" --out "$EVENTS" > /dev/null 2>&1 &
LISTENER=$!
sleep 1
HOME="$HOME_DIR" DYLD_INSERT_LIBRARIES="$PWD/build/librnrcompanion.dylib" \
  build/rnr-standin/RockNRoller "$ARCHIVE#selftrap"
sleep 0.5
kill $LISTENER; wait $LISTENER 2>/dev/null || true
grep -v '^\S* EVENT' "$LOG" | grep -v '^\S*   ' | sed 's/^/  log: /'
python3 - "$EVENTS" <<'EOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1])]
problems = []
songs = [e["arrangement"] for e in events if e["event"] == "song"]
tones = [(e["arrangement"], e["slot"], e["tone"], e.get("time")) for e in events if e["event"] == "tone"]
print("   songs:", songs)
for t in tones:
    print("   tone:", t)
if songs != ["selftrap_rhythm", "selftrap_bass"]:
    problems.append("songs: expected selftrap_rhythm, then selftrap_bass")
song = next((e for e in events if e["event"] == "song"), {})
if [t["slot"] for t in song.get("tones", [])] != ["Base", "A", "B"] or len(song.get("parts", [])) != 4:
    problems.append("song event: expected slots Base, A, B and 4 parts")
# Rhythm from 37 s: clean (Base), dist at 40.16 s; the seek to 60 s stays on dist (no event);
# clean at 63.02 s; then bass.
want = [("selftrap_rhythm", "Base", "SelfTrap_clean"), ("selftrap_rhythm", "B", "SelfTrap_dist"),
        ("selftrap_rhythm", "A", "SelfTrap_clean"), ("selftrap_bass", "Base", "SelfTrap_bass")]
if [t[:3] for t in tones] != want:
    problems.append(f"tones: expected {want}")
else:
    # Reported 100 ms early (lead), up to one 50 ms check later.
    for (_, _, _, at), change in ((tones[1], 40.164), (tones[2], 63.023)):
        if not change - 0.11 <= at <= change - 0.03:
            problems.append(f"tone at {at} s for the change at {change} s: expected ~{change - 0.1:.2f} s")
states = [e for e in events if e["event"] == "state"]
print(f"   {len(states)} heartbeats; last: song {states[-1].get('song') if states else None!r}")
if not states or any(e.get("game") != "rocknroller" for e in states):
    problems.append("heartbeats: expected game rocknroller in each")
if not any(e.get("song") for e in states) or states[-1].get("song"):
    problems.append("heartbeats: expected the song while playing, none after the play screen closes")
for p in problems:
    print("   FAIL:", p)
print("FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)
EOF
