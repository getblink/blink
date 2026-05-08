# Blink Server

Small FastAPI backend for the standalone Blink app experiment. It owns the
Gemini call so the shipped client never carries `GEMINI_API_KEY`, and it
reuses Blink's capability-token convention for closed dogfood.

Railway should deploy this service with the service root set to `server/`.

## Protocol naming carve-out

Blink is the product name, but the v1 wire/storage protocol keeps its original
`tldr` identifiers for compatibility with deployed clients and existing data:
`/v1/tldr`, `/v1/tldr/events`, the `tldr_*` Postgres tables/view, the
`tldr:v1:` cache prefix, and `tldr_dt_` device tokens. New user-facing docs,
apps, paths, and env vars should say Blink.

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

- `Authorization: Bearer <device token>`; legacy shared tokens are accepted
  only while `BLINK_LEGACY_TOKEN_ALLOWED=true`

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
  "model": "gemini-3-flash-preview",
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
Outcome (`copied` / `inserted` / `dismissed` / `user_typed` / `paste_failed`)
and `chosen_index` are derived from the latest `run_completed` event for
each request via the `tldr_requests_with_outcome` view; the events handler
itself does not mutate `tldr_requests`.

### `POST /v1/auth/mint`

Mint a per-install device token. This endpoint accepts only the bootstrap token:

```json
{"install_id": "anonymous-install-uuid"}
```

Success response:

```json
{"token": "tldr_dt_...", "token_type": "bearer"}
```

The plaintext token is returned once. The server stores only its SHA-256 hash,
revokes any prior token for that `install_id`, and rate-limits minting per IP.

### `POST /v1/beta-signup`

Public endpoint for the `useblink.dev` beta signup form:

```json
{"email": "person@example.com", "source": "useblink.dev", "hp": ""}
```

The `hp` field is a honeypot. Non-empty values return `{"ok": true}` without
writing a row. Valid emails are trimmed, lowercased for uniqueness, and stored
with the original submitted casing preserved. The endpoint always returns
`{"ok": true}` for valid submissions, including duplicate emails, so it does
not leak whether an address is already on the list.

Signup rows live in `beta_signups`:

```sql
CREATE TABLE beta_signups (
    id TEXT PRIMARY KEY,
    email_normalized TEXT NOT NULL UNIQUE,
    email_original TEXT NOT NULL,
    source TEXT,
    user_agent TEXT,
    ip_hash TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

`ip_hash` is `sha256(BLINK_IP_HASH_SALT + client_ip)`. The raw IP is not
stored; the hash is kept only for rate-limiting and abuse forensics. Emails are
for sending the beta DMG, not marketing.

There is no HTTP read endpoint. Inspect signups directly in Postgres:

```bash
railway run psql $DATABASE_URL \
  -c "SELECT email_original, source, created_at FROM beta_signups ORDER BY created_at DESC LIMIT 100"
```

### `POST /tldr`

Legacy screenshot-only compatibility wrapper that preserves the original
response shape for existing clients.

The server does not write screenshots or response bodies to disk. It may use
OCR/focused-context/stateful-context content transiently for Gemini context even
when content retention is off, but stored telemetry is redacted unless the
client opts into content retention. `stateful_context` is the local Blink memory
POC: user-typed voice samples plus bounded same-surface recent history supplied
by the app from prior run artifacts. When `DATABASE_URL` is configured it
persists structured request/event diagnostics; when `REDIS_URL` is configured it
may cache response JSON keyed by input hash only for requests that opted into
content retention.

Each Blink install sends an anonymous `client.install_id` UUID generated on the
device and persisted at `~/.blink/install_id`. When Postgres telemetry is
enabled, the server stores it on both `tldr_requests.install_id` and
`tldr_events.install_id` so per-install trajectories can be reconstructed
without relying on bearer-token uniqueness:

```sql
SELECT *
FROM tldr_requests
JOIN tldr_events USING (request_id)
WHERE tldr_requests.install_id = $1
ORDER BY tldr_requests.created_at, tldr_events.created_at;
```

The shipped app also stores its minted bearer token at `~/.blink/device_token`
with mode `0600`. Deleting `~/.blink/device_token` causes the app to mint a
replacement token on the next launch. Deleting `~/.blink/install_id` rotates the
anonymous identifier.

## Environment

Copy [`server/.env.example`](.env.example) into the repo-root `.env` or
`.env.local` for local dev. Required variables:

- `GEMINI_API_KEY` — Railway secret or local dev key
- `BLINK_BOOTSTRAP_TOKEN` — accepted only by `/v1/auth/mint`
- `BLINK_API_TOKENS` — comma-separated legacy bearer tokens for the deprecation window
- `BLINK_LEGACY_TOKEN_ALLOWED` — defaults to `true`; set `false` after legacy builds age out
- `DATABASE_URL` — optional Postgres telemetry storage
- `REDIS_URL` — optional Redis cache endpoint
- `BLINK_ALLOWED_MODELS` — comma-separated server allowlist
- `BLINK_EVENT_LOGGING` — defaults to `true`
- `BLINK_CACHE_RESPONSES` — defaults to `true`
- `BLINK_RESPONSE_CACHE_TTL_SECONDS` — defaults to `86400`
- `BLINK_MINT_RATE_LIMIT_PER_MINUTE` — defaults to `5` per client IP
- `BLINK_IP_HASH_SALT` — persisted salt for beta-signup IP hashes
- `BLINK_SIGNUP_RATE_LIMIT_PER_MINUTE` — defaults to `5` per hashed IP
- `BLINK_SIGNUP_RATE_LIMIT_PER_DAY` — defaults to `50` per hashed IP

Client-side variables used by the local Blink runner and future Swift app:

- `BLINK_PROXY_URL` — base URL of this server, for example `http://localhost:8000`
- `BLINK_PROXY_TOKEN` — bootstrap token for packaged builds; device tokens in
  `~/.blink/device_token` take precedence once minted

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

Postgres does not need a manual migration step for v1. When `DATABASE_URL` is
present, the server lazily creates `tldr_requests` and `tldr_events` with
`CREATE TABLE IF NOT EXISTS` before its first write. Redis also needs no manual
setup; when `REDIS_URL` is present, the server writes TTL-based response-cache
keys and silently treats cache failures as misses. Response caching is only used
for requests that explicitly allow content retention.

Railway config-as-code does not currently replace the service source/root
directory/config-file-path selection. Those pointers identify which slice of
this repo the service should deploy; the repeatable build and deploy behavior is
then sourced from `server/railway.json`.

The backend config includes a `/server/**` watch pattern so changes to the
separate landing-page service under `site/` do not redeploy the Blink API.

## Fork note

`server/gemini.py` is a deliberate fork of
`scratchpad/tldr_reply/gemini.py`. Prompt iteration still happens in
`scratchpad/tldr_reply/`; once a prompt wins, promote it into
[`server/prompt.txt`](prompt.txt) and redeploy.
