#!/usr/bin/env bash
# Sign Blink.app inside-out, notarize it, then staple the notarization ticket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

APP_PATH="${BLINK_APP_PATH:-$APP_DIR/build/Release/Blink.app}"
TEAM_ID="${BLINK_TEAM_ID:-}"
SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${BLINK_NOTARY_PROFILE:-Blink-NOTARY}"
ENTITLEMENTS_PATH="${BLINK_ENTITLEMENTS_PATH:-$APP_DIR/Blink/Blink.entitlements}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: $APP_PATH not found; run app/scripts/build.sh first" >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ -z "$TEAM_ID" ]]; then
        echo "[blink] error: set BLINK_TEAM_ID or BLINK_SIGN_IDENTITY in app/scripts/config.env" >&2
        exit 1
    fi
    SIGN_IDENTITY="$TEAM_ID"
fi
if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "[blink] error: entitlements file not found: $ENTITLEMENTS_PATH" >&2
    exit 1
fi

echo "[blink] stripping quarantine from $APP_PATH"
xattr -cr "$APP_PATH"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
PYTHON_DIR="$APP_PATH/Contents/Resources/python"
if [[ ! -d "$PYTHON_DIR" ]]; then
    echo "[blink] error: bundled python runtime not found: $PYTHON_DIR" >&2
    exit 1
fi

SIGN_SCAN_ROOTS=()
if [[ -d "$FRAMEWORKS_DIR" ]]; then
    SIGN_SCAN_ROOTS+=("$FRAMEWORKS_DIR")
fi
SIGN_SCAN_ROOTS+=("$PYTHON_DIR")

echo "[blink] signing nested Mach-O files"
while IFS= read -r file_path; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$file_path"
done < <(find "${SIGN_SCAN_ROOTS[@]}" -type f -exec sh -c 'file -b "$1" | grep -qE "Mach-O" && echo "$1"' _ {} \;)

if [[ -d "$FRAMEWORKS_DIR" ]]; then
    echo "[blink] signing nested Sparkle bundles"
    while IFS= read -r bundle_path; do
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle_path"
    done < <(find "$FRAMEWORKS_DIR" \( -name '*.xpc' -o -name '*.app' \) -type d -prune | sort)

    if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
            "$FRAMEWORKS_DIR/Sparkle.framework"
    fi
fi

echo "[blink] signing app bundle"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

echo "[blink] verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="${BLINK_NOTARIZE_ZIP:-/tmp/Blink-notarize.zip}"
rm -f "$ZIP_PATH"
echo "[blink] submitting app for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[blink] stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[blink] verifying Gatekeeper acceptance"
spctl -a -vv "$APP_PATH"

echo "[blink] signed and notarized app: $APP_PATH"
