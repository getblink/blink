#!/usr/bin/env bash
# Build Blink.app via xcodebuild, then stamp the bundled Python runtime and
# blink_once.py into Contents/Resources/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
CONFIG="${CONFIG:-Release}"

ROOT_ENV="$APP_DIR/../.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_ENV"
fi

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

export BLINK_DEVELOPMENT_TEAM="${BLINK_DEVELOPMENT_TEAM:-${BLINK_TEAM_ID:-}}"

echo "[blink] generating Xcode project"
(cd "$APP_DIR" && xcodegen generate --spec project.yml)

echo "[blink] xcodebuild ($CONFIG)"
# Build unsigned (ad-hoc); sign_and_notarize.sh handles real Developer ID signing.
xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build | xcbeautify 2>/dev/null || xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="$BUILD_DIR/$CONFIG/Blink.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: did not find $APP_PATH" >&2
    exit 1
fi
echo "[blink] built $APP_PATH"

BUILD_NUMBER="${BLINK_BUILD_NUMBER:-$(git -C "$APP_DIR/.." rev-list --count HEAD)}"
echo "[blink] stamping CFBundleVersion=$BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP_PATH/Contents/Info.plist"

if [[ -n "${BLINK_SPARKLE_FEED_URL:-}" ]]; then
    echo "[blink] stamping SUFeedURL=$BLINK_SPARKLE_FEED_URL"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $BLINK_SPARKLE_FEED_URL" \
        "$APP_PATH/Contents/Info.plist"
fi

if [[ -n "${BLINK_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    echo "[blink] stamping SUPublicEDKey from BLINK_SPARKLE_PUBLIC_ED_KEY"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $BLINK_SPARKLE_PUBLIC_ED_KEY" \
        "$APP_PATH/Contents/Info.plist"
fi

RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES/python"

echo "[blink] copying app resources -> $RESOURCES"
rsync -a "$APP_DIR/Resources/" "$RESOURCES/"

rm -f "$RESOURCES/proxy.env"
if [[ "${BLINK_DISABLE_PROXY:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    echo "[blink] proxy embedding disabled by BLINK_DISABLE_PROXY"
elif [[ -n "${BLINK_PROXY_URL:-}" || -n "${BLINK_PROXY_TOKEN:-}" ]]; then
    if [[ -z "${BLINK_PROXY_URL:-}" || -z "${BLINK_PROXY_TOKEN:-}" ]]; then
        echo "[blink] error: set both BLINK_PROXY_URL and BLINK_PROXY_TOKEN, or neither" >&2
        exit 1
    fi
    {
        printf 'BLINK_PROXY_URL=%s\n' "$BLINK_PROXY_URL"
        printf 'BLINK_PROXY_TOKEN=%s\n' "$BLINK_PROXY_TOKEN"
    } > "$RESOURCES/proxy.env"
    chmod 600 "$RESOURCES/proxy.env"
    echo "[blink] embedded proxy config -> Contents/Resources/proxy.env"
fi

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[blink] error: app/python-dist not found - run scripts/fetch_python.sh first" >&2
    exit 1
fi

echo "[blink] copying python runtime -> $RESOURCES/python"
rsync -a --delete "$APP_DIR/python-dist/" "$RESOURCES/python/"

echo "[blink] copying app/python/* into Resources"
rsync -a "$APP_DIR/python/" "$RESOURCES/"

PYTHON_SITE="$RESOURCES/python/lib"
SITE_PACKAGES_DIR="$(find "$PYTHON_SITE" -type d -name 'site-packages' | head -n 1 || true)"
if [[ -z "$SITE_PACKAGES_DIR" ]]; then
    echo "[blink] error: could not locate site-packages under $PYTHON_SITE" >&2
    exit 1
fi
echo "../../python-packages" > "$SITE_PACKAGES_DIR/blink-site.pth"

ENTITLEMENTS_PATH="${BLINK_ENTITLEMENTS_PATH:-$APP_DIR/Blink/Blink.entitlements}"
# xcodebuild ad-hoc signed the app, but PlistBuddy stamps and the Python /
# Resources rsync above mutate the bundle, invalidating that signature. The
# Developer ID flow re-signs from scratch in sign_and_notarize.sh, but
# install_local_app.sh stops here — without this re-sign the canonical local
# install ships with a broken signature, which makes Sparkle's Installer.xpc
# refuse to launch ("error connecting to the installer"). Re-sign just the
# outer bundle so Sparkle.framework's nested Developer-ID XPCs keep their
# original signatures.
echo "[blink] re-signing ad-hoc after Info.plist + resource stamping"
codesign --force --sign - \
    --options=runtime \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

echo "[blink] build complete -> $APP_PATH"

if [[ "${BLINK_SKIP_TCC_RESET:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi
