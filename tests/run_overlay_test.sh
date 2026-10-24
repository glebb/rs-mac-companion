#!/bin/sh
# End-to-end test of the RockSniffer-compatible stream overlays without the game (about 35 s):
# the in-game dylib runs in the stand-in (tests/standin_dylib.c, "notones": Self Trap's bass,
# with note-stats and Score Attack objects counting a hit per second), and the app (app/), with
# overlay_enabled on port 19938, serves RockSniffer's addon API. Checks:
#   - GET /: RockSniffer's JSON (success, currentState 4 = playing, memoryReadout in Score
#     Attack with its noteData, the arrangement's PersistentID) and songDetails read from the
#     game's songs.psarc (names, length, year, 3 arrangements with tuning, numbered sections,
#     phrase iterations and measures, vocals, album art as JPEG, the archive's MD5), CORS headers,
#   - /addons/ index, generated config.js with the port, files, no way out of the folder,
#   - /storage PUT and GET (and "null" for a missing key),
#   - refused: another Host (DNS rebinding), a PUT from another website's page, a negative
#     Content-Length (400, and the app keeps serving),
#   - the OBS text files and album_cover.jpeg in DATA_DIR/output,
#   - state 0 (no game) a few seconds after the game is gone.
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
clang -arch x86_64 -O1 -o build/rs-standin-dylib tests/standin_dylib.c
SNG=$(build/rstool toc "$ARCHIVE" | awk '$4 == "songs/bin/macos/selftrap_rhythm.sng" {print $1}')
AUDIO=$(build/rstool toc "$ARCHIVE" | awk '$4 ~ /\.wem$/ {print $1; exit}')

DATA=$(mktemp -d /tmp/rsc.XXXXXX)  # short: socket paths are limited to 104 characters
APP_BIN="app/build/RS Companion.app/Contents/MacOS/RSCompanion"
APP= STANDIN=
trap 'kill $APP $STANDIN 2>/dev/null || true; wait 2>/dev/null; rm -rf "$DATA"' EXIT
URL=http://127.0.0.1:19938

echo '{"overlay_enabled": true, "overlay_port": 19938}' > "$DATA/rscompanion.json"
RS_COMPANION_DATA="$DATA" "$APP_BIN" & APP=$!
sleep 2
RS_COMPANION_DATA="$DATA" DYLD_INSERT_LIBRARIES="$PWD/build/librscompanion.dylib" \
  build/rs-standin-dylib "$ARCHIVE" "$SNG" "$AUDIO" notones & STANDIN=$!
sleep 28  # the song plays from 5 s; the stats objects are found within ~10 s of that
curl -s -D "$DATA/head.txt" -o "$DATA/state.json" $URL/
curl -s -o "$DATA/index.html" $URL/addons/
curl -s -o "$DATA/config.js" $URL/addons/config.js
curl -s -o /dev/null -w '%{http_code} ' $URL/addons/_deps/sniffer-poller.js > "$DATA/codes.txt"
curl -s -o /dev/null -w '%{http_code} ' --path-as-is $URL/addons/../LICENSE >> "$DATA/codes.txt"
curl -s -o /dev/null -w '%{http_code}' $URL/addons/timeline/nothing.js >> "$DATA/codes.txt"
curl -s -X PUT --data '{"best": 42}' $URL/storage/test_addon/scores > /dev/null
curl -s -o "$DATA/stored.txt" $URL/storage/test_addon/scores
curl -s -o "$DATA/missing.txt" $URL/storage/test_addon/nothing
curl -s -o /dev/null -w '%{http_code} ' -H 'Host: evil.example:19938' $URL/ > "$DATA/refused.txt"
curl -s -o /dev/null -w '%{http_code} ' -X PUT -H 'Origin: https://evil.example' --data '"evil"' \
  $URL/storage/test_addon/scores >> "$DATA/refused.txt"
curl -s -o /dev/null -w '%{http_code} ' -X PUT -H "Origin: http://localhost:19938" --data '"mine"' \
  $URL/storage/test_addon/page >> "$DATA/refused.txt"
printf 'PUT /storage/test_addon/neg HTTP/1.1\r\nHost: 127.0.0.1:19938\r\nContent-Length: -1\r\n\r\n' \
  | nc -w 2 127.0.0.1 19938 | head -1 | tr -d '\r' > "$DATA/negative.txt"
curl -s -o "$DATA/stored_after.txt" $URL/storage/test_addon/scores
curl -s -o "$DATA/page.txt" $URL/storage/test_addon/page
cp -R "$DATA/output" "$DATA/output_playing" 2>/dev/null || true
kill $STANDIN; wait $STANDIN 2>/dev/null || true
sleep 5
curl -s -o "$DATA/gone.json" $URL/
kill $APP; wait $APP 2>/dev/null || true

echo "app log:"; grep overlays "$DATA/rs-companion-app.log" | sed 's/^/  /'
python3 - "$DATA" "$ARCHIVE" <<'EOF'
import base64, hashlib, json, os, sys
data, archive = sys.argv[1], sys.argv[2]
def text(name):
    try: return open(os.path.join(data, name)).read()
    except OSError: return None
problems = []
def check(ok, what):
    if not ok: problems.append(what)

s = json.loads(text("state.json") or "{}")
r, d = s.get("memoryReadout") or {}, s.get("songDetails") or {}
nd = r.get("noteData") or {}
print("  state", s.get("currentState"), "readout", {k: v for k, v in r.items() if k != "noteData"})
print("  noteData", nd)
check(s.get("success") is True and s.get("currentState") == 4 and s.get("Version"), "GET /: success, state 4, Version")
check(r.get("songID") == "SelfTrap" and r.get("arrangementID") == "B1B5DF1DC1BAD5E34DF5402354E21802"
      and r.get("mode") == 2 and r.get("gameStage") == "" and 20 <= r.get("songTimer", 0) <= 26,
      "memoryReadout: SelfTrap, the bass's PersistentID, Score Attack, the song time")
check(15 <= nd.get("TotalNotesHit", 0) <= 26 and nd.get("TotalNotes") == nd.get("TotalNotesHit")
      and nd.get("Accuracy") == 100 and nd.get("CurrentScore") == nd.get("TotalNotesHit", 0) * 100
      and nd.get("CurrentMultiplier") == 1 and "PerfectPhrases" in nd and "HighestFailedPhraseStreak" in nd,
      "noteData: Score Attack fields, hits = song seconds")
arrs = {a["name"]: a for a in d.get("arrangements", [])}
bass = arrs.get("Bass", {})
print("  song", d.get("songName"), "-", d.get("artistName"), d.get("albumName"), d.get("albumYear"),
      d.get("songLength"), sorted(arrs), "vocals", len(d.get("vocals", [])))
print("  bass", bass.get("type"), bass.get("tuning", {}).get("TuningName"), bass.get("sections", [{}])[:2],
      len(bass.get("phraseIterations", [])), "phrase iterations,", len((bass.get("data") or {}).get("Measures", [])), "measures")
check(d.get("songID") == "SelfTrap" and d.get("songName") == "Self Trap" and d.get("artistName") == "Playground Kings"
      and d.get("albumName") == "Blackhole Sessions" and d.get("albumYear") == 2007 and abs(d.get("songLength", 0) - 177.441) < 0.01
      and d.get("NumArrangements") == 3 and sorted(arrs) == ["Bass", "Combo", "Rhythm"], "songDetails: song fields")
check(bass.get("type") == "Bass" and bass.get("tuning", {}).get("TuningName") == "E Standard"
      and bass.get("isBonusArrangement") is False and bass.get("isAlternateArrangement") is False
      and [x["name"] for x in bass.get("sections", [])[:2]] == ["noguitar 1", "verse 1"]
      and bass.get("phraseIterations", [{}])[1].get("name") == "A 1"
      and len((bass.get("data") or {}).get("Measures", [])) > 30, "songDetails: the bass arrangement")
check(len(d.get("vocals", [])) > 50 and all(k in d["vocals"][0] for k in ("Time", "Note", "Length", "Lyric")), "songDetails: vocals")
art = base64.b64decode(d.get("albumArt") or "")
check(art[:3] == b"\xff\xd8\xff", "songDetails: album art as JPEG")
md5 = hashlib.md5()
with open(archive, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""): md5.update(chunk)
check(d.get("psarcFileHash") == base64.b64encode(md5.digest()).decode(), "songDetails: psarcFileHash")
head = (text("head.txt") or "").lower()
check("access-control-allow-origin: *" in head and "content-type: text/json" in head, "GET /: headers")

check("current_song_v4/current_song.html" in (text("index.html") or "") and "_deps" not in (text("index.html") or ""),
      "/addons/ index")
check("var port = 19938;" in (text("config.js") or ""), "/addons/config.js with the port")
print("  codes", text("codes.txt"))
check(text("codes.txt") == "200 404 404", "/addons files: found, no way out, missing")
check(text("stored.txt") == '{"best": 42}' and text("missing.txt") == "null", "/storage round trip")
print("  refused", text("refused.txt"), "negative length:", text("negative.txt"))
check(text("refused.txt") == "403 403 200 " and text("page.txt") == '"mine"',
      "403 for another Host and another website's PUT; the addons' own origin may PUT")
check(text("stored_after.txt") == '{"best": 42}', "the refused PUT wrote nothing")
check((text("negative.txt") or "").strip() == "HTTP/1.1 400 Bad Request", "negative Content-Length: 400")

out = os.path.join(data, "output_playing")
files = {f: open(os.path.join(out, f), "rb").read() for f in os.listdir(out)} if os.path.isdir(out) else {}
print("  output", {f: v.decode() for f, v in files.items() if f.endswith(".txt")})
check(files.get("song_details.txt") == b"Playground Kings - Self Trap"
      and files.get("album_details.txt") == b"Blackhole Sessions (2007)"
      and files.get("song_timer.txt", b"").endswith(b"/02:58") and files.get("accuracy.txt") == b"100.00%"
      and files.get("album_cover.jpeg", b"")[:3] == b"\xff\xd8\xff", "output files")

gone = json.loads(text("gone.json") or "{}")
check(gone.get("currentState") == 0, f"state 0 after the game is gone (got {gone.get('currentState')})")
for p in problems: print("  FAIL:", p)
print("FAIL" if problems else "PASS")
sys.exit(1 if problems else 0)
EOF
