#!/usr/bin/env bash
# Package TLDR.app into a drag-to-/Applications DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

APP_PATH="${TLDR_APP_PATH:-$APP_DIR/build/Release/TLDR.app}"
OUT_DIR="$APP_DIR/build"
NOTARY_PROFILE="${TLDR_NOTARY_PROFILE:-TLDR-NOTARY}"
SIGN_IDENTITY="${TLDR_SIGN_IDENTITY:-}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[tldr] $APP_PATH not found; building Release app first"
    CONFIG=Release TLDR_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "[tldr] error: install create-dmg (brew install create-dmg)" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "[tldr] error: $APP_PATH not found after build" >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ -z "${TLDR_TEAM_ID:-}" ]]; then
        echo "[tldr] error: set TLDR_TEAM_ID or TLDR_SIGN_IDENTITY in tldr_app/scripts/config.env" >&2
        exit 1
    fi
    SIGN_IDENTITY="Developer ID Application: Henry Zhang ($TLDR_TEAM_ID)"
fi

assert_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "[tldr] error: missing required file: $path" >&2
        exit 1
    fi
}

assert_executable() {
    local path="$1"
    if [[ ! -x "$path" ]]; then
        echo "[tldr] error: missing executable: $path" >&2
        exit 1
    fi
}

assert_proxy_env_mode() {
    local path="$1"
    local mode
    mode="$(stat -f '%Lp' "$path")"
    if [[ "$mode" != "600" ]]; then
        echo "[tldr] error: $path must have mode 600; found $mode" >&2
        exit 1
    fi
}

echo "[tldr] validating app bundle before packaging"
assert_executable "$APP_PATH/Contents/MacOS/TLDR"
assert_executable "$APP_PATH/Contents/Resources/python/bin/python3"
"$APP_PATH/Contents/Resources/python/bin/python3" --version >/dev/null
"$APP_PATH/Contents/Resources/python/bin/python3" -c "import google.genai"
assert_file "$APP_PATH/Contents/Resources/tldr_once.py"
assert_file "$APP_PATH/Contents/Resources/prompt.txt"
if [[ -n "${TLDR_PROXY_URL:-}" ]]; then
    assert_file "$APP_PATH/Contents/Resources/proxy.env"
    assert_proxy_env_mode "$APP_PATH/Contents/Resources/proxy.env"
fi

bash "$SCRIPT_DIR/sign_and_notarize.sh"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vv "$APP_PATH"

VERSION="${TLDR_DMG_VERSION:-$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
DMG_PATH="$OUT_DIR/TLDR-${VERSION}.dmg"

rm -f "$DMG_PATH"
mkdir -p "$OUT_DIR"

echo "[tldr] packaging $APP_PATH -> $DMG_PATH"
create-dmg \
    --volname "TLDR ${VERSION}" \
    --window-size 480 280 \
    --icon-size 96 \
    --icon "TLDR.app" 120 140 \
    --app-drop-link 360 140 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

echo "[tldr] signing and notarizing dmg"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv -t install "$DMG_PATH"

echo "[tldr] dmg ready: $DMG_PATH"
