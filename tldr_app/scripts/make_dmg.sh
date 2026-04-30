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

echo "[tldr] dmg ready: $DMG_PATH"
