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

# Production proxy embedding lives in build.sh — it's the script that
# actually writes Resources/proxy.env. release.sh used to source
# .env.production here, but build.sh's own re-source of .env then
# clobbered the prod values back to staging, which shipped staging into
# the 0.2.3 and 0.2.4 DMGs. Setting BLINK_REQUIRE_PRODUCTION_PROXY=1
# tells build.sh to source .env.production after .env, enforce its
# presence, and refuse any URL containing "staging".
export BLINK_REQUIRE_PRODUCTION_PROXY=1

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
    # Drift guard: SUFeedURL stamped into the binary (BLINK_SPARKLE_FEED_URL,
    # baked at build.sh:88-90) must match where this script will upload the
    # appcast. If they ever diverge, every install built with the old feed URL
    # is permanently quarantined from updates — its Sparkle poll hits a 404
    # and there's no in-band way to recover. Caught the 0.2.0 → 0.2.1 incident
    # where the stamped URL was /blink/appcast.xml but the upload key was
    # appcast.xml at the root.
    if [[ -z "${BLINK_SPARKLE_FEED_URL:-}" ]]; then
        echo "[blink] error: BLINK_SPARKLE_FEED_URL must be set so SUFeedURL gets stamped into the build (or set BLINK_RELEASE_UPLOAD=0 for a local dry run)" >&2
        exit 1
    fi
    # Normalize: tolerate trailing slash on R2_DOMAIN and leading slash on
    # APPCAST_REMOTE_KEY so config-time typos don't masquerade as drift.
    # BLINK_SPARKLE_FEED_URL itself is exact-string-matched: Sparkle stamps
    # whatever string we give it into Info.plist verbatim, and any difference
    # (query string, case, fragment) means installed apps poll a different URL.
    EXPECTED_FEED_URL="https://${R2_DOMAIN%/}/${APPCAST_REMOTE_KEY#/}"
    if [[ "$BLINK_SPARKLE_FEED_URL" != "$EXPECTED_FEED_URL" ]]; then
        echo "[blink] error: appcast URL drift detected — installed apps would poll a path this release does not publish to." >&2
        echo "[blink]   binary will be stamped with: $BLINK_SPARKLE_FEED_URL" >&2
        echo "[blink]   appcast will be uploaded to: $EXPECTED_FEED_URL" >&2
        echo "[blink] Either correct BLINK_SPARKLE_FEED_URL or set BLINK_R2_APPCAST_KEY so its path matches." >&2
        echo "[blink] (Note: BLINK_R2_PUBLIC_DOMAIN must be the host users actually fetch from, not an internal R2 hostname.)" >&2
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

    # rclone fallback config — lazily materialized if aws s3 cp fails. The
    # 0.2.6 release hit BAD_RECORD_MAC across every aws-cli/boto3/curl variant
    # we tried (Python OpenSSL and LibreSSL alike, single-part PUT and
    # multipart, rate-limited and full-speed); rclone (Go TLS + 5MB chunked
    # per-part retries) was the only path that completed. Keep aws s3 cp as
    # the primary path; per-object fall back to rclone on any non-zero exit.
    BLINK_RCLONE_CONFIG_TEMP=""
    trap '[[ -n "${BLINK_RCLONE_CONFIG_TEMP:-}" ]] && rm -f "$BLINK_RCLONE_CONFIG_TEMP"' EXIT

    upload_one() {
        local src="$1" key="$2" content_type="$3"
        local cache_control='public, max-age=60, must-revalidate'
        if aws s3 cp "$src" "s3://$R2_BUCKET/$key" \
                --endpoint-url "$R2_ENDPOINT" \
                --content-type "$content_type" \
                --cache-control "$cache_control"; then
            return 0
        fi
        echo "[blink] aws s3 cp failed for $key — falling back to rclone (Go TLS, chunked retries)"
        if ! command -v rclone >/dev/null 2>&1; then
            echo "[blink] error: rclone fallback unavailable. Install with 'brew install rclone' and rerun (artifacts in app/build/ are reusable)." >&2
            return 1
        fi
        if [[ -z "$BLINK_RCLONE_CONFIG_TEMP" ]]; then
            BLINK_RCLONE_CONFIG_TEMP="$(mktemp)"
            # `no_check_bucket = true`: rclone's S3 backend probes the bucket
            # via HeadBucket / CreateBucket by default, but our Cloudflare R2
            # tokens are scoped to Object Read & Write — they have no bucket
            # permissions, so the probe fails with `403 AccessDenied:
            # CreateBucket` before any object upload is attempted. Caught
            # during the 0.2.11 release when aws s3 cp hit BAD_RECORD_MAC and
            # rclone fallback then died 20 retries deep on CreateBucket.
            cat > "$BLINK_RCLONE_CONFIG_TEMP" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${R2_ENDPOINT}
region = auto
no_check_bucket = true
EOF
        fi
        # `--s3-no-check-bucket` belt-and-suspenders with `no_check_bucket` in
        # the config above: the flag wins if a stale config ever survives, and
        # the config wins if the flag is dropped during a future refactor.
        RCLONE_CONFIG="$BLINK_RCLONE_CONFIG_TEMP" rclone copyto \
            --s3-no-check-bucket \
            --s3-chunk-size=5M \
            --s3-upload-concurrency=1 \
            --retries 20 \
            --low-level-retries 30 \
            --header-upload "Content-Type: $content_type" \
            --header-upload "Cache-Control: $cache_control" \
            --progress --stats=2s --stats-one-line \
            "$src" "r2:${R2_BUCKET}/${key}"
    }

    # Short Cache-Control on the DMG too. Without it, Cloudflare applies a 4-hour
    # edge TTL to the DMG by default. If the same DMG path is ever re-uploaded
    # (e.g., dry-run then real release at the same version), Sparkle sees the new
    # appcast pointing at fresh bytes, but downloads the stale cached DMG —
    # signature verification then fails silently and updates break.
    upload_one "$DMG_PATH" "$DMG_REMOTE_KEY" application/x-apple-diskimage
    # Stable alias at latest/Blink.dmg for human-facing download links and
    # structured-data offer URLs that don't want to drift on each release.
    # Sparkle still uses the versioned URL via the appcast — this is purely
    # a convenience handle. Same short Cache-Control + must-revalidate so a
    # new release is visible within ~60s.
    LATEST_DMG_KEY="${BLINK_R2_LATEST_DMG_KEY:-latest/Blink.dmg}"
    upload_one "$DMG_PATH" "$LATEST_DMG_KEY" application/x-apple-diskimage
    # Appcast LAST — once it's live, installed apps start polling it for the
    # new DMG. Short Cache-Control so a fresh release is visible to Sparkle
    # within 60s instead of being pinned to Cloudflare's default edge TTL.
    upload_one "$APPCAST_LOCAL_PATH" "$APPCAST_REMOTE_KEY" 'application/xml; charset=utf-8'
    echo "[blink] release uploaded: $DMG_URL"
    echo "[blink] latest alias: https://$R2_DOMAIN/$LATEST_DMG_KEY"
    echo "[blink] appcast: https://$R2_DOMAIN/$APPCAST_REMOTE_KEY"
else
    echo "[blink] upload skipped by BLINK_RELEASE_UPLOAD=0"
fi
