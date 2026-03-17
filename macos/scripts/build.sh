#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ZIP_PATH="$PROJECT_DIR/$APP_NAME.zip"
DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"
CREATE_DMG_VERSION="v1.2.3"
CREATE_DMG_TARBALL_URL="https://github.com/create-dmg/create-dmg/archive/refs/tags/${CREATE_DMG_VERSION}.tar.gz"
# Update this hash whenever CREATE_DMG_VERSION is changed
CREATE_DMG_SHA256="8cf7b4ae540801171f4f630f1f2956913aaa87483b7ac03458f52b6cd0c48953"
DMG_RESOURCES_DIR="$PROJECT_DIR/Resources/dmg"
DMG_BACKGROUND_SOURCE="$DMG_RESOURCES_DIR/background.png"
APP_ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.icns"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
PLUTIL="/usr/bin/plutil"
CREATE_ZIP=0
CREATE_DMG=0
SKIP_BUILD=0

cd "$PROJECT_DIR"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip)
            CREATE_ZIP=1
            ;;
        --dmg)
            CREATE_DMG=1
            ;;
        --skip-build)
            SKIP_BUILD=1
            ;;
        *)
            echo "Error: unknown option '$1'"
            exit 1
            ;;
    esac
    shift
done

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

build_app_bundle() {
    echo "==> Building release binary..."
    swift build -c release

    local binary="$BUILD_DIR/release/$APP_NAME"
    if [[ ! -f "$binary" ]]; then
        echo "Error: binary not found at $binary"
        exit 1
    fi

    echo "==> Creating $APP_NAME.app bundle..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    cp "$binary" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

    local app_version="${APP_VERSION:-$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")}"
    local app_build="${APP_BUILD:-$(version_to_build_number "$app_version")}"

    "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $app_version" "$APP_BUNDLE/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleVersion $app_build" "$APP_BUNDLE/Contents/Info.plist"

    if [[ -n "${SU_FEED_URL:-}" ]]; then
        "$PLUTIL" -replace SUFeedURL -string "$SU_FEED_URL" "$APP_BUNDLE/Contents/Info.plist"
    else
        "$PLUTIL" -remove SUFeedURL "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    fi

    local resource_bundle="$BUILD_DIR/release/${APP_NAME}_${APP_NAME}.bundle"
    if [[ ! -d "$resource_bundle" ]]; then
        resource_bundle="$(find "$BUILD_DIR" -path "*/release/${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1 || true)"
    fi

    if [[ -z "$resource_bundle" || ! -d "$resource_bundle" ]]; then
        echo "Error: SwiftPM resource bundle not found for $APP_NAME"
        exit 1
    fi

    echo "==> Bundling SwiftPM resources..."
    ditto "$resource_bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$resource_bundle")"

    echo "==> Compiling Asset Catalog..."
    actool --compile "$APP_BUNDLE/Contents/Resources" \
           --platform macosx \
           --minimum-deployment-target 14.0 \
           --app-icon AppIcon \
           --output-partial-info-plist /dev/null \
           "$PROJECT_DIR/Resources/Assets.xcassets" > /dev/null

    local sparkle_framework
    sparkle_framework="$(find "$BUILD_DIR" -path '*/Sparkle.framework' -type d | head -n 1 || true)"
    if [[ -n "$sparkle_framework" ]]; then
        echo "==> Bundling Sparkle.framework..."
        mkdir -p "$APP_BUNDLE/Contents/Frameworks"
        ditto "$sparkle_framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi

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
}

create_zip() {
    echo "==> Creating $ZIP_PATH..."
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    echo "==> Done: $ZIP_PATH"
}

create_applications_alias() {
    local staging_dir="$1"
    local icon_script
    icon_script="$(mktemp "${TMPDIR:-/tmp}/set-applications-alias-icon.XXXXXX.swift")"

    osascript - "$staging_dir" <<'OSA'
on run argv
    set destinationFolder to POSIX file (item 1 of argv)
    set applicationsFolder to POSIX file "/Applications" as alias

    tell application "Finder"
        make new alias file at destinationFolder to applicationsFolder with properties {name:"Applications"}
    end tell
end run
OSA

    cat > "$icon_script" <<'SWIFT'
import AppKit

let target = CommandLine.arguments[1]
let source = CommandLine.arguments[2]
let icon = NSWorkspace.shared.icon(forFile: source)

guard NSWorkspace.shared.setIcon(icon, forFile: target, options: []) else {
    fputs("Failed to set custom icon on alias\n", stderr)
    exit(1)
}
SWIFT

    swift "$icon_script" "$staging_dir/Applications" "/Applications"
    rm -f "$icon_script"
}

create_dmg() {
    local staging_dir
    local create_dmg_root
    local create_dmg_tool
    local -a create_dmg_args
    staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-bar-dmg.XXXXXX")"
    create_dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/create-dmg.XXXXXX")"
    create_dmg_tool="$create_dmg_root/create-dmg"

    echo "==> Creating $DMG_PATH..."
    rm -f "$DMG_PATH"

    [[ -f "$DMG_BACKGROUND_SOURCE" ]] || { echo "Error: DMG background not found at $DMG_BACKGROUND_SOURCE"; exit 1; }

    ditto "$APP_BUNDLE" "$staging_dir/$APP_NAME.app"
    create_applications_alias "$staging_dir"
    local tarball
    tarball="$(mktemp "${TMPDIR:-/tmp}/create-dmg-tarball.XXXXXX.tar.gz")"
    curl -fsSL "$CREATE_DMG_TARBALL_URL" -o "$tarball"

    local actual_sha256
    actual_sha256="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$CREATE_DMG_SHA256" ]]; then
        echo "Error: create-dmg tarball SHA256 mismatch!"
        echo "  expected: $CREATE_DMG_SHA256"
        echo "  actual:   $actual_sha256"
        rm -f "$tarball"
        exit 1
    fi

    tar -xzf "$tarball" -C "$create_dmg_root" --strip-components=1
    rm -f "$tarball"
    chmod +x "$create_dmg_tool"

    create_dmg_args=(
        "$create_dmg_tool"
        --volname "$APP_NAME"
        --background "$DMG_BACKGROUND_SOURCE"
        --volicon "$APP_ICON_SOURCE"
        --window-pos 160 140
        --window-size 680 420
        --text-size 12
        --icon-size 96
        --icon "$APP_NAME.app" 110 225
        --hide-extension "$APP_NAME.app"
        --icon "Applications" 385 225
        --format UDZO
        --hdiutil-quiet
    )

    "${create_dmg_args[@]}" "$DMG_PATH" "$staging_dir" > /dev/null

    rm -rf "$create_dmg_root"
    rm -rf "$staging_dir"
    echo "==> Done: $DMG_PATH"
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    build_app_bundle
elif [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: app bundle not found at $APP_BUNDLE"
    exit 1
fi

if [[ "$CREATE_ZIP" -eq 1 ]]; then
    create_zip
fi

if [[ "$CREATE_DMG" -eq 1 ]]; then
    create_dmg
fi
