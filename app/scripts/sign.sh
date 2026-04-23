#!/usr/bin/env bash
# Leaf-first codesign: every .dylib/.so and the embedded python3 binary are
# signed before the parent .app. Hardened runtime + library-validation-disabled
# entitlement lets us load unsigned standard-library .so files from
# python-build-standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

APP_PATH="${BLINK_APP_PATH:-$APP_DIR/build/Release/Blink.app}"
SIGNING_ID="${BLINK_SIGNING_ID:?Set BLINK_SIGNING_ID in config.env (Developer ID Application: ...)}"
ENTITLEMENTS="$APP_DIR/Blink/Blink.entitlements"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: $APP_PATH not found" >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "[blink] error: entitlements missing at $ENTITLEMENTS" >&2
    exit 1
fi

# Strip extended attributes (quarantine, FinderInfo) — codesign fails on these.
echo "[blink] clearing extended attributes"
xattr -cr "$APP_PATH"

# Sign leaves first (dylibs/so), then executables, then the .app itself.
echo "[blink] signing nested dylibs/so files"
find "$APP_PATH/Contents/Resources" \
    \( -name "*.dylib" -o -name "*.so" \) -type f -print0 |
    while IFS= read -r -d '' binary; do
        codesign --force --timestamp --options=runtime \
            --sign "$SIGNING_ID" "$binary"
    done

echo "[blink] signing python3 binary"
PYTHON_BIN="$APP_PATH/Contents/Resources/python/bin/python3"
if [[ -f "$PYTHON_BIN" ]]; then
    codesign --force --timestamp --options=runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_ID" "$PYTHON_BIN"
fi

echo "[blink] signing Blink.app"
codesign --force --timestamp --options=runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_ID" "$APP_PATH"

echo "[blink] verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "[blink] signed: $APP_PATH"
