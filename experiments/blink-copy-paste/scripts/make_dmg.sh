#!/usr/bin/env bash
# Package the notarized Blink.app into a drag-to-/Applications DMG.
# Requires `create-dmg` (brew install create-dmg).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

APP_PATH="${BLINK_APP_PATH:-$APP_DIR/build/Release/Blink.app}"
VERSION="${BLINK_DMG_VERSION:-$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
OUT_DIR="$APP_DIR/build"
DMG_PATH="$OUT_DIR/Blink-${VERSION}.dmg"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: $APP_PATH not found" >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "[blink] error: install create-dmg (brew install create-dmg)" >&2
    exit 1
fi

rm -f "$DMG_PATH"
mkdir -p "$OUT_DIR"

echo "[blink] packaging $APP_PATH → $DMG_PATH"
create-dmg \
    --volname "Blink ${VERSION}" \
    --window-size 480 280 \
    --icon-size 96 \
    --icon "Blink.app" 120 140 \
    --app-drop-link 360 140 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

echo "[blink] dmg ready: $DMG_PATH"
