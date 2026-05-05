#!/usr/bin/env bash
# Sign TLDR.app inside-out, notarize it, then staple the notarization ticket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

APP_PATH="${TLDR_APP_PATH:-$APP_DIR/build/Release/TLDR.app}"
TEAM_ID="${TLDR_TEAM_ID:-}"
SIGN_IDENTITY="${TLDR_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${TLDR_NOTARY_PROFILE:-TLDR-NOTARY}"
ENTITLEMENTS_PATH="${TLDR_ENTITLEMENTS_PATH:-$APP_DIR/TLDR/TLDR.entitlements}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[tldr] error: $APP_PATH not found; run tldr_app/scripts/build.sh first" >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ -z "$TEAM_ID" ]]; then
        echo "[tldr] error: set TLDR_TEAM_ID or TLDR_SIGN_IDENTITY in tldr_app/scripts/config.env" >&2
        exit 1
    fi
    SIGN_IDENTITY="$TEAM_ID"
fi
if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "[tldr] error: entitlements file not found: $ENTITLEMENTS_PATH" >&2
    exit 1
fi

echo "[tldr] stripping quarantine from $APP_PATH"
xattr -cr "$APP_PATH"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
PYTHON_DIR="$APP_PATH/Contents/Resources/python"
if [[ ! -d "$PYTHON_DIR" ]]; then
    echo "[tldr] error: bundled python runtime not found: $PYTHON_DIR" >&2
    exit 1
fi

SIGN_SCAN_ROOTS=()
if [[ -d "$FRAMEWORKS_DIR" ]]; then
    SIGN_SCAN_ROOTS+=("$FRAMEWORKS_DIR")
fi
SIGN_SCAN_ROOTS+=("$PYTHON_DIR")

echo "[tldr] signing nested Mach-O files"
while IFS= read -r file_path; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$file_path"
done < <(find "${SIGN_SCAN_ROOTS[@]}" -type f -exec sh -c 'file -b "$1" | grep -qE "Mach-O" && echo "$1"' _ {} \;)

if [[ -d "$FRAMEWORKS_DIR" ]]; then
    echo "[tldr] signing nested Sparkle bundles"
    while IFS= read -r bundle_path; do
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle_path"
    done < <(find "$FRAMEWORKS_DIR" \( -name '*.xpc' -o -name '*.app' \) -type d -prune | sort)

    if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
            "$FRAMEWORKS_DIR/Sparkle.framework"
    fi
fi

echo "[tldr] signing app bundle"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"

echo "[tldr] verifying app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ZIP_PATH="${TLDR_NOTARIZE_ZIP:-/tmp/TLDR-notarize.zip}"
rm -f "$ZIP_PATH"
echo "[tldr] submitting app for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "[tldr] stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[tldr] verifying Gatekeeper acceptance"
spctl -a -vv "$APP_PATH"

echo "[tldr] signed and notarized app: $APP_PATH"
