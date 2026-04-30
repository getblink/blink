#!/usr/bin/env bash
# Reset TCC state for TLDR's bundle ID.
set -euo pipefail

BUNDLE_ID="${TLDR_BUNDLE_ID:-com.henryz2004.tldr}"
INSTALLED_APP="${TLDR_INSTALLED_APP:-/Applications/TLDR.app}"

echo "[tldr] stopping any running TLDR processes"
pkill -x TLDR 2>/dev/null || true

if [[ "${TLDR_KEEP_INSTALLED:-0}" != "1" && -d "$INSTALLED_APP" ]]; then
    echo "[tldr] removing installed app at $INSTALLED_APP"
    rm -rf "$INSTALLED_APP"
elif [[ -d "$INSTALLED_APP" ]]; then
    echo "[tldr] keeping installed app at $INSTALLED_APP"
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
    echo "[tldr] tccutil reset $service $BUNDLE_ID"
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
done

echo "[tldr] TCC reset complete for $BUNDLE_ID"
