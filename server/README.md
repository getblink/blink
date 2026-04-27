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

### `POST /tldr`

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

Error status codes:

- `401` missing or invalid bearer token
- `413` screenshot exceeds the 10MB cap
- `502` Gemini upstream error
- `503` Gemini parse error or schema mismatch

The server does not write screenshots or responses to disk. It only logs
`token_id`, `status`, `duration_ms`, and `usage_tokens`.

## Environment

Copy [`server/.env.example`](.env.example) into the repo-root `.env` or
`.env.local` for local dev. Required variables:

- `GEMINI_API_KEY` — Railway secret or local dev key
- `BLINK_API_TOKENS` — comma-separated accepted bearer tokens

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
  -F "screenshot=@scratchpad/fixtures/<fixture>/target.png;type=image/png" \
  http://127.0.0.1:8000/tldr
```

## Railway deploy

1. Set the Railway service root directory to `server/`.
2. Set `GEMINI_API_KEY` and `BLINK_API_TOKENS` as Railway secrets.
3. Use the start command from `server/Procfile`, which resolves to:
   `uvicorn main:app --host 0.0.0.0 --port $PORT`
4. Deploy and confirm `GET /healthz` returns `200`.
5. Point `BLINK_PROXY_URL` at the deployed URL for dogfood clients.

## Fork note

`server/gemini.py` is a deliberate fork of
`scratchpad/tldr_reply/gemini.py`. Prompt iteration still happens in
`scratchpad/tldr_reply/`; once a prompt wins, promote it into
[`server/prompt.txt`](prompt.txt) and redeploy.
