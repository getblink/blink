#!/usr/bin/env bash
# Build and install one canonical local Blink.app for dogfood.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$APP_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

# Mirror build.sh's env load so we see BLINK_SIGN_IDENTITY (and any
# other settings) when deciding whether to reset TCC below. Without
# this the auto-detect always flags the install as ad-hoc, since the
# env isn't typically exported from the parent shell.
ROOT_ENV="$SCRIPT_DIR/../../.env"
if [[ -f "$ROOT_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT_ENV"
fi

CANONICAL_APP="${BLINK_CANONICAL_APP:-$HOME/Applications/Blink.app}"

# TCC tracks permission grants by the bundle's designated requirement.
# With a Developer ID cert the DR is anchored to identifier + cert chain
# (stable across rebuilds → TCC grants survive). With ad-hoc signing
# the DR is cdhash-anchored (changes on every rebuild → grants go
# stale). So the reset is only useful when the previous install or the
# new install is ad-hoc. Default to auto-detect; `--reset-tcc` /
# `--skip-tcc-reset` flags override. If you switch Developer ID certs,
# pass `--reset-tcc` explicitly — the cert leaf is part of the DR.
RESET_TCC=auto
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
            echo "[blink] unknown option: $1" >&2
            echo "[blink] usage: bash app/scripts/install_local_app.sh [--reset-tcc|--skip-tcc-reset] [--no-launch]" >&2
            exit 2
            ;;
    esac
done

if [[ "$RESET_TCC" == "auto" ]]; then
    RESET_TCC=0
    if [[ "${BLINK_SIGN_IDENTITY:--}" == "-" ]]; then
        # New install will be ad-hoc; cdhash-anchored DR invalidates
        # existing TCC grants every build.
        RESET_TCC=1
        echo "[blink] auto-reset: new install will be ad-hoc signed"
    elif [[ -d "$CANONICAL_APP" ]]; then
        # Read codesign output into a variable instead of piping into
        # `grep -q`. With `set -o pipefail` the early grep-q close
        # SIGPIPEs codesign on its next write, returning 141 from the
        # pipeline — and the `!` would then flip false-negatives into
        # spurious resets.
        prev_sig=$(codesign -dvv "$CANONICAL_APP" 2>&1 || true)
        if ! grep -q '^Authority=Developer ID Application:' <<<"$prev_sig"; then
            # Previous install was ad-hoc; TCC has stale cdhash rows
            # that won't match the new Developer ID DR. One-shot reset
            # clears them; subsequent Developer ID → Developer ID
            # installs skip the reset.
            RESET_TCC=1
            echo "[blink] auto-reset: previous install was ad-hoc, clearing stale TCC rows"
        fi
    fi
fi

remove_duplicate_app() {
    # Delete a duplicate Blink.app bundle so macOS Launch Services and TCC
    # only see the canonical install at $CANONICAL_APP. Older versions of
    # this script stashed duplicates as `*.app.disabled` under
    # `.context/disabled-apps/`, but macOS Settings indexed those bundles
    # as separate apps anyway, cluttering Privacy & Security and wasting
    # ~100MB per stash. The canonical install is the source of truth.
    local target="$1"
    [[ -d "$target" ]] || return 0
    echo "[blink] removing duplicate app: $target"
    rm -rf "$target"
}

echo "[blink] stopping any running Blink processes"
pkill -x Blink 2>/dev/null || true
sleep 1

if [[ ! -d "$APP_DIR/python-dist" ]]; then
    echo "[blink] python-dist missing; fetching runtime first"
    bash "$SCRIPT_DIR/fetch_python.sh"
fi

if [[ -x "$APP_DIR/python-dist/bin/python3" ]]; then
    echo "[blink] precompiling app/python/*.py to .pyc"
    "$APP_DIR/python-dist/bin/python3" -m compileall -q "$APP_DIR/python" || \
        echo "[blink] warning: compileall failed; continuing without .pyc"
fi

echo "[blink] building self-contained Release app"
# Stamp dogfood builds with CFBundleVersion=0, but disable Sparkle for the
# local install so the app doesn't immediately replace unreleased workspace
# code with the public appcast build after launch.
CONFIG=Release \
    BLINK_SKIP_TCC_RESET=1 \
    BLINK_DISABLE_SPARKLE_UPDATES="${BLINK_DISABLE_SPARKLE_UPDATES:-1}" \
    BLINK_BUILD_NUMBER="${BLINK_BUILD_NUMBER:-0}" \
    bash "$SCRIPT_DIR/build.sh"

RELEASE_APP="$APP_DIR/build/Release/Blink.app"
if [[ ! -d "$RELEASE_APP" ]]; then
    echo "[blink] error: expected built app at $RELEASE_APP" >&2
    exit 1
fi

echo "[blink] installing canonical app -> $CANONICAL_APP"
mkdir -p "$(dirname "$CANONICAL_APP")"
rm -rf "$CANONICAL_APP"
ditto "$RELEASE_APP" "$CANONICAL_APP"

remove_duplicate_app "$RELEASE_APP"
remove_duplicate_app "/Applications/Blink.app"

while IFS= read -r derived_app; do
    remove_duplicate_app "$derived_app"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
    \( -path '*/Build/Products/Debug/Blink.app' \
       -o -path '*/Build/Products/Release/Blink.app' \) \
    -type d | sort)

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
