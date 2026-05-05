#!/usr/bin/env bash
# Build, notarize, package, sign for Sparkle, and optionally upload TLDR.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/config.env"
fi

SPARKLE_SIGN_UPDATE="${TLDR_SPARKLE_SIGN_UPDATE:-}"
SPARKLE_KEYCHAIN_ACCOUNT="${TLDR_SPARKLE_KEYCHAIN_ACCOUNT:-}"
R2_BUCKET="${TLDR_R2_BUCKET:-}"
R2_DOMAIN="${TLDR_R2_PUBLIC_DOMAIN:-}"
R2_ENDPOINT="${TLDR_R2_ENDPOINT:-}"
R2_ACCESS_KEY_ID="${TLDR_R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${TLDR_R2_SECRET_ACCESS_KEY:-}"
RELEASE_PREFIX="${TLDR_R2_RELEASE_PREFIX:-releases}"
APPCAST_LOCAL_PATH="${TLDR_APPCAST_LOCAL_PATH:-$APP_DIR/build/appcast.xml}"
APPCAST_REMOTE_KEY="${TLDR_R2_APPCAST_KEY:-appcast.xml}"
UPLOAD="${TLDR_RELEASE_UPLOAD:-1}"

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[tldr] error: missing required command: $1" >&2
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
        echo "[tldr] error: set TLDR_SPARKLE_SIGN_UPDATE to Sparkle's sign_update tool" >&2
        exit 1
    fi
fi

if [[ "$UPLOAD" != "0" ]]; then
    require aws
    if [[ -z "$R2_BUCKET" || -z "$R2_DOMAIN" ]]; then
        echo "[tldr] error: set TLDR_R2_BUCKET and TLDR_R2_PUBLIC_DOMAIN, or TLDR_RELEASE_UPLOAD=0" >&2
        exit 1
    fi
    if [[ -z "$R2_ENDPOINT" || -z "$R2_ACCESS_KEY_ID" || -z "$R2_SECRET_ACCESS_KEY" ]]; then
        echo "[tldr] error: set TLDR_R2_ENDPOINT, TLDR_R2_ACCESS_KEY_ID, and TLDR_R2_SECRET_ACCESS_KEY (S3-compatible R2 token credentials), or TLDR_RELEASE_UPLOAD=0" >&2
        exit 1
    fi
fi

bash "$SCRIPT_DIR/fetch_python.sh"
CONFIG=Release TLDR_SKIP_TCC_RESET=1 bash "$SCRIPT_DIR/build.sh"
bash "$SCRIPT_DIR/sign_and_notarize.sh"
bash "$SCRIPT_DIR/make_dmg.sh"

APP_PATH="${TLDR_APP_PATH:-$APP_DIR/build/Release/TLDR.app}"
VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString)"
BUILD_NUMBER="$(defaults read "$APP_PATH/Contents/Info" CFBundleVersion)"
DMG_PATH="$APP_DIR/build/TLDR-${VERSION}.dmg"
DMG_NAME="$(basename "$DMG_PATH")"
DMG_LENGTH="$(stat -f '%z' "$DMG_PATH")"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
DMG_REMOTE_KEY="$RELEASE_PREFIX/$VERSION/$DMG_NAME"
DMG_URL="https://$R2_DOMAIN/$DMG_REMOTE_KEY"

SIGN_ARGS=()
if [[ -n "$SPARKLE_KEYCHAIN_ACCOUNT" ]]; then
    SIGN_ARGS+=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
fi

echo "[tldr] signing update for Sparkle"
SIGN_OUTPUT="$("$SPARKLE_SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$DMG_PATH")"
ED_SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | head -n 1)"
if [[ -z "$ED_SIGNATURE" ]]; then
    ED_SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | awk '/edSignature/ {print $NF; exit}')"
fi
if [[ -z "$ED_SIGNATURE" ]]; then
    echo "[tldr] error: could not parse Sparkle EdDSA signature from sign_update output" >&2
    printf '%s\n' "$SIGN_OUTPUT" >&2
    exit 1
fi

mkdir -p "$(dirname "$APPCAST_LOCAL_PATH")"
cat > "$APPCAST_LOCAL_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>TLDR Updates</title>
    <description>TLDR app updates</description>
    <language>en</language>
    <item>
      <title>TLDR $VERSION</title>
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
echo "[tldr] appcast written: $APPCAST_LOCAL_PATH"
echo "[tldr] dmg sha256: $DMG_SHA256"

if [[ "$UPLOAD" != "0" ]]; then
    echo "[tldr] uploading $DMG_REMOTE_KEY and $APPCAST_REMOTE_KEY to R2 bucket $R2_BUCKET"
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws s3 cp "$DMG_PATH" "s3://$R2_BUCKET/$DMG_REMOTE_KEY" \
            --endpoint-url "$R2_ENDPOINT" \
            --checksum-algorithm CRC32 \
            --content-type application/x-apple-diskimage
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=auto \
        aws s3 cp "$APPCAST_LOCAL_PATH" "s3://$R2_BUCKET/$APPCAST_REMOTE_KEY" \
            --endpoint-url "$R2_ENDPOINT" \
            --checksum-algorithm CRC32 \
            --content-type application/xml
    echo "[tldr] release uploaded: $DMG_URL"
    echo "[tldr] appcast: https://$R2_DOMAIN/$APPCAST_REMOTE_KEY"
else
    echo "[tldr] upload skipped by TLDR_RELEASE_UPLOAD=0"
fi
