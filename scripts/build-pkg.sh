#!/bin/bash
# Build Pathfinder as a Universal (Intel x86_64 + Apple Silicon arm64) macOS application and installer package (.pkg)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "===> Building Universal Release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

BIN=".build/out/Products/Release/Pathfinder"
if [ ! -f "$BIN" ]; then
    echo "Error: Release binary not found at $BIN" >&2
    exit 1
fi

echo "===> Verifying binary architectures..."
lipo -info "$BIN"

DIST_DIR="dist"
BUILD_APP_DIR=".build/release-app"
APP_NAME="Pathfinder"
APP="$BUILD_APP_DIR/$APP_NAME.app"
PKG_PATH="$DIST_DIR/$APP_NAME.pkg"

rm -rf "$BUILD_APP_DIR"
mkdir -p "$BUILD_APP_DIR"
mkdir -p "$DIST_DIR"

echo "===> Assembling $APP_NAME.app..."
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pathfinder"

if [ -f "Pathfinder/Resources/AppIcon.icns" ]; then
    cp "Pathfinder/Resources/AppIcon.icns" "$APP/Contents/Resources/"
fi

for bundle in .build/out/Products/Release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP/Contents/Resources/"
    fi
done

sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    -e 's/$(EXECUTABLE_NAME)/Pathfinder/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.pathfinder.Pathfinder/' \
    -e 's/$(PRODUCT_NAME)/Pathfinder/' \
    Pathfinder/Resources/Info.plist > "$APP/Contents/Info.plist"

echo "===> Signing app bundle (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "===> Creating installer package (.pkg)..."
rm -f "$PKG_PATH"
COPYFILE_DISABLE=1 productbuild --component "$APP" /Applications "$PKG_PATH"

echo "===> Package built successfully:"
ls -lh "$PKG_PATH"
echo "Package location: $(pwd)/$PKG_PATH"
echo "Architectures supported: Intel (x86_64) and Apple Silicon (arm64)"

