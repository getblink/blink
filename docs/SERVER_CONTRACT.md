# TLDR Server Contract

This document defines the HTTP contract for the standalone TLDR app backend.
Implementation lives in [`server/`](../server/README.md).

## `GET /healthz`

Response:

```json
{"ok": true, "version": "<git sha>"}
```

## `POST /tldr`

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

Error responses:

- `401` — missing or invalid token
- `413` — screenshot exceeds 10MB
- `502` — Gemini upstream failure with a sanitized message
- `503` — Gemini parse error or schema mismatch

Operational rules:

- The server owns the prompt, schema, and model selection.
- The server must not persist screenshots or response bodies.
- Logging is limited to `token_id`, `status`, `duration_ms`, and `usage_tokens`.
- `BLINK_PROXY_URL` stays non-secret on the client; `BLINK_PROXY_TOKEN` is a
  revocable dogfood capability token.
