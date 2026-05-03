#!/usr/bin/env bash
# Build and install one canonical local Blink.app for profiling / dogfood.
#
# Why this exists:
#   - Launching Blink out of DerivedData or app/build produces multiple .app
#     bundles with the same bundle ID. Spotlight, LaunchServices, and TCC then
#     treat them as separate installs, which makes permission grants confusing.
#   - This script keeps one launch target at ~/Applications/Blink.app and moves
#     duplicate build products aside so local testing uses a stable path.
#
# Default behavior:
#   1. Fetch app/python-dist if missing.
#   2. Build a self-contained Release app.
#   3. With --reset-tcc: remove the old canonical app and reset TCC before the
#      fresh install, so Screen Recording cannot stay attached to the old app.
#   4. Install it to ~/Applications/Blink.app.
#   5. Move duplicate Blink.app bundles out of Spotlight/TCC's way.
#   6. Relaunch the canonical app.
#
# Options:
#   --reset-tcc   Reset Blink's TCC permissions before relaunching. Use after
#                 Swift app-code changes or if Accessibility appears enabled
#                 but the new build still behaves like it is denied.
#   --no-launch   Install only; do not reopen Blink.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"

CANONICAL_APP="${BLINK_CANONICAL_APP:-$HOME/Applications/Blink.app}"
DISABLED_DIR="$ROOT_DIR/.context/disabled-apps"

RESET_TCC=0
LAUNCH_APP=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-tcc)
            RESET_TCC=1
            shift
            ;;
        --no-launch)
            LAUNCH_APP=0
            shift
            ;;
        *)
            echo "[blink] unknown option: $1" >&2
            echo "[blink] usage: bash app/scripts/install_local_app.sh [--reset-tcc] [--no-launch]" >&2
            exit 2
            ;;
    esac
done

disable_app_bundle() {
    local src="$1"
    local label="$2"
    local dest="$DISABLED_DIR/$label.app.disabled"

    [[ -d "$src" ]] || return 0

    mkdir -p "$DISABLED_DIR"
    rm -rf "$dest"
    echo "[blink] stashing duplicate app: $src -> $dest"
    if ! mv "$src" "$dest"; then
        echo "[blink] warning: could not move $src; leaving it in place" >&2
    fi
}

echo "[blink] stopping any running Blink processes"
pkill -x Blink 2>/dev/null || true
sleep 1

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[blink] python-dist missing; fetching runtime first"
    bash "$SCRIPT_DIR/fetch_python.sh"
fi

# Pre-compile bundled Python sources to .pyc so the cold-spawn fallback path
# skips parser/AST work. Use the bundled python-dist interpreter so the .pyc
# magic number matches the runtime that will eventually load them.
if [[ -x "$APP_DIR/python-dist/bin/python3" ]]; then
    echo "[blink] precompiling app/python/*.py to .pyc"
    "$APP_DIR/python-dist/bin/python3" -m compileall -q "$APP_DIR/python" || \
        echo "[blink] warning: compileall failed; continuing without .pyc"
fi

echo "[blink] building self-contained Release app"
CONFIG=Release BLINK_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"

RELEASE_APP="$APP_DIR/build/Release/Blink.app"
if [[ ! -d "$RELEASE_APP" ]]; then
    echo "[blink] error: expected built app at $RELEASE_APP" >&2
    exit 1
fi

if [[ "$RESET_TCC" == "1" ]]; then
    echo "[blink] resetting TCC before the fresh canonical install"
    BLINK_INSTALLED_APP="$CANONICAL_APP" \
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi

echo "[blink] installing canonical app -> $CANONICAL_APP"
mkdir -p "$(dirname "$CANONICAL_APP")"
rm -rf "$CANONICAL_APP"
ditto "$RELEASE_APP" "$CANONICAL_APP"

disable_app_bundle "$RELEASE_APP" "Blink-Release"
disable_app_bundle "/Applications/Blink.app" "Blink-System"

# Catch any other Blink.app under DerivedData (both Debug and Release) — TCC
# treats each path as a separate bundle even when they share the same
# CFBundleIdentifier, which is the source of macOS Tahoe's repeated Screen &
# System Audio Recording prompts at launch.
while IFS= read -r derived_app; do
    flavor="Blink-Debug"
    case "$derived_app" in
        */Build/Products/Release/*) flavor="Blink-Release-DerivedData" ;;
    esac
    disable_app_bundle "$derived_app" "$flavor"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
    \( -path '*/Build/Products/Debug/Blink.app' \
       -o -path '*/Build/Products/Release/Blink.app' \) \
    -type d | sort)

# An earlier xcodebuild invocation from inside `app/` produces a doubled
# `app/app/build/...` path in this workspace. Stash it for the same reason.
if [[ -d "$APP_DIR/app" ]]; then
    while IFS= read -r doubled_app; do
        disable_app_bundle "$doubled_app" "Blink-DoubledPath"
    done < <(find "$APP_DIR/app" -name 'Blink.app' -type d 2>/dev/null | sort)
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user 2>/dev/null || true

if [[ "$LAUNCH_APP" == "1" ]]; then
    echo "[blink] launching $CANONICAL_APP"
    open "$CANONICAL_APP"
else
    echo "[blink] install complete (not launched)"
fi

echo "[blink] canonical app ready: $CANONICAL_APP"
