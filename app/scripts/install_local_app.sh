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
#   3. Install it to ~/Applications/Blink.app.
#   4. Move duplicate Blink.app bundles out of Spotlight/TCC's way.
#   5. Relaunch the canonical app.
#
# Options:
#   --reset-tcc   Reset Blink's TCC permissions before relaunching.
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

echo "[blink] building self-contained Release app"
CONFIG=Release BLINK_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"

RELEASE_APP="$APP_DIR/build/Release/Blink.app"
if [[ ! -d "$RELEASE_APP" ]]; then
    echo "[blink] error: expected built app at $RELEASE_APP" >&2
    exit 1
fi

echo "[blink] installing canonical app -> $CANONICAL_APP"
mkdir -p "$(dirname "$CANONICAL_APP")"
rm -rf "$CANONICAL_APP"
ditto "$RELEASE_APP" "$CANONICAL_APP"

disable_app_bundle "$RELEASE_APP" "Blink-Release"
disable_app_bundle "/Applications/Blink.app" "Blink-System"

while IFS= read -r derived_app; do
    disable_app_bundle "$derived_app" "Blink-Debug"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/Build/Products/Debug/Blink.app' -type d | sort)

if [[ "$RESET_TCC" == "1" ]]; then
    echo "[blink] resetting TCC for the canonical install"
    BLINK_KEEP_INSTALLED=1 \
    BLINK_INSTALLED_APP="$CANONICAL_APP" \
    bash "$SCRIPT_DIR/reset_tcc.sh"
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
