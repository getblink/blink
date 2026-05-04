#!/usr/bin/env bash
# Build TLDR.app via xcodebuild, then stamp the bundled Python runtime and
# tldr_once.py into Contents/Resources/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
CONFIG="${CONFIG:-Release}"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

export TLDR_DEVELOPMENT_TEAM="${TLDR_TEAM_ID:-}"

echo "[tldr] generating Xcode project"
(cd "$APP_DIR" && xcodegen generate --spec project.yml)

echo "[tldr] xcodebuild ($CONFIG)"
xcodebuild \
    -project "$APP_DIR/TLDR.xcodeproj" \
    -scheme TLDR \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    build | xcbeautify 2>/dev/null || xcodebuild \
    -project "$APP_DIR/TLDR.xcodeproj" \
    -scheme TLDR \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    build

APP_PATH="$BUILD_DIR/$CONFIG/TLDR.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "[tldr] error: did not find $APP_PATH" >&2
    exit 1
fi
echo "[tldr] built $APP_PATH"

RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES/python"

echo "[tldr] copying app resources -> $RESOURCES"
rsync -a "$APP_DIR/Resources/" "$RESOURCES/"

rm -f "$RESOURCES/proxy.env"
if [[ "${TLDR_DISABLE_PROXY:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    echo "[tldr] proxy embedding disabled by TLDR_DISABLE_PROXY"
elif [[ -n "${TLDR_PROXY_URL:-}" || -n "${TLDR_PROXY_TOKEN:-}" ]]; then
    if [[ -z "${TLDR_PROXY_URL:-}" || -z "${TLDR_PROXY_TOKEN:-}" ]]; then
        echo "[tldr] error: set both TLDR_PROXY_URL and TLDR_PROXY_TOKEN, or neither" >&2
        exit 1
    fi
    {
        printf 'BLINK_PROXY_URL=%s\n' "$TLDR_PROXY_URL"
        printf 'BLINK_PROXY_TOKEN=%s\n' "$TLDR_PROXY_TOKEN"
    } > "$RESOURCES/proxy.env"
    chmod 600 "$RESOURCES/proxy.env"
    echo "[tldr] embedded proxy config -> Contents/Resources/proxy.env"
fi

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[tldr] error: tldr_app/python-dist not found - run scripts/fetch_python.sh first" >&2
    exit 1
fi

echo "[tldr] copying python runtime -> $RESOURCES/python"
rsync -a --delete "$APP_DIR/python-dist/" "$RESOURCES/python/"

echo "[tldr] copying tldr_app/python/* into Resources"
rsync -a "$APP_DIR/python/" "$RESOURCES/"

PYTHON_SITE="$RESOURCES/python/lib"
SITE_PACKAGES_DIR="$(find "$PYTHON_SITE" -type d -name 'site-packages' | head -n 1 || true)"
if [[ -z "$SITE_PACKAGES_DIR" ]]; then
    echo "[tldr] error: could not locate site-packages under $PYTHON_SITE" >&2
    exit 1
fi
echo "../../python-packages" > "$SITE_PACKAGES_DIR/tldr-site.pth"

echo "[tldr] build complete -> $APP_PATH"

if [[ "${TLDR_SKIP_TCC_RESET:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi
