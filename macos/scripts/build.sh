#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
PLUTIL="/usr/bin/plutil"

cd "$PROJECT_DIR"

version_to_build_number() {
    local version="$1"
    version="${version#v}"

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        printf '%d' "$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]}))"
        return
    fi

    if [[ "$version" =~ ^[0-9]+$ ]]; then
        printf '%s' "$version"
        return
    fi

    printf '%s' "$version"
}

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

APP_VERSION="${APP_VERSION:-$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")}"
APP_BUILD="${APP_BUILD:-$(version_to_build_number "$APP_VERSION")}"

"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $APP_BUILD" "$APP_BUNDLE/Contents/Info.plist"

if [[ -n "${SU_FEED_URL:-}" ]]; then
    "$PLUTIL" -replace SUFeedURL -string "$SU_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
else
    "$PLUTIL" -remove SUFeedURL "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

RESOURCE_BUNDLE="$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$(find "$BUILD_DIR" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1 || true)"
fi

if [[ -z "$RESOURCE_BUNDLE" || ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Error: SwiftPM resource bundle not found for $APP_NAME"
    exit 1
fi

echo "==> Bundling SwiftPM resources..."
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$RESOURCE_BUNDLE")"

# --- Compile Asset Catalog (generates Assets.car + AppIcon.icns) ---
echo "==> Compiling Asset Catalog..."
actool --compile "$APP_BUNDLE/Contents/Resources" \
       --platform macosx \
       --minimum-deployment-target 14.0 \
       --app-icon AppIcon \
       --output-partial-info-plist /dev/null \
       "$PROJECT_DIR/Resources/Assets.xcassets" > /dev/null

SPARKLE_FRAMEWORK="$(find "$BUILD_DIR" -path '*/Sparkle.framework' -type d | head -n 1 || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
    echo "==> Bundling Sparkle.framework..."
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# --- Ad-hoc codesign ---
echo "==> Codesigning (ad-hoc)..."
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
    while IFS= read -r nested_bundle; do
        codesign --force --sign - "$nested_bundle"
    done < <(find "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" \
        \( -name '*.app' -o -name '*.xpc' \) -type d | sort)
    codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
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
