#!/bin/sh
# Builds "RS Companion.app" (menu-bar only, no Dock icon) into app/build/. No Xcode project.
# The app contains the in-game library (librscompanion.dylib), which it installs into Rocksmith,
# the RockNRoller library (librnrcompanion.dylib), which RockNRoller loads when opened from it,
# and RockSniffer's overlay pages (third_party/rocksniffer-addons), which it serves.
# Usage: app/build.sh [--run | --install | --release]
#   --run      also (re)starts it from app/build/
#   --install  also copies it to /Applications and (re)starts it from there
#   --release  builds it for Apple Silicon and Intel and zips it into app/build/RS-Companion.zip
set -e
cd "$(dirname "$0")"
VERSION=1.3.1
APP="build/RS Companion.app"
# This Mac's architecture, or both for a release.
ARCHS=$(uname -m)
[ "$1" = --release ] && ARCHS="arm64 x86_64"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ../presets.default.json "$APP/Contents/Resources/"  # seeds DATA_DIR/presets.json if missing
cp -R ../third_party/rocksniffer-addons "$APP/Contents/Resources/addons"
# The in-game library: x86_64 for the Steam game (Rosetta), arm64 for RS Re-ARMed (native port).
clang -arch x86_64 -arch arm64 -O2 -Wall -dynamiclib -install_name @executable_path/librscompanion.dylib \
  -o "$APP/Contents/Resources/librscompanion.dylib" ../native/rscompanion.c ../native/rscore.c ../native/rsfile.c -lz
codesign -s - -f "$APP/Contents/Resources/librscompanion.dylib" >/dev/null 2>&1
# The library RockNRoller loads when opened from the app: arm64, like RockNRoller.
clang -arch arm64 -O2 -Wall -dynamiclib -install_name @rpath/librnrcompanion.dylib \
  -o "$APP/Contents/Resources/librnrcompanion.dylib" ../native/rnrcompanion.c ../native/rscore.c ../native/rsfile.c -lz
codesign -s - -f "$APP/Contents/Resources/librnrcompanion.dylib" >/dev/null 2>&1
# The app reads song archives for the overlays with the same reader (native/rsfile.c).
mkdir -p build/obj
for ARCH in $ARCHS; do
  clang -arch "$ARCH" -mmacosx-version-min=14.0 -O2 -Wall -c ../native/rsfile.c -o "build/obj/rsfile-$ARCH.o"
  swiftc -O -parse-as-library -target "$ARCH-apple-macos14.0" -import-objc-header Sources/rsfile-bridge.h \
    Sources/*.swift "build/obj/rsfile-$ARCH.o" -lz -o "build/obj/RSCompanion-$ARCH"
done
lipo -create build/obj/RSCompanion-* -output "$APP/Contents/MacOS/RSCompanion"
rm -f build/obj/RSCompanion-*
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.rs-mac-companion</string>
  <key>CFBundleName</key><string>RS Companion</string>
  <key>CFBundleExecutable</key><string>RSCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - -f "$APP" >/dev/null 2>&1
echo "built app/$APP $VERSION ($ARCHS)"
case "$1" in
  --run)
    pkill -x RSCompanion 2>/dev/null || true
    open "$APP" ;;
  --install)
    pkill -x RSCompanion 2>/dev/null || true
    rm -rf "/Applications/RS Companion.app"
    ditto "$APP" "/Applications/RS Companion.app"
    echo "installed /Applications/RS Companion.app"
    open "/Applications/RS Companion.app" ;;
  --release)
    # A zip keeps the app's signature and executable bits as downloaded.
    rm -f build/RS-Companion.zip
    ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" build/RS-Companion.zip
    echo "built app/build/RS-Companion.zip" ;;
esac
