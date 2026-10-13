#!/bin/bash
# Build and launch Pathfinder as a real .app bundle (keyboard shortcuts, notifications, Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=".build/out/Products/Debug/Pathfinder"
[ -x "$BIN" ] || BIN=".build/debug/Pathfinder"
APP=".build/Pathfinder.app"
rm -rf ".build/Pathfinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Pathfinder"
# SwiftPM resource bundles (e.g. the public-suffix list used by the ad-block converter) must sit in Resources,
# otherwise Bundle.module traps at launch.
mkdir -p "$APP/Contents/Resources"
cp Pathfinder/Resources/AppIcon.icns "$APP/Contents/Resources/"
for b in "$(dirname "$BIN")"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/Pathfinder/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.pathfinder.Pathfinder/' -e 's/$(PRODUCT_NAME)/Pathfinder/' \
    Pathfinder/Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
pkill -f "Contents/MacOS/Pathfinder" 2>/dev/null || true
open "$APP"
