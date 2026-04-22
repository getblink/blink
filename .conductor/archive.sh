#!/usr/bin/env bash
# Runs before Conductor deletes the workspace dir. Move gitignored
# experiment artifacts somewhere safe so nothing important is silently lost.
set -euo pipefail

ts="$(date +%Y%m%d-%H%M%S)"
dest="$HOME/conductor/archive/blink/${CONDUCTOR_WORKSPACE_NAME:-unknown}-$ts"

preserved=0
for sub in fixtures sweeps runs; do
  src="scratchpad/$sub"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    mkdir -p "$dest/scratchpad"
    cp -R "$src" "$dest/scratchpad/"
    preserved=1
  fi
done

if [ "$preserved" = "1" ]; then
  echo "[archive] preserved experiment artifacts to $dest" >&2
else
  echo "[archive] no experiment artifacts to preserve" >&2
fi
