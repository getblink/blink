#!/usr/bin/env bash
# Submit Blink.app to Apple notary service, wait for approval, staple the ticket.
# Prereq: you've run `xcrun notarytool store-credentials <profile>` once so
# `BLINK_NOTARY_PROFILE` is valid.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

APP_PATH="${BLINK_APP_PATH:-$APP_DIR/build/Release/Blink.app}"
PROFILE="${BLINK_NOTARY_PROFILE:?Set BLINK_NOTARY_PROFILE in config.env}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "[blink] error: $APP_PATH not found" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP_PATH="$TMP_DIR/Blink.zip"

echo "[blink] zipping for submission"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[blink] submitting to notary"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait --timeout 30m

echo "[blink] stapling"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "[blink] notarized + stapled: $APP_PATH"
spctl --assess --type execute -vv "$APP_PATH"
