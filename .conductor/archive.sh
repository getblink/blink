#!/usr/bin/env bash
# Runs before Conductor deletes the workspace dir. Move gitignored
# experiment artifacts somewhere safe so nothing important is silently lost.
set -euo pipefail

ts="$(date +%Y%m%d-%H%M%S)"
archive_root="$HOME/conductor/archive/blink"
dest="$archive_root/${CONDUCTOR_WORKSPACE_NAME:-unknown}-$ts"
archive_log_path="$archive_root/_archive_runs.jsonl"

mkdir -p "$archive_root"

write_archive_receipt() {
  local receipt_path="$1"
  local pretty="$2"

  ARCHIVE_RECEIPT_PATH="$receipt_path" \
  ARCHIVE_RECEIPT_PRETTY="$pretty" \
  ARCHIVE_RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  ARCHIVE_WORKSPACE_NAME="${CONDUCTOR_WORKSPACE_NAME:-unknown}" \
  ARCHIVE_WORKSPACE_DIR="$PWD" \
  ARCHIVE_DEST="${archive_dest:-}" \
  ARCHIVE_PRESERVED="$preserved" \
  ARCHIVE_SWEEPS_COPIED="$sweeps_copied" \
  ARCHIVE_RUNS_COPIED="$runs_copied" \
  ARCHIVE_FIXTURES_COPIED="$fixtures_copied" \
  ARCHIVE_FIXTURES_MODE="$fixtures_mode" \
  ARCHIVE_FIXTURES_TARGET="$fixtures_target" \
  python3 - <<'PY'
import json
import os
from pathlib import Path


def as_bool(name):
    return os.environ.get(name) == "1"


def optional_env(name):
    value = os.environ.get(name, "")
    return value or None


payload = {
    "script": ".conductor/archive.sh",
    "status": "ok",
    "ran_at": os.environ["ARCHIVE_RAN_AT"],
    "workspace_name": os.environ["ARCHIVE_WORKSPACE_NAME"],
    "workspace_dir": os.environ["ARCHIVE_WORKSPACE_DIR"],
    "archive_dest": optional_env("ARCHIVE_DEST"),
    "preserved": as_bool("ARCHIVE_PRESERVED"),
    "copied": {
        "sweeps": as_bool("ARCHIVE_SWEEPS_COPIED"),
        "runs": as_bool("ARCHIVE_RUNS_COPIED"),
        "fixtures": as_bool("ARCHIVE_FIXTURES_COPIED"),
    },
    "fixtures_mode": os.environ["ARCHIVE_FIXTURES_MODE"],
    "fixtures_target": optional_env("ARCHIVE_FIXTURES_TARGET"),
}

path = Path(os.environ["ARCHIVE_RECEIPT_PATH"])
path.parent.mkdir(parents=True, exist_ok=True)
pretty = os.environ.get("ARCHIVE_RECEIPT_PRETTY") == "1"
with path.open("w" if pretty else "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, indent=2 if pretty else None, ensure_ascii=True) + "\n")
PY
}

preserved=0
has_references=0
sweeps_copied=0
runs_copied=0
fixtures_copied=0
fixtures_mode="missing"
fixtures_target=""
archive_dest=""

for sub in sweeps runs; do
  src="scratchpad/$sub"
  if [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
    mkdir -p "$dest/scratchpad"
    cp -R "$src" "$dest/scratchpad/"
    preserved=1
    has_references=1
    if [ "$sub" = "sweeps" ]; then
      sweeps_copied=1
    else
      runs_copied=1
    fi
  fi
done

fx="scratchpad/fixtures"
if [ -L "$fx" ]; then
  fixtures_mode="symlink"
  fixtures_target="$(readlink "$fx")"
  if [ "$has_references" = "1" ]; then
    mkdir -p "$dest/scratchpad"
    cp -RL "$fx" "$dest/scratchpad/"
    preserved=1
    fixtures_copied=1
  fi
elif [ -d "$fx" ] && [ -n "$(ls -A "$fx" 2>/dev/null)" ]; then
  fixtures_mode="directory"
  mkdir -p "$dest/scratchpad"
  cp -R "$fx" "$dest/scratchpad/"
  preserved=1
  fixtures_copied=1
elif [ -d "$fx" ]; then
  fixtures_mode="directory"
fi

if [ "$preserved" = "1" ]; then
  archive_dest="$dest"
fi

write_archive_receipt "$archive_log_path" 0
echo "[archive] appended receipt to $archive_log_path" >&2

if [ "$preserved" = "1" ]; then
  write_archive_receipt "$dest/archive-receipt.json" 1
  echo "[archive] wrote receipt to $dest/archive-receipt.json" >&2
  echo "[archive] preserved experiment artifacts to $dest" >&2
else
  echo "[archive] no experiment artifacts to preserve" >&2
fi
