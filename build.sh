#!/bin/sh
# Build everything into build/ (the app has its own build: app/build.sh):
#   build/rsprobe               memory reader (signed with the debugger entitlement so it may read
#                               Rocksmith's memory without admin rights)
#   build/rstool                song file reader (index_songs.py uses it)
#   build/librscompanion.dylib  the in-game library, for the tests
# Requires: Xcode command line tools (clang, codesign).
set -e
cd "$(dirname "$0")"
mkdir -p build
clang -O2 -Wall -o build/rsprobe native/rsprobe.c
codesign -s - -f --entitlements native/debugger.entitlements build/rsprobe
# Song file reader (rsfile.c) with its command-line tool, and the in-game library (x86_64: the
# game runs under Rosetta). The app bundles its own copy of the library and installs it; this one
# is for the tests.
clang -O2 -Wall -o build/rstool native/rstool.c native/rsfile.c -lz
clang -arch x86_64 -O2 -Wall -dynamiclib -install_name @executable_path/librscompanion.dylib \
  -o build/librscompanion.dylib native/rscompanion.c native/rscore.c native/rsfile.c -lz
codesign -s - -f build/librscompanion.dylib
echo "built build/rsprobe, build/rstool and build/librscompanion.dylib"
