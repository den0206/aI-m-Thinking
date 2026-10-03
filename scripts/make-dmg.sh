#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-path> <output.dmg> [volume-name]" >&2
  exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"
DEFAULT_VOLUME_NAME="aI'm Thinking"
VOLUME_NAME="${3:-$DEFAULT_VOLUME_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
STAGING="$WORK_DIR/staging"

MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="$(basename "$APP_PATH")"
RW_DMG="$WORK_DIR/rw.dmg"

mkdir -p "$STAGING/.background"
ditto "$APP_PATH" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"

# Background: 1x + 2x in one TIFF so Retina displays stay sharp.
RENDER="$ROOT/app/Resources/AppIcon/render_png.swift"
BG_SVG="$ROOT/app/Resources/DmgBackground.svg"
swift "$RENDER" "$BG_SVG" "$WORK_DIR/bg.png" 660 400
swift "$RENDER" "$BG_SVG" "$WORK_DIR/bg@2x.png" 1320 800
tiffutil -cathidpicheck "$WORK_DIR/bg.png" "$WORK_DIR/bg@2x.png" -out "$STAGING/.background/background.tiff" >/dev/null 2>&1

# On GitHub's macOS runners hdiutil create intermittently fails with "Resource busy"
# while the same commit succeeds on another run, so retry only that error.
for attempt in 1 2 3; do
  if output="$(hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG" 2>&1)"; then
    break
  fi
  if [[ "$output" != *"Resource busy"* || "$attempt" == 3 ]]; then
    echo "$output" >&2
    exit 1
  fi
  echo "hdiutil create: Resource busy, retrying ($attempt/3)" >&2
  sleep 5
done
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk -F '\t' '/\/Volumes\// { print $NF }')"
# hdiutil appends " 1" etc. when the name is taken, so ask Finder by the actual mount name.
DISK_NAME="$(basename "$MOUNT_POINT")"

# Window layout is stored in the volume's .DS_Store, which only Finder writes.
# Icon positions are icon centers and must match DmgBackground.svg.
# The content area is 660x400; bounds include the ~28px title bar.
osascript - "$DISK_NAME" "$APP_NAME" <<'APPLESCRIPT'
on run {diskName, appName}
  tell application "Finder"
    tell disk diskName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 860, 548}
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 12
      set background picture of opts to file ".background:background.tiff"
      set position of item appName of container window to {150, 176}
      set position of item "Applications" of container window to {510, 176}
      close
      open
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
MOUNT_POINT=""

rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
