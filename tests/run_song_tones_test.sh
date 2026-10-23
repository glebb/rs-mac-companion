#!/bin/sh
# End-to-end test of song-made tones (app/Sources/SongTones.swift) without the game, like
# run_app_test.sh: the in-game dylib runs in the stand-in (tests/standin_dylib.c) with Self Trap
# (Rhythm, comes with the game), the app has "song_tones" on, and tools/midi_monitor.swift prints
# what it sends (about 50 s). Expected: one SysEx when the song loads, manufacturer 0x7D then
# JSON (v2) naming the style and the song's two tones in the order they first play (SelfTrap_clean
# on Program Change 8, SelfTrap_dist on 9, both without delay or modulation); then Program Change
# 8 at song start and 9 at the first change (~40 s, from the banner), on MIDI channel 1. Each
# tone's category is the one the app picks when that tone plays.
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
trap 'kill $APP $MONITOR $STANDIN 2>/dev/null || true; wait 2>/dev/null; rm -rf "$DATA"' EXIT

cp presets.default.json "$DATA/presets.json"
echo '{"song_tones": true}' > "$DATA/rscompanion.json"
RS_COMPANION_DATA="$DATA" "$APP_BIN" & APP=$!
build/midi_monitor > "$DATA/midi.txt" & MONITOR=$!
sleep 2
RS_COMPANION_DATA="$DATA" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
  build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" & STANDIN=$!
sleep 46
kill $APP $MONITOR $STANDIN; wait 2>/dev/null || true

echo "app log:"; sed 's/^/  /' "$DATA/rs-companion-app.log"
echo "MIDI:"; sed 's/^/  /' "$DATA/midi.txt"
python3 - "$DATA/midi.txt" "$DATA/rs-companion-app.log" <<'EOF'
import json, re, sys
lines = [l.split(": ", 1)[1].strip() for l in open(sys.argv[1]) if ": " in l and ("SysEx" in l or "Program Change" in l)]
problems = []
sysex = [l for l in lines if l.startswith("SysEx")]
if len(sysex) != 1:
    problems.append(f"expected one SysEx, got {len(sysex)}")
else:
    raw = sysex[0].split(" bytes: ", 1)[1]
    if not raw.startswith("\x7d"):
        problems.append("SysEx doesn't start with manufacturer 0x7D")
    msg = json.loads(raw[1:])
    tones = [(t["program"], t["key"]) for t in msg["tones"]]
    if msg.get("styles") != ["Soft", "Classic rock", "Metal"]:
        problems.append(f"styles: {msg.get('styles')}")
    if (msg.get("v") != 2 or msg.get("kind") != "song-tones" or msg.get("song") != "Self Trap" or not msg.get("style")
            or msg.get("arrangement") != "selftrap_rhythm" or not isinstance(msg.get("heaviness"), (int, float))):
        problems.append(f"unexpected message header: { {k: msg.get(k) for k in ('v', 'kind', 'song', 'arrangement', 'style', 'heaviness')} }")
    if tones != [(8, "SelfTrap_clean"), (9, "SelfTrap_dist")]:
        problems.append(f"tones: {tones}")
    for t in msg["tones"]:
        if "delay" in t["effects"] or "modulation" in t["effects"]:
            problems.append(f"{t['key']}: expected no delay or modulation, got {t['effects']}")
    # Each song tone has the category the tone gets when it plays (amp and gain included).
    played = dict(re.findall(r"tone \S+ (\S+) \[.*?\] from .* → (\w[\w ]*?) \(", open(sys.argv[2]).read()))
    for t in msg["tones"]:
        if t["key"] in played and t["category"] != played[t["key"]]:
            problems.append(f"{t['key']}: category {t['category']}, but plays as {played[t['key']]}")
    if not any(t["key"] in played for t in msg["tones"]):
        problems.append("no played tone in the app log to compare the categories with")
pcs = [l for l in lines if l.startswith("Program Change")]
if pcs != ["Program Change 8 ch 1", "Program Change 9 ch 1"]:
    problems.append(f"Program Changes: {pcs}")
if lines and not lines[0].startswith("SysEx"):
    problems.append("the SysEx should come before the first Program Change")
print("PASS" if not problems else "FAIL: " + "; ".join(problems))
sys.exit(1 if problems else 0)
EOF
