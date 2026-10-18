#!/bin/bash
# Build, sign and (optionally) publish a Pathfinder release.
#   scripts/release.sh             build the .pkg and the signed update zip into dist/
#   scripts/release.sh --publish   also tag, create the GitHub release and bump the Homebrew cask
# The version comes from Pathfinder/Resources/Info.plist (CFBundleShortVersionString).
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

REPO="ilham-fauzi/pathfinder"
TAP_DIR="${TAP_DIR:-$(cd .. && pwd)/homebrew-tap}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Pathfinder/Resources/Info.plist)
TAG="v$VERSION"
ZIP="dist/pathfinder-$TAG.zip"

echo "===> Releasing Pathfinder $VERSION"

# The app only trusts updates signed by the key it was built with.
EMBEDDED=$(grep -o 'publicKey = "[^"]*"' Pathfinder/Services/Updater/UpdateLogic.swift | cut -d'"' -f2)
ACTUAL=$(swift scripts/update-key.swift public)
if [ "$EMBEDDED" != "$ACTUAL" ]; then
    echo "Error: signing key does not match UpdateLogic.publicKey; installed apps would reject this update." >&2
    exit 1
fi

./scripts/build-pkg.sh

echo "===> Creating signed update archive..."
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent ".build/release-app/Pathfinder.app" "$ZIP"
swift scripts/update-key.swift sign "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "sha256: $SHA"

if [ "$PUBLISH" -eq 0 ]; then
    echo "Built $ZIP, $ZIP.sig and dist/Pathfinder.pkg. Re-run with --publish to release."
    exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: commit your changes before publishing (the tag must match what was built)." >&2
    exit 1
fi

echo "===> Tagging $TAG and creating the GitHub release..."
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sig" dist/Pathfinder.pkg \
    --repo "$REPO" --title "Pathfinder $VERSION" --generate-notes

echo "===> Updating Homebrew cask in $TAP_DIR..."
CASK="$TAP_DIR/Casks/pathfinder.rb"
perl -pi -e 's/^(\s*version\s+)"[^"]*"/$1"'"$VERSION"'"/; s/^(\s*sha256\s+)"[^"]*"/$1"'"$SHA"'"/' "$CASK"
git -C "$TAP_DIR" add Casks/pathfinder.rb
git -C "$TAP_DIR" commit -m "Update pathfinder to $TAG"
git -C "$TAP_DIR" push
echo "===> Done: https://github.com/$REPO/releases/tag/$TAG"
