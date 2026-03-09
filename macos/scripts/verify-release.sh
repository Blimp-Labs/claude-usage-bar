#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
ZIP_PATH="${1:-$PROJECT_DIR/$APP_NAME.zip}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-bar-release.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Error: release archive not found at $ZIP_PATH"
    exit 1
fi

APP_BUNDLE="$TMP_DIR/$APP_NAME.app"
APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

echo "==> Extracting $(basename "$ZIP_PATH")..."
ditto -x -k "$ZIP_PATH" "$TMP_DIR"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: extracted archive did not contain $APP_NAME.app"
    exit 1
fi

echo "==> Verifying packaged resources..."
[[ -f "$APP_PLIST" ]] || { echo "Error: missing Info.plist"; exit 1; }
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "Error: missing SwiftPM resource bundle"; exit 1; }
[[ -f "$RESOURCE_BUNDLE/Info.plist" ]] || { echo "Error: missing resource bundle Info.plist"; exit 1; }
[[ -f "$RESOURCE_BUNDLE/claude-logo.png" ]] || { echo "Error: missing packaged logo resource"; exit 1; }
[[ -f "$RESOURCE_BUNDLE/en.lproj/Localizable.strings" ]] || { echo "Error: missing packaged localization resource"; exit 1; }
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Error: missing Sparkle.framework"; exit 1; }

echo "==> Verifying app signature..."
codesign -v "$APP_BUNDLE"

echo "==> Verifying updater metadata..."
plutil -extract SUPublicEDKey raw "$APP_PLIST" >/dev/null

if [[ "${EXPECT_FEED_URL:-0}" == "1" ]]; then
    plutil -extract SUFeedURL raw "$APP_PLIST" >/dev/null
fi

echo "==> Release archive looks good"
