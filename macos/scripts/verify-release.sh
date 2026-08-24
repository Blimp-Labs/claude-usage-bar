#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="ClaudeUsageBar"
ARTIFACT_PATH="${1:-$PROJECT_DIR/$APP_NAME.zip}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-bar-release.XXXXXX")"
MOUNT_DIR="$TMP_DIR/mount"
DMG_ATTACHED=0

cleanup() {
    if [[ "$DMG_ATTACHED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$ARTIFACT_PATH" ]]; then
    echo "Error: release archive not found at $ARTIFACT_PATH"
    exit 1
fi

verify_app_bundle() {
    local app_bundle="$1"
    local app_plist="$app_bundle/Contents/Info.plist"
    local resource_bundle="$app_bundle/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
    local sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"

    echo "==> Verifying packaged resources..."
    [[ -f "$app_plist" ]] || { echo "Error: missing Info.plist"; exit 1; }
    [[ -d "$resource_bundle" ]] || { echo "Error: missing SwiftPM resource bundle"; exit 1; }
    [[ -f "$resource_bundle/Info.plist" ]] || { echo "Error: missing resource bundle Info.plist"; exit 1; }
    [[ -f "$resource_bundle/claude-logo.png" ]] || { echo "Error: missing packaged logo resource"; exit 1; }
    [[ -f "$resource_bundle/en.lproj/Localizable.strings" ]] || { echo "Error: missing packaged localization resource"; exit 1; }
    [[ -d "$sparkle_framework" ]] || { echo "Error: missing Sparkle.framework"; exit 1; }

    echo "==> Verifying app signature..."
    codesign -v "$app_bundle"

    verify_build_target "$app_bundle/Contents/MacOS/$APP_NAME"

    echo "==> Verifying updater metadata..."
    plutil -extract SUPublicEDKey raw "$app_plist" >/dev/null

    if [[ "${EXPECT_FEED_URL:-0}" == "1" ]]; then
        plutil -extract SUFeedURL raw "$app_plist" >/dev/null
    fi
}

verify_build_target() {
    local binary="$1"
    local min_sdk_major="${MIN_SDK_MAJOR:-26}"
    local expected_minos="${EXPECTED_MINOS:-14.0}"

    echo "==> Verifying build target..."

    command -v vtool >/dev/null 2>&1 || { echo "Error: vtool not found (needs Xcode command line tools)"; exit 1; }

    local build_info sdks minoses
    build_info="$(vtool -show-build "$binary")"
    sdks="$(awk '$1 == "sdk" { print $2 }' <<< "$build_info")"
    minoses="$(awk '$1 == "minos" { print $2 }' <<< "$build_info")"

    [[ -n "$sdks" && -n "$minoses" ]] || { echo "Error: could not read LC_BUILD_VERSION from $binary"; exit 1; }

    # macOS 26 grants an app the current appearance only if it was linked
    # against the macOS 26 SDK or newer — there is an Info.plist key to opt out
    # but none to opt in. An older SDK silently falls back to legacy chrome
    # (square popover corners), with no build error to catch it.
    local sdk
    while read -r sdk; do
        if [[ "${sdk%%.*}" -lt "$min_sdk_major" ]]; then
            echo "Error: linked against SDK $sdk, need $min_sdk_major or newer."
            echo "       The runner image is probably too old — check 'runs-on' in .github/workflows/."
            exit 1
        fi
    done <<< "$sdks"

    # The other direction: a newer toolchain must not silently raise the
    # deployment target and strand users on older macOS.
    local minos
    while read -r minos; do
        if [[ "$minos" != "$expected_minos" ]]; then
            echo "Error: deployment target is $minos, expected $expected_minos."
            echo "       Check .macOS(.v14) in Package.swift and LSMinimumSystemVersion in Info.plist."
            exit 1
        fi
    done <<< "$minoses"

    echo "    sdk $(head -n 1 <<< "$sdks") | minos $(head -n 1 <<< "$minoses")"
}

verify_applications_shortcut() {
    local shortcut_path="$1"

    if [[ -L "$shortcut_path" ]]; then
        return
    fi

    if [[ -f "$shortcut_path" ]] && file "$shortcut_path" | grep -q 'MacOS Alias file'; then
        return
    fi

    echo "Error: mounted DMG is missing a valid Applications shortcut"
    exit 1
}

case "$ARTIFACT_PATH" in
    *.zip)
        APP_BUNDLE="$TMP_DIR/$APP_NAME.app"

        echo "==> Extracting $(basename "$ARTIFACT_PATH")..."
        ditto -x -k "$ARTIFACT_PATH" "$TMP_DIR"

        if [[ ! -d "$APP_BUNDLE" ]]; then
            echo "Error: extracted archive did not contain $APP_NAME.app"
            exit 1
        fi

        verify_app_bundle "$APP_BUNDLE"
        ;;
    *.dmg)
        APP_BUNDLE="$MOUNT_DIR/$APP_NAME.app"
        DMG_BACKGROUND="$MOUNT_DIR/.background/background.png"
        DMG_DS_STORE="$MOUNT_DIR/.DS_Store"

        echo "==> Mounting $(basename "$ARTIFACT_PATH")..."
        mkdir -p "$MOUNT_DIR"
        hdiutil attach "$ARTIFACT_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" > /dev/null
        DMG_ATTACHED=1

        [[ -d "$APP_BUNDLE" ]] || { echo "Error: mounted DMG did not contain $APP_NAME.app"; exit 1; }
        verify_applications_shortcut "$MOUNT_DIR/Applications"
        [[ -f "$DMG_DS_STORE" ]] || { echo "Error: mounted DMG is missing Finder layout metadata"; exit 1; }
        [[ -f "$DMG_BACKGROUND" ]] || { echo "Error: mounted DMG is missing Finder background artwork"; exit 1; }

        verify_app_bundle "$APP_BUNDLE"
        ;;
    *)
        echo "Error: unsupported artifact type '$ARTIFACT_PATH'"
        exit 1
        ;;
esac

echo "==> Release archive looks good"
