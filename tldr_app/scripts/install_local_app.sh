#!/usr/bin/env bash
# Build and install one canonical local TLDR.app for dogfood.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"

CANONICAL_APP="${TLDR_CANONICAL_APP:-$HOME/Applications/TLDR.app}"
DISABLED_DIR="$ROOT_DIR/.context/disabled-apps"

RESET_TCC=1
LAUNCH_APP=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-tcc)
            RESET_TCC=1
            shift
            ;;
        --skip-tcc-reset)
            RESET_TCC=0
            shift
            ;;
        --no-launch)
            LAUNCH_APP=0
            shift
            ;;
        *)
            echo "[tldr] unknown option: $1" >&2
            echo "[tldr] usage: bash tldr_app/scripts/install_local_app.sh [--skip-tcc-reset] [--no-launch]" >&2
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
    echo "[tldr] stashing duplicate app: $src -> $dest"
    if ! mv "$src" "$dest"; then
        echo "[tldr] warning: could not move $src; leaving it in place" >&2
    fi
}

echo "[tldr] stopping any running TLDR processes"
pkill -x TLDR 2>/dev/null || true
sleep 1

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[tldr] python-dist missing; fetching runtime first"
    bash "$SCRIPT_DIR/fetch_python.sh"
fi

if [[ -x "$APP_DIR/python-dist/bin/python3" ]]; then
    echo "[tldr] precompiling tldr_app/python/*.py to .pyc"
    "$APP_DIR/python-dist/bin/python3" -m compileall -q "$APP_DIR/python" || \
        echo "[tldr] warning: compileall failed; continuing without .pyc"
fi

echo "[tldr] building self-contained Release app"
CONFIG=Release TLDR_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"

RELEASE_APP="$APP_DIR/build/Release/TLDR.app"
if [[ ! -d "$RELEASE_APP" ]]; then
    echo "[tldr] error: expected built app at $RELEASE_APP" >&2
    exit 1
fi

echo "[tldr] installing canonical app -> $CANONICAL_APP"
mkdir -p "$(dirname "$CANONICAL_APP")"
rm -rf "$CANONICAL_APP"
ditto "$RELEASE_APP" "$CANONICAL_APP"

disable_app_bundle "$RELEASE_APP" "TLDR-Release"
disable_app_bundle "/Applications/TLDR.app" "TLDR-System"

while IFS= read -r derived_app; do
    flavor="TLDR-DerivedData"
    disable_app_bundle "$derived_app" "$flavor"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
    \( -path '*/Build/Products/Debug/TLDR.app' \
       -o -path '*/Build/Products/Release/TLDR.app' \) \
    -type d | sort)

if [[ "$RESET_TCC" == "1" ]]; then
    echo "[tldr] resetting TCC for the canonical install"
    TLDR_KEEP_INSTALLED=1 \
    TLDR_INSTALLED_APP="$CANONICAL_APP" \
    bash "$SCRIPT_DIR/reset_tcc.sh"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user 2>/dev/null || true

if [[ "$LAUNCH_APP" == "1" ]]; then
    echo "[tldr] launching $CANONICAL_APP"
    open "$CANONICAL_APP"
else
    echo "[tldr] install complete (not launched)"
fi

echo "[tldr] canonical app ready: $CANONICAL_APP"
