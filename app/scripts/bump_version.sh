#!/usr/bin/env bash
# Bump CFBundleShortVersionString in BOTH app/Blink/Info.plist AND
# app/project.yml atomically. xcodegen regenerates Info.plist from
# project.yml on every build, so missing the yaml entry means
# release.sh ships the old version even though Info.plist looks bumped.
# Caught on 0.2.21 — see commit history and release.sh's version-drift
# guard for the post-mortem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$APP_DIR/Blink/Info.plist"
PROJECT_YML="$APP_DIR/project.yml"

if [[ $# -ne 1 ]]; then
    cat >&2 <<'USAGE'
usage: bump_version.sh <X.Y.Z>

Bumps CFBundleShortVersionString in both app/Blink/Info.plist and
app/project.yml to <X.Y.Z>. Run from the project root or anywhere —
the script resolves its own paths.

After bumping, commit both files and ship via release.sh.
USAGE
    exit 1
fi

NEW_VERSION="$1"
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[blink] error: version must be X.Y.Z (got: $NEW_VERSION)" >&2
    exit 1
fi

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[blink] error: missing required command: $1" >&2
        exit 1
    fi
}
require /usr/libexec/PlistBuddy

OLD_INFO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
OLD_YML_VERSION="$(awk -F'"' '/^[[:space:]]+CFBundleShortVersionString:/ {print $2; exit}' "$PROJECT_YML")"

if [[ "$OLD_INFO_VERSION" != "$OLD_YML_VERSION" ]]; then
    echo "[blink] warn: pre-existing version drift between files" >&2
    echo "[blink]   Info.plist:   $OLD_INFO_VERSION" >&2
    echo "[blink]   project.yml:  $OLD_YML_VERSION" >&2
    echo "[blink] continuing — both will be set to $NEW_VERSION" >&2
fi

if [[ "$OLD_INFO_VERSION" == "$NEW_VERSION" && "$OLD_YML_VERSION" == "$NEW_VERSION" ]]; then
    echo "[blink] both files already at $NEW_VERSION — nothing to do"
    exit 0
fi

# Edit Info.plist via PlistBuddy (safe — schema-aware).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST"

# Edit project.yml via sed (in-place, BSD sed needs '' after -i).
sed -i '' "s/^\([[:space:]]*CFBundleShortVersionString:[[:space:]]*\)\"[^\"]*\"/\1\"$NEW_VERSION\"/" "$PROJECT_YML"

# Verify the edits stuck.
NEW_INFO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
NEW_YML="$(awk -F'"' '/^[[:space:]]+CFBundleShortVersionString:/ {print $2; exit}' "$PROJECT_YML")"
if [[ "$NEW_INFO" != "$NEW_VERSION" || "$NEW_YML" != "$NEW_VERSION" ]]; then
    echo "[blink] error: post-edit verification failed" >&2
    echo "[blink]   Info.plist:   $NEW_INFO (expected $NEW_VERSION)" >&2
    echo "[blink]   project.yml:  $NEW_YML (expected $NEW_VERSION)" >&2
    exit 1
fi

echo "[blink] bumped CFBundleShortVersionString: $OLD_INFO_VERSION -> $NEW_VERSION"
echo "[blink]   $INFO_PLIST"
echo "[blink]   $PROJECT_YML"
echo
echo "Next:"
echo "  git add $INFO_PLIST $PROJECT_YML"
echo "  git commit -m \"Bump $NEW_VERSION: <release notes>\""
echo "  # then PR + merge + release.sh"
