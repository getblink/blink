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

- `Authorization: Bearer <token>`

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
- When `REDIS_URL` is configured, the server may cache response JSON keyed by
  input hash only when `allow_content_retention=true`.

Error responses:

- `401` — missing or invalid token
- `413` — screenshot exceeds 10MB
- `422` — invalid request envelope or missing screenshot/context
- `502` — Gemini upstream failure with a sanitized message
- `503` — Gemini parse error or schema mismatch

## `POST /v1/tldr/events`

Headers:

- `Authorization: Bearer <token>`

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

## `POST /tldr`

Legacy screenshot-only compatibility wrapper for older clients and the current
scratchpad proxy path.

Headers:

- `Authorization: Bearer <token>`

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
