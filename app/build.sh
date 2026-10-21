#!/bin/sh
# Builds "RS Companion.app" (menu-bar only, no Dock icon) into app/build/. No Xcode project.
# The app contains the in-game library (librscompanion.dylib), which it installs into Rocksmith,
# and RockSniffer's overlay pages (third_party/rocksniffer-addons), which it serves.
# Usage: app/build.sh [--run | --install]
#   --run      also (re)starts it from app/build/
#   --install  also copies it to /Applications and (re)starts it from there
set -e
cd "$(dirname "$0")"
APP="build/RS Companion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ../presets.default.json "$APP/Contents/Resources/"  # seeds DATA_DIR/presets.json if missing
cp -R ../third_party/rocksniffer-addons "$APP/Contents/Resources/addons"
# The in-game library: x86_64, because the game runs under Rosetta.
clang -arch x86_64 -O2 -Wall -dynamiclib -install_name @executable_path/librscompanion.dylib \
  -o "$APP/Contents/Resources/librscompanion.dylib" ../native/rscompanion.c ../native/rsfile.c -lz
codesign -s - -f "$APP/Contents/Resources/librscompanion.dylib" >/dev/null 2>&1
# The app reads song archives for the overlays with the same reader (native/rsfile.c).
mkdir -p build/obj
clang -arch "$(uname -m)" -mmacosx-version-min=14.0 -O2 -Wall -c ../native/rsfile.c -o build/obj/rsfile.o
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" -import-objc-header Sources/rsfile-bridge.h \
  Sources/*.swift build/obj/rsfile.o -lz -o "$APP/Contents/MacOS/RSCompanion"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.rs-mac-companion</string>
  <key>CFBundleName</key><string>RS Companion</string>
  <key>CFBundleExecutable</key><string>RSCompanion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -s - -f "$APP" >/dev/null 2>&1
echo "built app/$APP"
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
esac
