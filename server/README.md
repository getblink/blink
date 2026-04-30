# TLDR Server

Small FastAPI backend for the standalone TLDR app experiment. It owns the
Gemini call so the shipped client never carries `GEMINI_API_KEY`, and it
reuses Blink's capability-token convention for closed dogfood.

Railway should deploy this service with the service root set to `server/`.

See also:

- [`docs/SERVER_CONTRACT.md`](../docs/SERVER_CONTRACT.md) for the endpoint contract the Swift workspace can depend on
- [`scratchpad/tldr_reply/README.md`](../scratchpad/tldr_reply/README.md) for the local hotkey experiment that can dogfood this endpoint

## Endpoints

### `GET /healthz`

Returns:

```json
{"ok": true, "version": "<git sha>"}
```

### `POST /v1/tldr`

Headers:

- `Authorization: Bearer <token>`

Body:

- `multipart/form-data`
- `request=<application/json>`
- `screenshot=<image/png>` optional

Success response:

```json
{
  "request_id": "...",
  "status": "ok",
  "tldr": "...",
  "suggestions": ["...", "...", "..."],
  "duration_ms": 1234,
  "model": "gemini-3.1-flash-lite-preview",
  "warnings": []
}
```

Error status codes:

- `401` missing or invalid bearer token
- `413` screenshot exceeds the 10MB cap
- `422` invalid request envelope
- `502` Gemini upstream error
- `503` Gemini parse error or schema mismatch

### `POST /v1/tldr/events`

Accepts client behavior and diagnostics events keyed by `request_id` and
returns `{"ok": true, "stored": <bool>}` so the client can tell whether the
event actually reached durable storage. `stored` is `false` when logging is
disabled, the database is unavailable, or telemetry storage is not configured.

### `POST /tldr`

Legacy screenshot-only compatibility wrapper that preserves the original
response shape for existing clients.

The server does not write screenshots or response bodies to disk. It may use
OCR/focused-context content transiently for Gemini context even when content
retention is off, but stored telemetry is redacted unless the client opts into
content retention. When `DATABASE_URL` is configured it persists structured
request/event diagnostics; when `REDIS_URL` is configured it may cache response
JSON keyed by input hash only for requests that opted into content retention.

## Environment

Copy [`server/.env.example`](.env.example) into the repo-root `.env` or
`.env.local` for local dev. Required variables:

- `GEMINI_API_KEY` — Railway secret or local dev key
- `BLINK_API_TOKENS` — comma-separated accepted bearer tokens
- `DATABASE_URL` — optional Postgres telemetry storage
- `REDIS_URL` — optional Redis cache endpoint
- `TLDR_ALLOWED_MODELS` — comma-separated server allowlist
- `TLDR_EVENT_LOGGING` — defaults to `true`
- `TLDR_CACHE_RESPONSES` — defaults to `true`
- `TLDR_RESPONSE_CACHE_TTL_SECONDS` — defaults to `86400`

Client-side variables used by the local TLDR runner and future Swift app:

- `BLINK_PROXY_URL` — base URL of this server, for example `http://localhost:8000`
- `BLINK_PROXY_TOKEN` — one tester token from `BLINK_API_TOKENS`

## Local development

From the repo root:

```bash
python3.11 -m venv server/.venv
server/.venv/bin/pip install -r server/requirements.txt
server/.venv/bin/uvicorn server.main:app --reload
```

Then verify:

```bash
curl http://127.0.0.1:8000/healthz
curl -X POST \
  -H "Authorization: Bearer <token>" \
  -F 'request={"request_id":"local-1","input_mode":"screenshot"};type=application/json' \
  -F "screenshot=@scratchpad/fixtures/<fixture>/target.png;type=image/png" \
  http://127.0.0.1:8000/v1/tldr
```

## Railway deploy

Most build/deploy settings live in [`railway.json`](railway.json). For a new
or existing Railway service, the remaining one-time dashboard wiring is:

1. Connect the service to this GitHub repo and branch.
2. Set the Railway service root directory to `/server`.
3. Set the Railway config file path to `/server/railway.json`.
4. Set `GEMINI_API_KEY` and `BLINK_API_TOKENS` as service variables.
5. Optional but recommended for telemetry: attach Postgres and set
   `DATABASE_URL=${{Postgres.DATABASE_URL}}`.
6. Optional for response caching: attach Redis and set
   `REDIS_URL=${{Redis.REDIS_URL}}`.
7. Deploy and confirm `GET /healthz` returns `200`.
8. Point `BLINK_PROXY_URL` at the deployed URL for dogfood clients.

Railway config-as-code does not currently replace the service source/root
directory/config-file-path selection. Those pointers identify which slice of
this repo the service should deploy; the repeatable build and deploy behavior is
then sourced from `server/railway.json`.

The backend config includes a `/server/**` watch pattern so changes to the
separate landing-page service under `site/` do not redeploy the TLDR API.

## Fork note

`server/gemini.py` is a deliberate fork of
`scratchpad/tldr_reply/gemini.py`. Prompt iteration still happens in
`scratchpad/tldr_reply/`; once a prompt wins, promote it into
[`server/prompt.txt`](prompt.txt) and redeploy.
