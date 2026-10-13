#!/bin/bash
# Build Pathfinder as a Universal macOS .app and zip it for a GitHub Release / Homebrew cask.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Pathfinder/Resources/Info.plist)
ZIP_PATH="dist/Pathfinder-$VERSION.zip"

# build-pkg.sh assembles .build/release-app/Pathfinder.app; reuse it, then zip the app.
./scripts/build-pkg.sh

rm -f "$ZIP_PATH"
ditto -c -k --keepParent ".build/release-app/Pathfinder.app" "$ZIP_PATH"

echo "===> Zip built successfully:"
ls -lh "$ZIP_PATH"
echo "sha256: $(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
