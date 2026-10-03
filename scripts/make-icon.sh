#!/bin/bash
# Regenerates the app icon from app/Resources/AppIcon/generate_icon.py.
# Outputs: app/Resources/AppIcon/AppIcon.svg, app/Resources/AppIcon.icns, docs/images/icon.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/Resources/AppIcon"
SVG="$SRC/AppIcon.svg"
ICNS="$ROOT/app/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 "$SRC/generate_icon.py" "$SVG"

# Compile the rasterizer once instead of interpreting it per size.
swiftc -O "$SRC/render_png.swift" -o "$WORK/render_png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  "$WORK/render_png" "$SVG" "$ICONSET/icon_${size}x${size}.png" "$size"
  "$WORK/render_png" "$SVG" "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$ICONSET" -o "$ICNS"

# Image shown at the top of README.md / README_JP.md
mkdir -p "$ROOT/docs/images"
cp "$ICONSET/icon_256x256@2x.png" "$ROOT/docs/images/icon.png"

echo "$ICNS"
