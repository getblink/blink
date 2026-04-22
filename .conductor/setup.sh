#!/usr/bin/env bash
# Runs once, inside a freshly-created Conductor workspace (cwd = workspace root).
# Idempotent: safe to re-run by hand.
set -euo pipefail

python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install --quiet --upgrade pip
scratchpad/.venv/bin/pip install --quiet -r scratchpad/requirements.txt

fx_dir="$(
  scratchpad/.venv/bin/python - <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path("scratchpad/settings.json")

try:
    settings = json.loads(settings_path.read_text())
except Exception as exc:  # pragma: no cover - shell bootstrap path
    print(f"ERROR: failed to read {settings_path}: {exc}", file=sys.stderr)
    raise SystemExit(1)

value = settings.get("fixtures_dir")
if not isinstance(value, str):
    print(
        f"ERROR: {settings_path} is missing a string fixtures_dir.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(value)
PY
)"

if [ "$fx_dir" != "fixtures" ]; then
  echo "ERROR: scratchpad/settings.json has fixtures_dir=\"$fx_dir\"." >&2
  echo "       Shared-pool setup requires the default \"fixtures\". Either" >&2
  echo "       reset it, or delete this check from .conductor/setup.sh to" >&2
  echo "       deliberately opt out of the shared pool." >&2
  exit 1
fi

POOL="$HOME/conductor/shared/blink/fixtures"
mkdir -p "$POOL"

if [ -d scratchpad/fixtures ]; then
  rm -f scratchpad/fixtures/.DS_Store scratchpad/fixtures/Icon$'\r' 2>/dev/null || true
fi

if [ -L scratchpad/fixtures ]; then
  if [ "$(readlink scratchpad/fixtures)" != "$POOL" ]; then
    ln -sfn "$POOL" scratchpad/fixtures
  fi
elif [ -d scratchpad/fixtures ]; then
  if [ -z "$(ls -A scratchpad/fixtures 2>/dev/null)" ]; then
    rmdir scratchpad/fixtures
    ln -s "$POOL" scratchpad/fixtures
  else
    echo "[setup] scratchpad/fixtures has local contents; leaving it alone." >&2
    echo "        Run .conductor/migrate_fixtures.sh to merge into the shared pool." >&2
  fi
else
  ln -s "$POOL" scratchpad/fixtures
fi

env_source=""
if [ -n "${CONDUCTOR_ROOT_PATH:-}" ]; then
  env_source="$CONDUCTOR_ROOT_PATH/.env"
fi

env_status="missing"
if [ -f "$env_source" ]; then
  cp "$env_source" .env
  env_status="copied"
else
  echo "WARNING: no .env at \$CONDUCTOR_ROOT_PATH/.env." >&2
  echo "         Create it once (see .env.example) so future workspaces inherit the key." >&2
fi

fixtures_mode="missing"
fixtures_target=""
if [ -L scratchpad/fixtures ]; then
  fixtures_mode="symlink"
  fixtures_target="$(readlink scratchpad/fixtures)"
elif [ -d scratchpad/fixtures ]; then
  fixtures_mode="directory"
fi

setup_receipt_dir=".context/conductor"
setup_receipt_path="$setup_receipt_dir/setup-receipt.json"
mkdir -p "$setup_receipt_dir"

SETUP_RECEIPT_PATH="$setup_receipt_path" \
SETUP_RAN_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
SETUP_WORKSPACE_NAME="${CONDUCTOR_WORKSPACE_NAME:-unknown}" \
SETUP_WORKSPACE_DIR="$PWD" \
SETUP_FIXTURES_DIR="$fx_dir" \
SETUP_FIXTURES_MODE="$fixtures_mode" \
SETUP_FIXTURES_TARGET="$fixtures_target" \
SETUP_SHARED_POOL="$POOL" \
SETUP_ENV_SOURCE="$env_source" \
SETUP_ENV_STATUS="$env_status" \
python3 - <<'PY'
import json
import os
from pathlib import Path


def optional_env(name):
    value = os.environ.get(name, "")
    return value or None


payload = {
    "script": ".conductor/setup.sh",
    "status": "ok",
    "ran_at": os.environ["SETUP_RAN_AT"],
    "workspace_name": os.environ["SETUP_WORKSPACE_NAME"],
    "workspace_dir": os.environ["SETUP_WORKSPACE_DIR"],
    "fixtures_dir_setting": os.environ["SETUP_FIXTURES_DIR"],
    "fixtures_mode": os.environ["SETUP_FIXTURES_MODE"],
    "fixtures_target": optional_env("SETUP_FIXTURES_TARGET"),
    "shared_fixture_pool": os.environ["SETUP_SHARED_POOL"],
    "env_source": optional_env("SETUP_ENV_SOURCE"),
    "env_status": os.environ["SETUP_ENV_STATUS"],
}

path = Path(os.environ["SETUP_RECEIPT_PATH"])
path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
PY

echo "[setup] wrote receipt to $setup_receipt_path" >&2
