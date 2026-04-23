#!/usr/bin/env bash
# Reset TCC (Privacy & Security) state for Blink's bundle ID *and* scrub the
# app from the system so the next launch behaves like a truly-first launch.
#
# Why this is so aggressive:
#   - `tccutil reset` only clears approval records. macOS (Sequoia+) will
#     re-approve the same bundle ID automatically as long as the same binary
#     is still running or installed, because its designated requirement
#     matches a recent grant. That made prior resets look like a no-op.
#   - Quitting the running instance + removing the installed .app + clearing
#     the TCC approval collectively force System Settings to show the entries
#     as un-granted (and actually re-prompt on the next fresh install).
#
# Side effects:
#   - Kills any running Blink process.
#   - Deletes /Applications/Blink.app (by default). Skip with
#     BLINK_KEEP_INSTALLED=1 if you only want the TCC entries cleared.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

BUNDLE_ID="${BLINK_BUNDLE_ID:-com.blink.tester.Blink}"
INSTALLED_APP="${BLINK_INSTALLED_APP:-/Applications/Blink.app}"

echo "[blink] stopping any running Blink processes"
pkill -x Blink 2>/dev/null || true
# Give macOS a moment to tear down TCC sessions for the killed process.
sleep 1

if [[ "${BLINK_KEEP_INSTALLED:-0}" != "1" ]]; then
    if [[ -d "$INSTALLED_APP" ]]; then
        echo "[blink] removing installed $INSTALLED_APP"
        rm -rf "$INSTALLED_APP"
    fi
fi

echo "[blink] resetting TCC entries for $BUNDLE_ID"
# Reset the umbrella bucket + each service individually. `All` *should* cover
# every service, but explicit resets make the intent obvious and survive any
# quirks where the `All` shortcut skips a service on a given macOS version.
for service in All Accessibility ScreenCapture ListenEvent PostEvent AppleEvents SystemPolicyAllFiles; do
    tccutil reset "$service" "$BUNDLE_ID" 2>/dev/null || true
done

# Some macOS versions cache LaunchServices metadata keyed by bundle ID. Nudge
# it to forget the old binary so the next install is treated as fresh.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user 2>/dev/null || true

echo "[blink] done."
if [[ "${BLINK_KEEP_INSTALLED:-0}" == "1" ]]; then
    echo "[blink] NOTE: /Applications/Blink.app was kept per BLINK_KEEP_INSTALLED=1."
    echo "[blink]       Relaunch it to see the reset take effect."
else
    echo "[blink] Install the fresh DMG to see the reset take effect."
fi
