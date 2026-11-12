#!/bin/sh
# How the in-game library (native/rscompanion.c) sees a song load in RS Re-ARMed's Mac edition, without
# the game: against tests/standin_lp.c as the Mac edition ("mac"), which plays RS Re-ARMed's part (its
# mod interface) and the game's as far as a song's load: the song's archive open, and each of its .sng
# opened through FrontEnd_OpenFile. Checks, in about 7 s: one song load (18 And Life) from the archive
# the game has open, with its arrangements, and none selected by the open (the Mac edition opens them
# all; the memory scan selects).
# Needs RS Re-ARMed's game folder with dlc/skid18an_m.psarc (RS_REARMED_GAME_DIR, default RS Re-ARMed's);
# skipped without it. Everything else goes to a temporary folder.
set -e
cd "$(dirname "$0")/.."
ARCHIVE="${RS_REARMED_GAME_DIR:-$HOME/Library/Application Support/RS Re-ARMed/game}/dlc/skid18an_m.psarc"
if [ ! -f "$ARCHIVE" ]; then echo "skipped: no $ARCHIVE"; exit 0; fi
mkdir -p build
clang -arch arm64 -O2 -Wall -dynamiclib -o build/librscompanion-lp-test.dylib native/rscompanion.c native/rscore.c \
  native/rsfile.c -lz
codesign -s - -f build/librscompanion-lp-test.dylib 2> /dev/null
clang -arch arm64 -O1 -Wall -o build/rs-standin-lp tests/standin_lp.c

HOME_DIR=$(mktemp -d /tmp/rsl.XXXXXX)
trap 'rm -rf "$HOME_DIR"' EXIT
DATA="$HOME_DIR/Library/Application Support/rs-mac-companion"
mkdir -p "$DATA"
LOG="$DATA/rscompanion.log"
HOME="$HOME_DIR" build/rs-standin-lp "$PWD/build/librscompanion-lp-test.dylib" skid18an_lead Skid18an 5 mac "$ARCHIVE" \
  > "$HOME_DIR/standin.out"
sed 's/^/  standin: /' "$HOME_DIR/standin.out"
grep -v 'known memory tags' "$LOG" | sed 's/^/  log: /'
LOADS=$(grep -c "song skid18an loaded by the game from " "$LOG" || true)
if [ "$LOADS" != 1 ] || ! grep -q "loaded by the game from .*dlc/skid18an_m.psarc" "$LOG" \
    || ! grep -q "skid18an_lead: Base=" "$LOG" || grep -q "selected arrangement" "$LOG" \
    || ! grep -q "RS Re-ARMed: songs are seen as the game opens their .sng" "$LOG"; then
  echo "FAIL: expected one load of skid18an from $ARCHIVE (loads: $LOADS), its arrangements, none selected"
  exit 1
fi
echo PASS
