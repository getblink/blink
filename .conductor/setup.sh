#!/usr/bin/env bash
# Runs once, inside a freshly-created Conductor workspace (cwd = workspace root).
# Idempotent: safe to re-run by hand.
set -euo pipefail

python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install --quiet --upgrade pip
scratchpad/.venv/bin/pip install --quiet -r scratchpad/requirements.txt

if [ -f "${CONDUCTOR_ROOT_PATH:-}/.env" ]; then
  cp "$CONDUCTOR_ROOT_PATH/.env" .env
else
  echo "WARNING: no .env at \$CONDUCTOR_ROOT_PATH/.env." >&2
  echo "         Create it once (see .env.example) so future workspaces inherit the key." >&2
fi
