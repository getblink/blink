#!/usr/bin/env bash

blink_deprecated_env() {
    local new_name="$1"
    local old_name="$2"
    local new_value="${!new_name:-}"
    local old_value="${!old_name:-}"
    if [[ -z "$new_value" && -n "$old_value" ]]; then
        printf -v "$new_name" '%s' "$old_value"
        export "$new_name"
        echo "[blink] warning: $old_name is deprecated, use $new_name" >&2
    fi
}

blink_apply_legacy_env_aliases() {
    blink_deprecated_env BLINK_DEVELOPMENT_TEAM TLDR_DEVELOPMENT_TEAM
    blink_deprecated_env BLINK_TEAM_ID TLDR_TEAM_ID
    blink_deprecated_env BLINK_BUILD_NUMBER TLDR_BUILD_NUMBER
    blink_deprecated_env BLINK_DEV_PYTHON TLDR_DEV_PYTHON
    blink_deprecated_env BLINK_DISABLE_PROXY TLDR_DISABLE_PROXY
    blink_deprecated_env BLINK_FORCE_LEGACY_GLASS TLDR_FORCE_LEGACY_GLASS
    blink_deprecated_env BLINK_PROXY_URL TLDR_PROXY_URL
    blink_deprecated_env BLINK_PROXY_TOKEN TLDR_PROXY_TOKEN
    blink_deprecated_env BLINK_APP_PATH TLDR_APP_PATH
    blink_deprecated_env BLINK_CANONICAL_APP TLDR_CANONICAL_APP
    blink_deprecated_env BLINK_BUNDLE_ID TLDR_BUNDLE_ID
    blink_deprecated_env BLINK_INSTALLED_APP TLDR_INSTALLED_APP
    blink_deprecated_env BLINK_KEEP_INSTALLED TLDR_KEEP_INSTALLED
    blink_deprecated_env BLINK_SKIP_TCC_RESET TLDR_SKIP_TCC_RESET
    blink_deprecated_env BLINK_ENTITLEMENTS_PATH TLDR_ENTITLEMENTS_PATH
    blink_deprecated_env BLINK_SIGN_IDENTITY TLDR_SIGN_IDENTITY
    blink_deprecated_env BLINK_NOTARY_PROFILE TLDR_NOTARY_PROFILE
    blink_deprecated_env BLINK_NOTARIZE_ZIP TLDR_NOTARIZE_ZIP
    blink_deprecated_env BLINK_DMG_VERSION TLDR_DMG_VERSION
    blink_deprecated_env BLINK_RELEASE_UPLOAD TLDR_RELEASE_UPLOAD
    blink_deprecated_env BLINK_APPCAST_LOCAL_PATH TLDR_APPCAST_LOCAL_PATH
    blink_deprecated_env BLINK_R2_APPCAST_KEY TLDR_R2_APPCAST_KEY
    blink_deprecated_env BLINK_R2_BUCKET TLDR_R2_BUCKET
    blink_deprecated_env BLINK_R2_PUBLIC_DOMAIN TLDR_R2_PUBLIC_DOMAIN
    blink_deprecated_env BLINK_R2_ENDPOINT TLDR_R2_ENDPOINT
    blink_deprecated_env BLINK_R2_ACCESS_KEY_ID TLDR_R2_ACCESS_KEY_ID
    blink_deprecated_env BLINK_R2_SECRET_ACCESS_KEY TLDR_R2_SECRET_ACCESS_KEY
    blink_deprecated_env BLINK_R2_RELEASE_PREFIX TLDR_R2_RELEASE_PREFIX
    blink_deprecated_env BLINK_SPARKLE_FEED_URL TLDR_SPARKLE_FEED_URL
    blink_deprecated_env BLINK_SPARKLE_PUBLIC_ED_KEY TLDR_SPARKLE_PUBLIC_ED_KEY
    blink_deprecated_env BLINK_SPARKLE_SIGN_UPDATE TLDR_SPARKLE_SIGN_UPDATE
    blink_deprecated_env BLINK_SPARKLE_KEYCHAIN_ACCOUNT TLDR_SPARKLE_KEYCHAIN_ACCOUNT
}
