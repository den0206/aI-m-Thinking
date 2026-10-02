#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-path> <output.dmg> [volume-name]" >&2
  exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"
DEFAULT_VOLUME_NAME="I'm Thinking"
VOLUME_NAME="${3:-$DEFAULT_VOLUME_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
STAGING="$WORK_DIR/staging"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create   -volname "$VOLUME_NAME"   -srcfolder "$STAGING"   -ov   -format UDZO   "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
