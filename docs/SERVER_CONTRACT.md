# TLDR Server Contract

This document defines the HTTP contract for the standalone TLDR app backend.
Implementation lives in [`server/`](../server/README.md).

## `GET /healthz`

Response:

```json
{"ok": true, "version": "<git sha>"}
```

## `POST /v1/tldr`

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
  "request_id": "req-123",
  "status": "ok",
  "tldr": "...",
  "suggestions": ["...", "...", "..."],
  "duration_ms": 1234,
  "model": "gemini-3.1-flash-lite-preview",
  "warnings": []
}
```

Operational rules:

- The request JSON carries the client envelope: `request_id`, client/build info,
  requested preferences, frontmost-app metadata, input mode, optional screenshot
  metadata, image diagnostics, optional OCR/focused-context packets, and
  consent flags.
- The server owns the prompt, schema, and final model policy.
- OCR/focused-context content may be used transiently to build Gemini context
  even when `allow_content_retention=false`, but stored telemetry must use a
  redacted envelope unless content retention is explicitly enabled.
- The server must not persist screenshot bytes or response bodies.
- When `DATABASE_URL` is configured, the server may persist structured
  request/event telemetry.
- Request telemetry includes the returned summary, suggestions, raw model
  output, and terminal outcome metadata. Screenshot bytes are never persisted.
- When `REDIS_URL` is configured, the server may cache response JSON keyed by
  input hash only when `allow_content_retention=true`.

Error responses:

- `401` — missing or invalid device/legacy token
- `413` — screenshot exceeds 10MB
- `422` — invalid request envelope or missing screenshot/context
- `502` — Gemini upstream failure with a sanitized message
- `503` — Gemini parse error or schema mismatch

## `POST /v1/tldr/events`

Headers:

- `Authorization: Bearer <device token>`; legacy shared tokens are accepted
  only while `BLINK_LEGACY_TOKEN_ALLOWED=true`

Body:

```json
{
  "schema_version": 1,
  "request_id": "req-123",
  "event_type": "capture_started",
  "created_at": "2026-04-29T17:00:00.000-07:00",
  "client": {
    "app_name": "TLDR",
    "app_version": "0.1.0"
  },
  "details": {
    "last_phase": "capture_started"
  }
}
```

Success response:

```json
{"ok": true, "stored": true}
```

`stored` is `true` only when the event reached durable telemetry storage. It is
`false` when event logging is disabled, storage is unavailable, or the backend
is running without a configured database.
Terminal events `suggestion_copied`, `suggestion_inserted`, and
`suggestion_dismissed` also update `tldr_requests.outcome` and optional
`tldr_requests.chosen_index`. The legacy event name `overlay_dismissed` is
accepted as an alias for `suggestion_dismissed` for older clients.

## `POST /v1/auth/mint`

Headers:

- `Authorization: Bearer <bootstrap token>`

Body:

```json
{"install_id": "anonymous-install-uuid"}
```

Success response:

```json
{"token": "tldr_dt_...", "token_type": "bearer"}
```

The returned token is shown only once to the client. The server stores its
SHA-256 hash and revokes any prior token for the same `install_id`.

During the upgrade window (default `BLINK_LEGACY_TOKEN_ALLOWED=true`) the
bootstrap token also satisfies non-mint endpoints so a fresh install isn't
bricked between launch and a successful mint round-trip. When
`BLINK_LEGACY_TOKEN_ALLOWED=false`, the bootstrap token is accepted only on
`/v1/auth/mint`.

`install_id` is capped at 128 characters.

The mint endpoint's per-IP rate limit reads `X-Forwarded-For` only when
`TLDR_TRUST_PROXY_HEADERS=true`. Set this when the server runs behind a
trusted reverse proxy (Railway, Cloudflare, etc.); otherwise the limit
falls back to `request.client.host`.

Error responses:

- `401` — missing or invalid bootstrap token
- `422` — request body is not valid JSON, missing `install_id`, or
  `install_id` exceeds 128 characters
- `429` — per-IP mint rate limit exceeded (default 5/minute, configurable
  via `TLDR_MINT_RATE_LIMIT_PER_MINUTE`)
- `500` — `BLINK_BOOTSTRAP_TOKEN` is empty (server misconfigured)
- `503` — device token storage is unavailable

## `POST /tldr`

Legacy screenshot-only compatibility wrapper for older clients and the current
scratchpad proxy path.

Headers:

- `Authorization: Bearer <device or legacy token>`

Body:

- `multipart/form-data`
- `screenshot=<image/png>`

Success response:

```json
{
  "tldr": "...",
  "suggestions": ["...", "...", "..."],
  "duration_ms": 1234,
  "model": "gemini-3.1-flash-lite-preview"
}
```
