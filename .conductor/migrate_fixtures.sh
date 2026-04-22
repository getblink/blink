#!/usr/bin/env bash
# One-time helper for workspaces that captured fixtures before shared-pool setup.
set -euo pipefail

fx="scratchpad/fixtures"
pool="$HOME/conductor/shared/blink/fixtures"

mkdir -p "$pool"

if [ -L "$fx" ]; then
  echo "[migrate] scratchpad/fixtures is already a symlink ($(readlink "$fx"))" >&2
  exit 0
fi

if [ ! -d "$fx" ]; then
  echo "[migrate] scratchpad/fixtures is not a local directory; nothing to migrate" >&2
  exit 0
fi

rm -f "$fx/.DS_Store" "$fx/Icon"$'\r' 2>/dev/null || true

shopt -s nullglob dotglob

moved=0
collisions=0
blockers=0

for entry in "$fx"/*; do
  name="$(basename "$entry")"

  if [ ! -d "$entry" ]; then
    echo "[migrate] leaving unexpected entry in place: $name" >&2
    blockers=1
    continue
  fi

  if [ -e "$pool/$name" ]; then
    echo "[migrate] pool already has $name; leaving local copy for manual resolution" >&2
    collisions=1
    continue
  fi

  mv "$entry" "$pool/"
  echo "[migrate] moved $name" >&2
  moved=$((moved + 1))
done

if [ -z "$(ls -A "$fx" 2>/dev/null)" ]; then
  rmdir "$fx"
  ln -s "$pool" "$fx"
  echo "[migrate] linked scratchpad/fixtures -> $pool" >&2
  echo "[migrate] moved $moved fixture(s)" >&2
  exit 0
fi

echo "[migrate] migration incomplete; scratchpad/fixtures still has local contents" >&2
echo "[migrate] moved $moved fixture(s), collisions=$collisions, blockers=$blockers" >&2
exit 1
