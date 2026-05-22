#!/bin/bash
# Start a local uvicorn instance of the Blink server for latency experiments.
# Auth: legacy BLINK_API_TOKENS path, no DB or Redis needed.
set -e
cd "$(dirname "$0")/../.."

# Load GEMINI_API_KEY etc from .env
set -a
source .env
set +a

# Override / set local-test config
export BLINK_API_TOKENS="local-test-token,${BLINK_API_TOKENS:-}"
export BLINK_LEGACY_TOKEN_ALLOWED=1
unset DATABASE_URL
unset REDIS_URL
unset BLINK_RATE_LIMIT_REDIS_URL
unset TLDR_RATE_LIMIT_REDIS_URL

export PORT="${PORT:-8765}"

cd server
exec python3 -m uvicorn main:app --host 127.0.0.1 --port "$PORT" --log-level warning
