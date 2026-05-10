#!/usr/bin/env bash
# Build, notarize, package, sign for Sparkle, and optionally upload Blink.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

# shellcheck disable=SC1091
source "$SCRIPT_DIR/env_compat.sh"
blink_apply_legacy_env_aliases

SPARKLE_SIGN_UPDATE="${BLINK_SPARKLE_SIGN_UPDATE:-}"
SPARKLE_KEYCHAIN_ACCOUNT="${BLINK_SPARKLE_KEYCHAIN_ACCOUNT:-}"
R2_BUCKET="${BLINK_R2_BUCKET:-}"
R2_DOMAIN="${BLINK_R2_PUBLIC_DOMAIN:-}"
R2_ENDPOINT="${BLINK_R2_ENDPOINT:-}"
R2_ACCESS_KEY_ID="${BLINK_R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${BLINK_R2_SECRET_ACCESS_KEY:-}"
RELEASE_PREFIX="${BLINK_R2_RELEASE_PREFIX:-releases}"
APPCAST_LOCAL_PATH="${BLINK_APPCAST_LOCAL_PATH:-$APP_DIR/build/appcast.xml}"
APPCAST_REMOTE_KEY="${BLINK_R2_APPCAST_KEY:-appcast.xml}"
UPLOAD="${BLINK_RELEASE_UPLOAD:-1}"

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[blink] error: missing required command: $1" >&2
        exit 1
    fi
}

require /usr/libexec/PlistBuddy
require stat

if [[ -z "$SPARKLE_SIGN_UPDATE" ]]; then
    if command -v sign_update >/dev/null 2>&1; then
        SPARKLE_SIGN_UPDATE="$(command -v sign_update)"
    elif [[ -x "$APP_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" ]]; then
        SPARKLE_SIGN_UPDATE="$APP_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    else
        echo "[blink] error: set BLINK_SPARKLE_SIGN_UPDATE to Sparkle's sign_update tool" >&2
        exit 1
    fi
fi

if [[ "$UPLOAD" != "0" ]]; then
    require aws
    if [[ -z "$R2_BUCKET" || -z "$R2_DOMAIN" ]]; then
        echo "[blink] error: set BLINK_R2_BUCKET and BLINK_R2_PUBLIC_DOMAIN, or BLINK_RELEASE_UPLOAD=0" >&2
        exit 1
    fi
    if [[ -z "$R2_ENDPOINT" || -z "$R2_ACCESS_KEY_ID" || -z "$R2_SECRET_ACCESS_KEY" ]]; then
        echo "[blink] error: set BLINK_R2_ENDPOINT, BLINK_R2_ACCESS_KEY_ID, and BLINK_R2_SECRET_ACCESS_KEY (S3-compatible R2 token credentials), or BLINK_RELEASE_UPLOAD=0" >&2
        exit 1
    fi
fi

bash "$SCRIPT_DIR/fetch_python.sh"
CONFIG=Release BLINK_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"
bash "$SCRIPT_DIR/sign_and_notarize.sh"
bash "$SCRIPT_DIR/make_dmg.sh"

APP_PATH="${BLINK_APP_PATH:-$APP_DIR/build/Release/Blink.app}"
VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
BUILD_NUMBER="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
DMG_PATH="$APP_DIR/build/Blink-${VERSION}.dmg"
DMG_NAME="$(basename "$DMG_PATH")"
DMG_LENGTH="$(stat -f '%z' "$DMG_PATH")"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_REMOTE_KEY="$RELEASE_PREFIX/$VERSION/$DMG_NAME"
DMG_URL="https://$R2_DOMAIN/$DMG_REMOTE_KEY"

SIGN_ARGS=()
if [[ -n "$SPARKLE_KEYCHAIN_ACCOUNT" ]]; then
    SIGN_ARGS+=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
fi

echo "[blink] signing update for Sparkle"
SIGN_OUTPUT="$("$SPARKLE_SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$DMG_PATH")"
ED_SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$ED_SIGNATURE" ]]; then
    ED_SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | awk '/edSignature/ {print $NF; exit}')"
fi
if [[ -z "$ED_SIGNATURE" ]]; then
    echo "[blink] error: could not parse Sparkle EdDSA signature from sign_update output" >&2
    printf '%s\n' "$SIGN_OUTPUT" >&2
    exit 1
fi

mkdir -p "$(dirname "$APPCAST_LOCAL_PATH")"
cat > "$APPCAST_LOCAL_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blink Updates</title>
    <description>Blink app updates</description>
    <language>en</language>
    <item>
      <title>Blink $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="$DMG_URL"
        sparkle:version="$BUILD_NUMBER"
        sparkle:shortVersionString="$VERSION"
        sparkle:edSignature="$ED_SIGNATURE"
        length="$DMG_LENGTH"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

xmllint --noout "$APPCAST_LOCAL_PATH"
echo "[blink] appcast written: $APPCAST_LOCAL_PATH"
echo "[blink] dmg sha256: $DMG_SHA256"

if [[ "$UPLOAD" != "0" ]]; then
    echo "[blink] uploading $DMG_REMOTE_KEY and $APPCAST_REMOTE_KEY to R2 bucket $R2_BUCKET"
    # AWS CLI v2 defaults to sending integrity-check headers that R2 rejects
    # mid-multipart-upload with `SSLV3_ALERT_BAD_RECORD_MAC` on partNumber=2.
    # Opt back to legacy behavior so the upload streams without checksum
    # negotiation R2 doesn't fully support.
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export AWS_DEFAULT_REGION=auto
    export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
    export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
    # Short Cache-Control on the DMG too. Without it, Cloudflare applies a 4-hour
    # edge TTL to the DMG by default. If the same DMG path is ever re-uploaded
    # (e.g., dry-run then real release at the same version), Sparkle sees the new
    # appcast pointing at fresh bytes, but downloads the stale cached DMG —
    # signature verification then fails silently and updates break.
    aws s3 cp "$DMG_PATH" "s3://$R2_BUCKET/$DMG_REMOTE_KEY" \
        --endpoint-url "$R2_ENDPOINT" \
        --content-type application/x-apple-diskimage \
        --cache-control 'public, max-age=60, must-revalidate'
    # Short Cache-Control so a fresh release is visible to Sparkle within 60s
    # instead of being pinned to Cloudflare's default edge TTL for XML.
    aws s3 cp "$APPCAST_LOCAL_PATH" "s3://$R2_BUCKET/$APPCAST_REMOTE_KEY" \
        --endpoint-url "$R2_ENDPOINT" \
        --content-type 'application/xml; charset=utf-8' \
        --cache-control 'public, max-age=60, must-revalidate'
    echo "[blink] release uploaded: $DMG_URL"
    echo "[blink] appcast: https://$R2_DOMAIN/$APPCAST_REMOTE_KEY"
else
    echo "[blink] upload skipped by BLINK_RELEASE_UPLOAD=0"
fi
