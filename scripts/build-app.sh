#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/I'm Thinking.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

cargo build --manifest-path "$ROOT/core/Cargo.toml" --release
swift build --package-path "$ROOT/app" -c release --product ImThinking

SWIFT_BIN_DIR="$(swift build --package-path "$ROOT/app" -c release --show-bin-path)"
cp "$SWIFT_BIN_DIR/ImThinking" "$MACOS/ImThinking"
cp "$ROOT/core/target/release/im-thinking-core" "$MACOS/im-thinking-core"
chmod 755 "$MACOS/ImThinking" "$MACOS/im-thinking-core"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ImThinking</string>
    <key>CFBundleIdentifier</key>
    <string>com.den0206.ImThinking</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>I'm Thinking</string>
    <key>CFBundleDisplayName</key>
    <string>I'm Thinking</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi

echo "$APP"
