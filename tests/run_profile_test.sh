#!/bin/sh
# Device profiles (app/Sources/Profile.swift, docs/device-profiles.md). First the format and its
# rules (tests/profile_harness.swift). Then end to end without the game, like
# run_song_tones_test.sh: the in-game dylib runs in the stand-in with Self Trap (Rhythm, comes
# with the game), a profile sends straight to a test MIDI device (tools/midi_monitor.swift
# --device), and a second monitor watches the virtual source. Expected at the device, on channel 3:
# the sequence of the song's amp in order, its wait kept, then the snapshot, knob and effect CCs for
# each tone.
# On the virtual source: nothing. About 50 s.
# Uses a temporary data folder, so your own data and a running RS Companion are not touched
# (the MIDI source name is the same, so quit a running RS Companion first).
set -e
cd "$(dirname "$0")/.."
GAME_DIR=${RS_GAME_DIR:-"$HOME/Library/Application Support/Steam/steamapps/common/Rocksmith2014"}
ARCHIVE="$GAME_DIR/songs.psarc"
[ -f "$ARCHIVE" ] || { echo "Rocksmith's songs.psarc not found at $ARCHIVE (set RS_GAME_DIR)" >&2; exit 1; }
if pgrep -x RSCompanion > /dev/null; then echo "quit RS Companion first" >&2; exit 1; fi
[ -x build/rstool ] && [ -f build/librscompanion.dylib ] || { echo "run ./build.sh first" >&2; exit 1; }

DATA=$(mktemp -d /tmp/rsc.XXXXXX)  # short: socket paths are limited to 104 characters
APP= MONITOR= DEVICE= STANDIN=
trap 'kill $APP $MONITOR $DEVICE $STANDIN 2>/dev/null || true; wait 2>/dev/null; rm -rf "$DATA"' EXIT

clang -O1 -c native/rsfile.c -o "$DATA/rsfile.o"
swiftc -parse-as-library -import-objc-header app/Sources/rsfile-bridge.h tests/profile_harness.swift \
  app/Sources/Profile.swift app/Sources/SongTones.swift app/Sources/Category.swift app/Sources/Rig.swift \
  "$DATA/rsfile.o" -lz -o "$DATA/harness" 2>&1 | grep -v warning || true
"$DATA/harness" profiles

app/build.sh > /dev/null
swiftc -O tools/midi_monitor.swift -o build/midi_monitor
clang -arch x86_64 -O1 -o build/rs-standin-dylib tests/standin_dylib.c
SNG=$(build/rstool toc "$ARCHIVE" | awk '$4 == "songs/bin/macos/selftrap_rhythm.sng" {print $1}')
AUDIO=$(build/rstool toc "$ARCHIVE" | awk '$4 ~ /\.wem$/ {print $1; exit}')
APP_BIN="app/build/RS Companion.app/Contents/MacOS/RSCompanion"

cp presets.default.json "$DATA/presets.json"
mkdir "$DATA/profiles"
cat > "$DATA/profiles/test-device.json" <<'JSON'
{
  "name": "Test device",
  "destination": "RS Test Device",
  "channel": 3,
  "song_load": {"*": [{"pc": 99}]},
  "amp_load": {"Amp_TW40": [{"pc": 100}, {"wait_ms": 300}, {"bytes": "B2 46 01"}, {"song_tones_message": true}]},
  "category": {
    "Clean":  [{"cc": 69, "value": 0}],
    "Crunch": [{"cc": 69, "value": 1}],
    "Heavy":  [{"cc": 69, "value": 2}],
    "Lead":   [{"cc": 69, "value": 2}, {"cc": 20, "value": 127}]
  },
  "effects": {"chorus": 21, "flanger": 21, "delay": 24},
  "knobs": [{"cc": 30, "from": "drive"}, {"cc": 31, "from": "bass"},
            {"cc": 32, "from": "delay_time"}, {"cc": 33, "from": "reverb_mix", "default": 5}]
}
JSON
echo '{"profile": "test-device"}' > "$DATA/rscompanion.json"
# The AI's correction reaches the drive knob of a distorted tone.
echo '{"selftrap": {"style": "Classic rock", "distortion": "crunch", "gain_offset": 0.3, "confidence": "high", "reason": "test"}}' > "$DATA/ai_classified.json"
build/midi_monitor --device "RS Test Device" > "$DATA/device.txt" & DEVICE=$!
sleep 1
RS_COMPANION_DATA="$DATA" "$APP_BIN" & APP=$!
build/midi_monitor > "$DATA/virtual.txt" & MONITOR=$!
sleep 2
RS_COMPANION_DATA="$DATA" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
  build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" & STANDIN=$!
sleep 46
kill $APP $MONITOR $DEVICE $STANDIN; wait 2>/dev/null || true

echo "app log:"; sed 's/^/  /' "$DATA/rs-companion-app.log"
echo "device:"; cut -c1-120 "$DATA/device.txt" | sed 's/^/  /'
python3 - "$DATA/device.txt" "$DATA/virtual.txt" "$DATA/profiles" <<'PY'
import datetime, json, os, re, sys
problems = []
rows = [l.rstrip("\n").split(" ", 1) for l in open(sys.argv[1]) if " RS Test Device: " in l]
events = [(datetime.datetime.strptime(t, "%H:%M:%S.%f"), m.split(": ", 1)[1]) for t, m in rows]
got = [e[1] for e in events]
if got[:2] != ["Program Change 100 ch 3", "Control Change 70 = 1 ch 3"]:
    problems.append(f"song load starts with {got[:2]}")
elif (events[1][0] - events[0][0]).total_seconds() < 0.28:
    problems.append("the wait step wasn't kept")
if len(got) < 3 or not got[2].startswith("SysEx") or '"song-tones"' not in got[2]:
    problems.append("no song tones message after the song load steps")
tones = [g for g in got[3:]]
# Self Trap's clean tone, then its dist tone: a snapshot, the knobs, then both effect CCs, off.
# Bass 48, then 55; no delay, so CC 32 stays silent; no reverb, so CC 33 sends its default.
effects = ["Control Change 21 = 0 ch 3", "Control Change 24 = 0 ch 3"]
fixed = lambda bass: [f"Control Change 31 = {bass} ch 3", "Control Change 33 = 5 ch 3"] + effects
if len(tones) != 12 or tones[2:6] != fixed(61) or tones[8:12] != fixed(70):
    problems.append(f"tone messages: {tones}")
if not all(tones[i].startswith("Control Change 69 = ") for i in (0, 6)) or tones[0] == tones[6]:
    problems.append(f"snapshots: {tones[0:1] + tones[6:7]}")
drive = [int(re.search(r"Control Change 30 = (\d+)", t).group(1)) if "Change 30 =" in t else -1 for t in tones[1:2] + tones[7:8]]
if drive != [42, 59]:  # clean: the top of the clean band, 1/3. Crunch: 0.57 less 0.3/3
    problems.append(f"drive knob: {drive}")
virtual = [l for l in open(sys.argv[2]) if "Program Change" in l or "Control Change" in l or "SysEx" in l]
if virtual:
    problems.append(f"sent on the virtual source too: {virtual[:2]}")
for name in ("program-changes.json", "stagehand.json", "hx-stomp.json", "hx-stomp-amps.json"):
    if not os.path.exists(os.path.join(sys.argv[3], name)):
        problems.append(f"{name} wasn't put in the profiles folder")
print("PASS" if not problems else "FAIL: " + "; ".join(problems))
sys.exit(1 if problems else 0)
PY
