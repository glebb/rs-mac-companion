#!/bin/sh
# End-to-end test of rstone without the game, against tests/standin.c (about 70 s).
# Checks: starting tone at song selection, first change from the banner (which also locks the
# song timer while ignoring decoy clocks), next change from the timer, on time.
# Uses a temporary data folder with a one-song index, so your own data is not touched.
set -e
cd "$(dirname "$0")/.."
[ -x build/rsprobe ] || { echo "run ./build.sh first" >&2; exit 1; }
if pgrep -f "rstone.py" > /dev/null; then echo "stop the running rstone.py first" >&2; exit 1; fi
clang -arch x86_64 -O1 -o build/rs-standin tests/standin.c

DATA=$(mktemp -d)
cp tests/fixture_index.jsonl "$DATA/tones_index.jsonl"
cp presets.default.json "$DATA/presets.json"
OUT="$DATA/events.jsonl"

build/rs-standin &
STANDIN=$!
RS_COMPANION_DATA="$DATA" python3 -u rstone.py --process rs-standin --arrangement selftrap_rhythm \
  --no-index-refresh --no-open --port 8799 --log "$DATA/test.log" > "$OUT" 2>/dev/null &
RSTONE=$!
trap 'kill $RSTONE $STANDIN 2>/dev/null; wait 2>/dev/null; rm -rf "$DATA"' EXIT

sleep 68

python3 - "$OUT" <<'EOF'
import json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
tones = [(e["source"], e["slot"], e["tone"], e.get("time")) for e in events if e["event"] == "tone"]
for t in tones:
    print("  ", t)
expect = [("song-start", "Base", "SelfTrap_clean"), ("banner", "B", "SelfTrap_dist"), ("timer", "A", "SelfTrap_clean")]
ok = [t[:3] for t in tones] == expect and 62.7 <= (tones[2][3] or 0) <= 63.1
print("PASS" if ok else "FAIL: expected song-start Clean, banner Distortion, timer Clean at ~62.9 s")
sys.exit(0 if ok else 1)
EOF
