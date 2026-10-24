#!/bin/sh
# Tests the app's installer (app/Sources/GameInstaller.swift, MachOPatcher.swift) on a COPY of the
# game executable in a temporary folder, through the app's command-line mode. The real game is
# not touched (it may even be running).
# Source executable: the backup Rocksmith2014.orig if present (as installed by hand earlier),
# else the game's executable; it must not contain the companion already.
set -e
cd "$(dirname "$0")/.."
GAME_DIR=${RS_GAME_DIR:-"$HOME/Library/Application Support/Steam/steamapps/common/Rocksmith2014"}
SRC="$GAME_DIR/Rocksmith2014.app/Contents/MacOS/Rocksmith2014.orig"
[ -f "$SRC" ] || SRC="$GAME_DIR/Rocksmith2014.app/Contents/MacOS/Rocksmith2014"
if otool -arch x86_64 -L "$SRC" | grep -q librscompanion; then echo "$SRC already has the companion" >&2; exit 1; fi
app/build.sh > /dev/null
APPBIN="app/build/RS Companion.app/Contents/MacOS/RSCompanion"
BUNDLED="app/build/RS Companion.app/Contents/Resources/librscompanion.dylib"

T=$(mktemp -d /tmp/rsi.XXXXXX)
trap 'rm -rf "$T"' EXIT
G="$T/Rocksmith2014"
M="$G/Rocksmith2014.app/Contents/MacOS"
mkdir -p "$M" "$T/data"
cp "$SRC" "$T/original"
fresh() { rm -f "$M"/*; cp "$T/original" "$M/Rocksmith2014"; }
run() { RS_COMPANION_DATA="$T/data" "$APPBIN" "$@" "$G"; }
last() { otool -arch x86_64 -L "$M/Rocksmith2014" | tail -1 | awk '{print $1}'; }
fails=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }
ndylibs() { otool -arch x86_64 -L "$1" | tail -n +2 | wc -l | tr -d ' '; }

echo "1. fresh install"
fresh
check "status: not installed" '[ "$(run --game-status)" = "Not installed in Rocksmith" ]'
run --install-game | sed 's/^/    /'
check "status: installed" '[ "$(run --game-status)" = "Installed in Rocksmith" ]'
check "load command added last" '[ "$(last)" = "@executable_path/librscompanion.dylib" ]'
check "exactly one more library" '[ $(ndylibs "$M/Rocksmith2014") = $(( $(ndylibs "$T/original") + 1 )) ]'
check "custom-song patch kept" 'otool -arch x86_64 -L "$M/Rocksmith2014" | grep -q libRSBypass || ! otool -arch x86_64 -L "$T/original" | grep -q libRSBypass'
check "library is the bundled one" 'cmp -s "$M/librscompanion.dylib" "$BUNDLED"'
check "library not quarantined" '! xattr "$M/librscompanion.dylib" | grep -q quarantine'
check "backup is the original" 'cmp -s "$M/Rocksmith2014.orig" "$T/original"'
check "executable still executable" '[ -x "$M/Rocksmith2014" ]'
check "i386 part untouched" 'lipo -thin i386 "$M/Rocksmith2014" -output "$T/a" && lipo -thin i386 "$T/original" -output "$T/b" && cmp -s "$T/a" "$T/b"'
check "only 48 bytes or so changed" '[ $(cmp -l "$M/Rocksmith2014" "$T/original" | wc -l) -le 64 ]'
cp "$M/Rocksmith2014" "$T/installed"

echo "2. install again changes nothing"
run --install-game > /dev/null
check "executable unchanged" 'cmp -s "$M/Rocksmith2014" "$T/installed"'
check "backup unchanged" 'cmp -s "$M/Rocksmith2014.orig" "$T/original"'

echo "3. prototype install (librscompanion_test.dylib) is migrated"
fresh
cp "$M/Rocksmith2014" "$M/Rocksmith2014.orig"
python3 tools/add_load_dylib.py "$T/original" "$M/Rocksmith2014" @executable_path/librscompanion_test.dylib > /dev/null
cp "$BUNDLED" "$M/librscompanion_test.dylib"
check "status: update available" '[ "$(run --game-status)" = "Installed; an update is available" ]'
run --install-game | sed 's/^/    /'
check "only the new load command" '[ "$(last)" = "@executable_path/librscompanion.dylib" ] && ! otool -arch x86_64 -L "$M/Rocksmith2014" | grep -q _test'
check "same bytes as a fresh install" 'cmp -s "$M/Rocksmith2014" "$T/installed"'
check "old library deleted" '[ ! -e "$M/librscompanion_test.dylib" ]'
check "backup still the original" 'cmp -s "$M/Rocksmith2014.orig" "$T/original"'

echo "4. a changed library is updated"
printf x >> "$M/librscompanion.dylib"
check "status: update available" '[ "$(run --game-status)" = "Installed; an update is available" ]'
run --install-game > /dev/null
check "library replaced" 'cmp -s "$M/librscompanion.dylib" "$BUNDLED"'

echo "5. uninstall"
run --uninstall-game | sed 's/^/    /'
check "executable byte-identical to the original" 'cmp -s "$M/Rocksmith2014" "$T/original"'
check "library removed" '[ ! -e "$M/librscompanion.dylib" ]'
check "backup kept" '[ -e "$M/Rocksmith2014.orig" ]'
check "status: not installed" '[ "$(run --game-status)" = "Not installed in Rocksmith" ]'

echo "6. no game"
check "status: not found" '[ "$(RS_COMPANION_DATA="$T/data" "$APPBIN" --game-status "$T/nothing")" = "Rocksmith not found" ]'
check "install fails cleanly" '! RS_COMPANION_DATA="$T/data" "$APPBIN" --install-game "$T/nothing" > /dev/null'

echo "6b. a damaged executable is an error, not a crash"
fresh
printf '\312\376\272\276\000\000\020\000' > "$M/Rocksmith2014"  # fat header claiming 4096 architectures
head -c 24 /dev/zero >> "$M/Rocksmith2014"
check "fat header past the end: status reports it" 'run --game-status | grep -q "^Cannot read the game executable"'
check "fat header past the end: install fails cleanly" '(run --install-game > /dev/null 2>&1; [ $? = 1 ])'
head -c 4000 "$T/original" > "$M/Rocksmith2014"
check "truncated executable: status reports it" 'run --game-status | grep -q "^Cannot read the game executable"'

echo "7. finding the game in Steam's libraries"
S="$T/steam"
find_game() { RS_STEAM_DIR="$S" "$APPBIN" --find-game; }
fake_game() { mkdir -p "$1/Rocksmith2014.app/Contents/MacOS" && touch "$1/Rocksmith2014.app/Contents/MacOS/Rocksmith2014"; }
mkdir -p "$S/steamapps" "$T/drive 2/steamapps"
printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' \
  "$S" "$T/drive 2" > "$S/steamapps/libraryfolders.vdf"
printf '"AppState"\n{\n\t"appid"\t\t"221680"\n\t"installdir"\t\t"Rocksmith Renamed"\n}\n' > "$T/drive 2/steamapps/appmanifest_221680.acf"
fake_game "$T/drive 2/steamapps/common/Rocksmith Renamed"
check "in another library, in the folder its manifest names" '[ "$(find_game)" = "$T/drive 2/steamapps/common/Rocksmith Renamed" ]'
fake_game "$S/steamapps/common/Rocksmith2014"
check "Steam's own library first" '[ "$(find_game)" = "$S/steamapps/common/Rocksmith2014" ]'

[ $fails = 0 ] && echo PASS || { echo "FAIL ($fails)"; exit 1; }
