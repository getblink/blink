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

# Production-release flows (release.sh) set this so the build pulls
# BLINK_PROXY_URL/BLINK_PROXY_TOKEN from .env.production rather than from
# the local-dev .env that was just sourced above. Local-dev flows
# (install_local_app.sh, raw build.sh) leave this unset and keep
# embedding whatever's in .env (typically staging). Without this two-file
# split, release.sh's .env.production exports got clobbered by build.sh's
# re-source of .env, which shipped staging into the 0.2.3 and 0.2.4 DMGs.
if [[ "${BLINK_REQUIRE_PRODUCTION_PROXY:-}" == "1" ]]; then
    PROD_ENV="$APP_DIR/../.env.production"
    if [[ ! -f "$PROD_ENV" ]]; then
        echo "[blink] error: BLINK_REQUIRE_PRODUCTION_PROXY=1 but $PROD_ENV not found." >&2
        echo "[blink] Create it with BLINK_PROXY_URL and BLINK_PROXY_TOKEN (see .env.production.example)." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$PROD_ENV"
    echo "[blink] sourced production proxy config from $PROD_ENV"
    if [[ -z "${BLINK_PROXY_URL:-}" || -z "${BLINK_PROXY_TOKEN:-}" ]]; then
        echo "[blink] error: $PROD_ENV must define both BLINK_PROXY_URL and BLINK_PROXY_TOKEN" >&2
        exit 1
    fi
    if [[ "$BLINK_PROXY_URL" == *staging* ]]; then
        echo "[blink] error: BLINK_PROXY_URL in $PROD_ENV points at staging ($BLINK_PROXY_URL); release builds must embed production." >&2
        exit 1
    fi
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

if [[ "${BLINK_DISABLE_SPARKLE_UPDATES:-}" =~ ^(1|true|TRUE|yes|YES|on|ON)$ ]]; then
    # Local dogfood installs should stay on the just-built bundle. Point the
    # feed at a non-HTTPS localhost URL so BlinkApp.hasUsableSparkleConfig
    # leaves Sparkle disabled even if config.env provided production updater
    # credentials.
    BLINK_SPARKLE_FEED_URL="http://127.0.0.1:9/appcast.xml"
fi

export BLINK_DEVELOPMENT_TEAM="${BLINK_DEVELOPMENT_TEAM:-${BLINK_TEAM_ID:-}}"

# Use a real Developer ID identity for local builds when one is available, so
# the bundle's designated requirement is anchored to the cert (stable across
# rebuilds) instead of the cdhash (changes every build). Stable attribution is
# what lets TCC's Screen Recording entry persist across reinstalls — under
# ad-hoc signing on Tahoe, every rebuild looks like a different app to TCC and
# the System Settings entry never reliably lands. Falls back to ad-hoc when no
# identity is configured (CI, fresh checkout without a populated .env).
LOCAL_SIGN_IDENTITY="${BLINK_SIGN_IDENTITY:--}"
if [[ "$LOCAL_SIGN_IDENTITY" == "-" ]]; then
    echo "[blink] signing identity: ad-hoc (set BLINK_SIGN_IDENTITY for stable Developer ID attribution)"
else
    echo "[blink] signing identity: $LOCAL_SIGN_IDENTITY"
fi

echo "[blink] generating Xcode project"
(cd "$APP_DIR" && xcodegen generate --spec project.yml)

echo "[blink] xcodebuild ($CONFIG)"
# DEVELOPMENT_TEAM has to be set on the xcodebuild command line (not just on the
# Blink target via project.yml) so SwiftPM-built dependency targets like
# PermissionFlow / SystemSettingsKit / their resource bundles inherit it.
# Without this they fail with "Signing for ... requires a development team".
xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="${BLINK_DEVELOPMENT_TEAM:-}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build | xcbeautify 2>/dev/null || xcodebuild \
    -project "$APP_DIR/Blink.xcodeproj" \
    -scheme Blink \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination 'generic/platform=macOS' \
    BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="${BLINK_DEVELOPMENT_TEAM:-}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="$BUILD_DIR/$CONFIG/Blink.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: did not find $APP_PATH" >&2
    exit 1
fi
echo "[blink] built $APP_PATH"

if [[ -n "${BLINK_BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$BLINK_BUILD_NUMBER"
else
    BUILD_COUNT="$(git -C "$APP_DIR/.." rev-list --count HEAD)"
    BUILD_OFFSET_PATH="$APP_DIR/BUILD_NUMBER_OFFSET"
    BUILD_OFFSET=0
    if [[ -f "$BUILD_OFFSET_PATH" ]]; then
        BUILD_OFFSET="$(tr -d '[:space:]' < "$BUILD_OFFSET_PATH")"
        if [[ ! "$BUILD_OFFSET" =~ ^[0-9]+$ ]]; then
            echo "[blink] error: app/BUILD_NUMBER_OFFSET must contain a non-negative integer" >&2
            exit 1
        fi
    fi
    BUILD_NUMBER=$((BUILD_COUNT + BUILD_OFFSET))
fi
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
rsync -a --exclude '*.xcassets' "$APP_DIR/Resources/" "$RESOURCES/"

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

# Precompile every .py inside the bundle so .pyc files exist at sign time and
# Python never writes new ones at runtime. Without this, Python regenerates
# stdlib .pyc on first import (rsync mtimes don't match the prebuilt headers),
# adding files that aren't in the code-resources manifest. The broken seal
# silently blocks TCC's Screen Recording registration so Blink never appears
# in System Settings even though the prompt fires. Combined with
# PYTHONDONTWRITEBYTECODE=1 in PythonRunner.swift this keeps the seal intact.
echo "[blink] precompiling bundled python (.pyc) so the seal stays intact"
"$RESOURCES/python/bin/python3" -m compileall -f -q -j0 \
    "$RESOURCES/python/lib" "$RESOURCES" || {
        echo "[blink] error: compileall failed; aborting before sign" >&2
        exit 1
    }

ENTITLEMENTS_PATH="${BLINK_ENTITLEMENTS_PATH:-$APP_DIR/Blink/Blink.entitlements}"
# xcodebuild ad-hoc signed the app, but PlistBuddy stamps and the Python /
# Resources rsync above mutate the bundle, invalidating that signature. The
# Developer ID flow re-signs from scratch in sign_and_notarize.sh, but
# install_local_app.sh stops here — without this re-sign the canonical local
# install ships with a broken signature, which makes Sparkle's Installer.xpc
# refuse to launch ("error connecting to the installer"). Re-sign just the
# outer bundle so Sparkle.framework's nested Developer-ID XPCs keep their
# original signatures.
echo "[blink] re-signing ($LOCAL_SIGN_IDENTITY) after Info.plist + resource stamping"
codesign --force --sign "$LOCAL_SIGN_IDENTITY" \
    --options=runtime \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

echo "[blink] build complete -> $APP_PATH"

if [[ "${BLINK_SKIP_TCC_RESET:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi
