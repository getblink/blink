#!/usr/bin/env bash
# Build Blink.app via xcodebuild, then stamp the bundled python runtime and
# our run_once.py into Contents/Resources/.
#
# Prereqs: xcodegen, python-dist/ present (see fetch_python.sh).
# Output: app/build/Release/Blink.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$APP_DIR/build"
CONFIG="${CONFIG:-Release}"

# Load config.env if present (TEAM_ID, BUNDLE_ID).
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

export BLINK_DEVELOPMENT_TEAM="${BLINK_TEAM_ID:-}"

echo "[blink] generating Xcode project"
(cd "$APP_DIR" && xcodegen generate --spec project.yml)

echo "[blink] xcodebuild ($CONFIG)"
xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    build | xcbeautify 2>/dev/null || xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    build

APP_PATH="$BUILD_DIR/$CONFIG/Blink.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: did not find $APP_PATH" >&2
    exit 1
fi
echo "[blink] built $APP_PATH"

RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES/python"

echo "[blink] copying app resources → $RESOURCES"
rsync -a "$APP_DIR/Resources/" "$RESOURCES/"

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[blink] error: app/python-dist not found — run scripts/fetch_python.sh first" >&2
    exit 1
fi

echo "[blink] copying python runtime → $RESOURCES/python"
rsync -a --delete "$APP_DIR/python-dist/" "$RESOURCES/python/"

echo "[blink] copying app/python/* into Resources (run_once.py etc.)"
rsync -a "$APP_DIR/python/" "$RESOURCES/"

# Ensure run_once.py can find gemini_runner.py beside it (already is via rsync).
# Also make sure python-packages (google-genai) is on sys.path. Prepend a .pth file.
PYTHON_SITE="$RESOURCES/python/lib"
SITE_PACKAGES_DIR="$(find "$PYTHON_SITE" -type d -name 'site-packages' | head -n 1 || true)"
if [[ -z "$SITE_PACKAGES_DIR" ]]; then
    echo "[blink] error: could not locate site-packages under $PYTHON_SITE" >&2
    exit 1
fi
# site-packages is at python/lib/python3.11/site-packages/, target is python/lib/python-packages/
echo "../../python-packages" > "$SITE_PACKAGES_DIR/blink-site.pth"

# Inject proxy URL/token into the built bundle's Info.plist so the shipped DMG
# works without per-machine setup. The committed Info.plist keeps empty
# defaults; the live values come from config.env (gitignored). Must run before
# the ad-hoc resign below so the signature seals the modified plist.
INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ -n "${BLINK_PROXY_URL:-}" ]]; then
    echo "[blink] stamping BlinkProxyURL into Info.plist"
    /usr/libexec/PlistBuddy -c "Set :BlinkProxyURL ${BLINK_PROXY_URL}" "$INFO_PLIST"
fi
if [[ -n "${BLINK_PROXY_TOKEN:-}" ]]; then
    echo "[blink] stamping BlinkProxyToken into Info.plist"
    /usr/libexec/PlistBuddy -c "Set :BlinkProxyToken ${BLINK_PROXY_TOKEN}" "$INFO_PLIST"
fi

# Xcode signs the bundle before we rsync python-dist + run_once.py into
# Contents/Resources/, so the on-disk seal is now invalid ("a sealed resource
# is missing or invalid"). Re-seal ad-hoc here so the bundle is launchable
# as-is. scripts/sign.sh will overwrite this with a Developer ID signature
# for distribution builds.
echo "[blink] re-signing bundle ad-hoc after resource copy"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - --options runtime --timestamp=none \
    --entitlements "$APP_DIR/Blink/Blink.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "[blink] build complete → $APP_PATH"

# Reset TCC so the freshly-built binary gets a clean first-launch experience
# in System Settings. Opt out with BLINK_SKIP_TCC_RESET=1 if you're iterating
# and don't want to re-grant permissions every rebuild.
if [[ "${BLINK_SKIP_TCC_RESET:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi
