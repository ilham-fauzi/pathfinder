#!/bin/bash
# Builds Pathfinder/Resources/AppIcon.icns from design/AppIcon-1024.png (run scripts/make-icon.swift first).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="design/AppIcon-1024.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Pathfinder/Resources/AppIcon.icns
echo "wrote Pathfinder/Resources/AppIcon.icns"
