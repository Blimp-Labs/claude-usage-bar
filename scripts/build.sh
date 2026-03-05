#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"

# --- Build release binary ---
echo "==> Building release binary..."
swift build -c release

BINARY="$BUILD_DIR/release/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY"
    exit 1
fi

# --- Create .app bundle ---
echo "==> Creating $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# --- Compile app icon (iconutil works with Command Line Tools; no full Xcode needed) ---
echo "==> Compiling app icon..."
ICONSET_SRC="$PROJECT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_TMP"
cp "$ICONSET_SRC"/*.png "$ICONSET_TMP/"
iconutil -c icns "$ICONSET_TMP" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_TMP")"

# --- Ad-hoc codesign ---
echo "==> Codesigning (ad-hoc)..."
codesign --force --sign - "$APP_BUNDLE"

echo "==> Built $APP_BUNDLE"
codesign -v "$APP_BUNDLE"
echo "==> Codesign verified OK"

# --- Zip if requested ---
if [[ "${1:-}" == "--zip" ]]; then
    ZIP_PATH="$PROJECT_DIR/$APP_NAME.zip"
    echo "==> Creating $ZIP_PATH..."
    cd "$PROJECT_DIR"
    rm -f "$APP_NAME.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip"
    echo "==> Done: $ZIP_PATH"
fi
