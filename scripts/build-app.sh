#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

case "$CONFIG" in
  debug)
    APP_NAME="I'm Thinking Debug"
    BUNDLE_ID="com.den0206.ImThinking.debug"
    CORE_DIR="debug"
    SWIFT_CONFIG="debug"
    DISTRIBUTION="direct"
    ;;
  release)
    APP_NAME="I'm Thinking"
    BUNDLE_ID="com.den0206.ImThinking"
    CORE_DIR="release"
    SWIFT_CONFIG="release"
    DISTRIBUTION="direct"
    ;;
  appstore-smoke)
    APP_NAME="I'm Thinking App Store Smoke"
    BUNDLE_ID="com.den0206.ImThinking.appstore-smoke"
    CORE_DIR="release"
    SWIFT_CONFIG="release"
    DISTRIBUTION="app-store"
    ;;
  *)
    echo "CONFIG must be 'debug', 'release', or 'appstore-smoke'" >&2
    exit 2
    ;;
esac

OUT_DIR="$ROOT/.build/$CONFIG"
APP="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

if [[ "$CORE_DIR" == "release" ]]; then
  cargo build --manifest-path "$ROOT/core/Cargo.toml" --release
else
  cargo build --manifest-path "$ROOT/core/Cargo.toml"
fi
swift build --package-path "$ROOT/app" -c "$SWIFT_CONFIG" --product ImThinking

SWIFT_BIN_DIR="$(swift build --package-path "$ROOT/app" -c "$SWIFT_CONFIG" --show-bin-path)"
cp "$SWIFT_BIN_DIR/ImThinking" "$MACOS/ImThinking"
cp "$ROOT/core/target/$CORE_DIR/im-thinking-core" "$MACOS/im-thinking-core"
chmod 755 "$MACOS/ImThinking" "$MACOS/im-thinking-core"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ImThinking</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$MARKETING_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>ImThinkingDistribution</key>
    <string>$DISTRIBUTION</string>
</dict>
</plist>
PLIST

CODESIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" && "$CONFIG" == "release" ]]; then
  CODESIGN_ARGS+=(--timestamp)
fi

# Sign the bundled Rust helper first, then seal the containing app bundle.
CORE_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}")
APP_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}")

if [[ "$CONFIG" == "appstore-smoke" ]]; then
  CORE_CODESIGN_ARGS+=(--identifier "$BUNDLE_ID.core")
  CORE_CODESIGN_ARGS+=(--entitlements "$ROOT/app/Resources/im-thinking-core.appstore.entitlements")
  APP_CODESIGN_ARGS+=(--entitlements "$ROOT/app/Resources/ImThinking.appstore.entitlements")
elif [[ "$CONFIG" == "debug" ]]; then
  APP_CODESIGN_ARGS+=(--entitlements "$ROOT/app/Resources/ImThinking.debug.entitlements")
fi

codesign "${CORE_CODESIGN_ARGS[@]}" "$MACOS/im-thinking-core"
codesign "${APP_CODESIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "$APP"
