#!/usr/bin/env bash
# Reset TCC state for Blink's bundle ID.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

BUNDLE_ID="${BLINK_BUNDLE_ID:-com.henryz2004.blink}"
INSTALLED_APP="${BLINK_INSTALLED_APP:-/Applications/Blink.app}"

echo "[blink] stopping any running Blink processes"
pkill -x Blink 2>/dev/null || true

if [[ "${BLINK_KEEP_INSTALLED:-0}" != "1" && -d "$INSTALLED_APP" ]]; then
    echo "[blink] removing installed app at $INSTALLED_APP"
    rm -rf "$INSTALLED_APP"
elif [[ -d "$INSTALLED_APP" ]]; then
    echo "[blink] keeping installed app at $INSTALLED_APP"
fi

SERVICES=(
    Accessibility
    ListenEvent
    PostEvent
    ScreenCapture
    SystemPolicyAllFiles
    AppleEvents
)

for service in "${SERVICES[@]}"; do
    echo "[blink] tccutil reset $service $BUNDLE_ID"
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

# Drop and re-register the canonical bundle so LaunchServices forgets stale
# registrations of the same bundle ID with old trusted code signatures.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -d "$INSTALLED_APP" ]]; then
    "$LSREGISTER" -u "$INSTALLED_APP" 2>/dev/null || true
    "$LSREGISTER" -f "$INSTALLED_APP" 2>/dev/null || true
fi

echo "[blink] TCC reset complete for $BUNDLE_ID"
