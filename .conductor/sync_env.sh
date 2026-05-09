#!/usr/bin/env bash
# Sync the central .env to all existing workspaces under
# ~/conductor/workspaces/blink/.
#
# Conductor's setup.sh only copies .env once at workspace creation. This
# helper re-syncs existing workspaces from the canonical central .env so
# rotated credentials and new env vars propagate without recreating each
# workspace. Each workspace's existing .env is backed up before overwrite.
#
# Usage:
#   .conductor/sync_env.sh            # actually sync
#   .conductor/sync_env.sh --dry-run  # show which workspaces would change

set -euo pipefail

CENTRAL_ENV="$HOME/conductor/repos/blink/.env"
WORKSPACES_DIR="$HOME/conductor/workspaces/blink"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ ! -f "$CENTRAL_ENV" ]; then
  echo "ERROR: central .env not found at $CENTRAL_ENV" >&2
  exit 1
fi

shopt -s nullglob
for ws in "$WORKSPACES_DIR"/*/; do
  ws_env="${ws}.env"
  ws_name="$(basename "$ws")"
  if [ ! -f "$ws_env" ]; then
    echo "skip   $ws_name (no .env — workspace may be empty/broken)"
    continue
  fi
  if cmp -s "$CENTRAL_ENV" "$ws_env"; then
    echo "ok     $ws_name (already in sync)"
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    central_keys="$(grep -cE '^[A-Z_]+=' "$CENTRAL_ENV" || true)"
    ws_keys="$(grep -cE '^[A-Z_]+=' "$ws_env" || true)"
    echo "would  $ws_name (central=$central_keys keys, workspace=$ws_keys keys)"
  else
    backup="${ws_env}.bak.$(date +%Y%m%dT%H%M%S)"
    cp "$ws_env" "$backup"
    cp "$CENTRAL_ENV" "$ws_env"
    echo "synced $ws_name (backup at $(basename "$backup"))"
  fi
done
