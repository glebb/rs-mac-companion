#!/bin/sh
# End-to-end test of the companion app without the game: the in-game dylib runs in the
# stand-in (tests/standin_dylib.c), sends events to the app (app/), and the app sends MIDI,
# which tools/midi_monitor.swift prints (about 70 s). The mapping (presets.json) starts with
# Self Trap (Rhythm, comes with the game) slot B (Distortion) overridden to Crunch, and mid-song
# SelfTrap_clean is set to Lead (as a hand edit, which the app picks up). Expected Program Changes:
# 0 (Clean) at song start, 1 (Crunch, from the banner), 3 (Lead: Clean slot A, from the timer at
# ~62.9 s), and 3 again when the app is restarted mid-song and catches up. Settings
# (rscompanion.json) select Program Changes 4-7, MIDI channel 2 and a lead
# time of 300 ms, so the Program Changes go out as 4, 5, 7, 7 on channel 2, with the timed change
# reported ~0.3 s early.
# Uses a temporary data folder, so your own data and a running RS Companion are not touched
# (the MIDI source name is the same, so quit a running RS Companion first).
set -e
cd "$(dirname "$0")/.."
GAME_DIR=${RS_GAME_DIR:-"$HOME/Library/Application Support/Steam/steamapps/common/Rocksmith2014"}
ARCHIVE="$GAME_DIR/songs.psarc"
[ -f "$ARCHIVE" ] || { echo "Rocksmith's songs.psarc not found at $ARCHIVE (set RS_GAME_DIR)" >&2; exit 1; }
if pgrep -x RSCompanion > /dev/null; then echo "quit RS Companion first" >&2; exit 1; fi
[ -x build/rstool ] && [ -f build/librscompanion.dylib ] || { echo "run ./build.sh first" >&2; exit 1; }
app/build.sh > /dev/null
swiftc -O tools/midi_monitor.swift -o build/midi_monitor
clang -arch x86_64 -O1 -o build/rs-standin-dylib tests/standin_dylib.c
SNG=$(build/rstool toc "$ARCHIVE" | awk '$4 == "songs/bin/macos/selftrap_rhythm.sng" {print $1}')
AUDIO=$(build/rstool toc "$ARCHIVE" | awk '$4 ~ /\.wem$/ {print $1; exit}')

DATA=$(mktemp -d /tmp/rsc.XXXXXX)  # short: socket paths are limited to 104 characters
APP_BIN="app/build/RS Companion.app/Contents/MacOS/RSCompanion"
APP= MONITOR= STANDIN=
trap 'kill $APP $MONITOR $STANDIN 2>/dev/null; wait 2>/dev/null; rm -rf "$DATA"' EXIT

python3 - "$DATA/presets.json" <<'EOF'
import json, sys
p = json.load(open("presets.default.json"))
p["songs"] = {"selftrap_rhythm": {"B": "Crunch"}}
json.dump(p, open(sys.argv[1], "w"), indent=2)
EOF
echo '{"lead_ms": 300, "midi_channel": 2, "programs": {"Clean": 4, "Crunch": 5, "Heavy": 6, "Lead": 7}}' \
  > "$DATA/rscompanion.json"
RS_COMPANION_DATA="$DATA" "$APP_BIN" & APP=$!
build/midi_monitor > "$DATA/midi.txt" & MONITOR=$!
sleep 2
RS_COMPANION_DATA="$DATA" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
  build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" & STANDIN=$!
sleep 40
python3 - "$DATA/presets.json" <<'EOF'
import json, sys
p = json.load(open(sys.argv[1]))
p["tones"] = {"SelfTrap_clean": "Lead"}
json.dump(p, open(sys.argv[1], "w"), indent=2)
EOF
sleep 22
# Restart the app mid-song: it must catch up with the active tone from the heartbeat.
kill $APP; wait $APP 2>/dev/null || true
RS_COMPANION_DATA="$DATA" "$APP_BIN" & APP=$!
sleep 4
kill $APP $MONITOR $STANDIN; wait 2>/dev/null || true

echo "app log:"; sed 's/^/  /' "$DATA/rs-companion-app.log"
echo "MIDI:"; sed 's/^/  /' "$DATA/midi.txt"
python3 - "$DATA/midi.txt" "$DATA/rs-companion-app.log" <<'EOF'
import sys
midi = [l.split(": ", 1)[1].strip() for l in open(sys.argv[1]) if "Program Change" in l]
log = open(sys.argv[2]).read()
import re
expect = ["Program Change 4 ch 2", "Program Change 5 ch 2", "Program Change 7 ch 2", "Program Change 7 ch 2"]
timed = [float(t) for t in re.findall(r"from timer at ([0-9.]+) s", log)]
ok = midi == expect and "caught up: tone A SelfTrap_clean → Lead" in log and "presets.json changed" in log \
    and len(timed) == 1 and 62.6 <= timed[0] <= 62.8
print("PASS" if ok else f"FAIL: expected {expect} (the last after the restart), a presets reload, a catch-up "
      f"and the timed change at ~62.72 s (got {timed})")
sys.exit(0 if ok else 1)
EOF
