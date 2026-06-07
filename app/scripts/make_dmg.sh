#!/usr/bin/env bash
# Package Blink.app into a drag-to-/Applications DMG.
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
OUT_DIR="$APP_DIR/build"
NOTARY_PROFILE="${BLINK_NOTARY_PROFILE:-Blink-NOTARY}"
SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:-}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] $APP_PATH not found; building Release app first"
    CONFIG=Release BLINK_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "[blink] error: install create-dmg (brew install create-dmg)" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: $APP_PATH not found after build" >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ -z "${BLINK_TEAM_ID:-}" ]]; then
        echo "[blink] error: set BLINK_TEAM_ID or BLINK_SIGN_IDENTITY in app/scripts/config.env" >&2
        exit 1
    fi
    SIGN_IDENTITY="Developer ID Application: Henry Zhang ($BLINK_TEAM_ID)"
fi

assert_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "[blink] error: missing required file: $path" >&2
        exit 1
    fi
}

assert_executable() {
    local path="$1"
    if [[ ! -x "$path" ]]; then
        echo "[blink] error: missing executable: $path" >&2
        exit 1
    fi
}

assert_proxy_env_mode() {
    local path="$1"
    local mode
    mode="$(stat -f '%Lp' "$path")"
    if [[ "$mode" != "600" ]]; then
        echo "[blink] error: $path must have mode 600; found $mode" >&2
        exit 1
    fi
}

echo "[blink] validating app bundle before packaging"
assert_executable "$APP_PATH/Contents/MacOS/Blink"
assert_executable "$APP_PATH/Contents/Resources/python/bin/python3"
"$APP_PATH/Contents/Resources/python/bin/python3" --version >/dev/null
# The client is proxy-only — the server makes the Gemini call, so the app no
# longer bundles google-genai (requirements.txt is empty). Validate the real
# entrypoint instead: the bundled interpreter must import blink_once.py (and
# its local deps) with only what ships. Catches a broken bundle / missing
# python-packages wiring without asserting a dependency the client dropped.
( cd "$APP_PATH/Contents/Resources" && "$APP_PATH/Contents/Resources/python/bin/python3" -c "import blink_once" )
assert_file "$APP_PATH/Contents/Resources/blink_once.py"
assert_file "$APP_PATH/Contents/Resources/prompt.txt"
if [[ -n "${BLINK_PROXY_URL:-}" ]]; then
    assert_file "$APP_PATH/Contents/Resources/proxy.env"
    assert_proxy_env_mode "$APP_PATH/Contents/Resources/proxy.env"
fi

bash "$SCRIPT_DIR/sign_and_notarize.sh"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vv "$APP_PATH"

VERSION="${BLINK_DMG_VERSION:-$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
DMG_PATH="$OUT_DIR/Blink-${VERSION}.dmg"

rm -f "$DMG_PATH"
mkdir -p "$OUT_DIR"

echo "[blink] packaging $APP_PATH -> $DMG_PATH"
create-dmg \
    --volname "Blink ${VERSION}" \
    --window-size 480 280 \
    --icon-size 96 \
    --icon "Blink.app" 120 140 \
    --app-drop-link 360 140 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

echo "[blink] signing and notarizing dmg"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t install "$DMG_PATH"

echo "[blink] dmg ready: $DMG_PATH"
