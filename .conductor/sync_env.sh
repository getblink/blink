#!/usr/bin/env bash
# Sync the central env files to all existing workspaces under
# ~/conductor/workspaces/blink/.
#
# Conductor's setup.sh only copies env files once at workspace creation.
# This helper re-syncs existing workspaces from the canonical central
# copies so rotated credentials and new env vars propagate without
# recreating each workspace. Each workspace's existing file is backed up
# before overwrite.
#
# Files synced:
#   .env             — local-dev/staging proxy + R2/Sparkle release creds.
#                      Required.
#   .env.production  — production proxy URL/token embedded by release.sh.
#                      Optional; backfilled into workspaces that don't
#                      have it yet, since this file was added later.
#   .env.development — Astro dev-mode override that points the landing
#                      page at the staging Railway backend during
#                      `npm run dev`. Optional; backfilled.
#
# Usage:
#   .conductor/sync_env.sh            # actually sync
#   .conductor/sync_env.sh --dry-run  # show which workspaces would change

set -euo pipefail

CENTRAL_DIR="$HOME/conductor/repos/blink"
WORKSPACES_DIR="$HOME/conductor/workspaces/blink"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ ! -f "$CENTRAL_DIR/.env" ]; then
  echo "ERROR: central .env not found at $CENTRAL_DIR/.env" >&2
  exit 1
fi

# sync_one CENTRAL_FILE WORKSPACE_DIR FILE_BASENAME REQUIRED
#   REQUIRED=1 → "skip" line if workspace lacks the file (the workspace
#                is broken or empty; mirrors the original .env behaviour).
#   REQUIRED=0 → workspace gets the file even if it didn't have one before
#                (backfills newly-introduced files like .env.production).
sync_one() {
  local central="$1"
  local ws="$2"
  local base="$3"
  local required="$4"
  local ws_file="${ws}${base}"
  local ws_name; ws_name="$(basename "$ws")"

  if [ ! -f "$central" ]; then
    return 0
  fi
  if [ ! -f "$ws_file" ]; then
    if [ "$required" = "1" ]; then
      echo "skip   $ws_name $base (no $base — workspace may be empty/broken)"
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would  $ws_name $base (new file from central)"
    else
      cp "$central" "$ws_file"
      chmod 600 "$ws_file"
      echo "added  $ws_name $base"
    fi
    return 0
  fi
  if cmp -s "$central" "$ws_file"; then
    echo "ok     $ws_name $base (already in sync)"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    local central_keys ws_keys
    central_keys="$(grep -cE '^[A-Z][A-Z0-9_]*=' "$central" || true)"
    ws_keys="$(grep -cE '^[A-Z][A-Z0-9_]*=' "$ws_file" || true)"
    echo "would  $ws_name $base (central=$central_keys keys, workspace=$ws_keys keys)"
  else
    local backup="${ws_file}.bak.$(date +%Y%m%dT%H%M%S)"
    cp "$ws_file" "$backup"
    cp "$central" "$ws_file"
    echo "synced $ws_name $base (backup at $(basename "$backup"))"
  fi
}

shopt -s nullglob
for ws in "$WORKSPACES_DIR"/*/; do
  sync_one "$CENTRAL_DIR/.env"             "$ws" ".env"             1
  sync_one "$CENTRAL_DIR/.env.production"  "$ws" ".env.production"  0
  sync_one "$CENTRAL_DIR/.env.development" "$ws" ".env.development" 0
done
