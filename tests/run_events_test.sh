#!/bin/sh
# Test of the events the in-game libraries send (native/rscore.c) for very large songs, without the
# game: tests/events_harness.c builds a 3-arrangement song and a 16-arrangement one with every name
# as long as the reader allows (and quotes and backslashes to escape), and receives their song,
# tone and state events. Expected: every event arrives and is valid JSON; the small song lists all
# 3 parts; the huge one lists only whole parts, as many as fit, and the log says how many. A second.
set -e
cd "$(dirname "$0")/.."
DATA=$(mktemp -d /tmp/rsc.XXXXXX)  # short: socket paths are limited to 104 characters
trap 'rm -rf "$DATA"' EXIT
clang -O1 -Wall -o "$DATA/harness" tests/events_harness.c native/rscore.c native/rsfile.c -lz
"$DATA/harness" "$DATA" small huge > "$DATA/events.txt"
python3 - "$DATA" <<'PY'
import json, sys
data = sys.argv[1]
fail = []
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    ok or fail.append(what)
lines = open(f"{data}/events.txt").read().splitlines()
events = []
for l in lines:
    try:
        events.append(json.loads(l))
    except ValueError as e:
        check(False, f"valid JSON ({e}): {l[:80]}...{l[-40:]}")
check(len(lines) == 6 and len(events) == 6, f"6 events (song, tone, state per song) arrive as valid JSON: {len(events)} of {len(lines)}")
by = {(e["event"], e.get("arrangement", "")[:5]): e for e in events}
small, huge = by.get(("song", "small"), {}), by.get(("song", "huge_"), {})
check([p["arrangement"] for p in small.get("parts", [])] == ["small_lead", "small_rhythm", "small_bass"]
      and small["parts"][0]["slots"] == {"Base": "small_clean", "A": "small_dist"}, "small song: all 3 parts")
hp = huge.get("parts", [])
check(0 < len(hp) < 16 and all(len(p["slots"]) == 5 and p["arrangement"].startswith("huge_part") for p in hp),
      f"huge song: only whole parts, as many as fit ({len(hp)} of 16)")
check(len(huge.get("tones", [])) == 5 and huge.get("song", "").startswith("Song0_"), "huge song: its tones and names")
state = by.get(("state", "huge_"), {})
check(state.get("tone", "").startswith("Tone1_") and state.get("time") == 2.5, "huge song: the state event is whole")
log = open(f"{data}/events_harness.log").read()
check(f"warning: {len(hp)} of 16 arrangements fit" in log, "the log says how many parts fit")
check(max(map(len, lines)) < 24576, f"every event fits the socket's send buffer ({max(map(len, lines))} bytes)")
sys.exit(1 if fail else 0)
PY
