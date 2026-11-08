#!/bin/sh
# Build and test lp_probe (tools/lp_probe.c), the Learn & Play memory probe:
#   tools/lp_probe.sh            self-test on a fake guest window, the index lookup against the game
#                                folder, then build/lp_probe.dylib (needs RS Re-ARMed's source:
#                                RS_REARMED_SRC, default ~/src/rs-rearmed)
#   tools/lp_probe.sh install    also copy it into Learn & Play's mods folder
#   tools/lp_probe.sh remove     take it out again
set -e
cd "$(dirname "$0")/.."
MODS="$HOME/Library/Application Support/RS Re-ARMed/learn-play/mods"
if [ "$1" = remove ]; then rm -f "$MODS/lp_probe.dylib"; echo "removed"; exit 0; fi
SRC="${RS_REARMED_SRC:-$HOME/src/rs-rearmed}"
RT="$SRC/tools/ws7/recomp/runtime"
mkdir -p build
clang -O2 -Wall -DLP_PROBE_TEST -o build/lp_probe_test tools/lp_probe.c native/rsfile.c -lz
build/lp_probe_test > build/lp_probe_test.out 2>&1
grep -q 'image pointer 01d00100 at name-0x14: 3 of 3 names, 4 objects' build/lp_probe_test.out
grep -q 'testkey_lead: 2 copies of the text, 2 string objects' build/lp_probe_test.out
grep -q 'testkey_bass_alternate: 1 copies of the text, 1 string objects' build/lp_probe_test.out
grep -q 'play: 06800000 changed at: +18 +1c' build/lp_probe_test.out
grep -q 'stats: type 01d00300: 1 objects' build/lp_probe_test.out
grep -q 'stats: type 01d00400: 1 objects' build/lp_probe_test.out
grep -q 'stats: 2 objects' build/lp_probe_test.out
grep -q 'timer: 07000008 = ' build/lp_probe_test.out
echo "self-test passed"
if [ -d "$HOME/Library/Application Support/RS Re-ARMed/learn-play/game/dlc" ]; then
  build/lp_probe_test abbadanc | grep -q '^abbadanc_lead$' && echo "index lookup passed (abbadanc)"
fi
clang -arch arm64 -O2 -Wall -Wno-unused-parameter -dynamiclib -undefined dynamic_lookup -I"$RT" \
  -I"$SRC/tools/ws7/recomp/overrides" -I"$SRC/shims/include" -o build/lp_probe.dylib tools/lp_probe.c native/rsfile.c -lz
codesign -s - -f build/lp_probe.dylib
nm build/lp_probe.dylib | grep -q _rc_mod_abi
echo "built build/lp_probe.dylib"
if [ "$1" = install ]; then cp build/lp_probe.dylib "$MODS/" && echo "installed in $MODS"; fi
