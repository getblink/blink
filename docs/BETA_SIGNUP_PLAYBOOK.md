# Beta Signup Playbook

What happens when someone hits **join the beta** on
[useblink.dev](https://useblink.dev), and what to do next.

## End-to-end flow

1. Form on `site/src/pages/index.astro` POSTs `{email, source, hp}` to the
   server's `POST /v1/beta-signup` (Cloud Run, `https://api.useblink.dev`).
2. Server (`server/main.py:beta_signup`):
   - drops honeypot submissions silently,
   - rate-limits per hashed IP (5/min, 50/day; configurable),
   - inserts into Postgres `beta_signups` with `email_normalized` UNIQUE,
   - on a **new** row: fires PostHog `beta_signup_recorded` and a Discord
     webhook ping (background task, non-blocking),
   - on a **duplicate**: returns `200 {ok: true, already_signed_up: true}`
     and fires PostHog `beta_signup_duplicate` keyed on the IP-hash prefix.
     No Discord ping.
3. Client renders one of: `success`, `already`, `error-invalid`,
   `error-network`, `error-rate-limit`.

## When you'll find out

- **Discord** — set `BLINK_DISCORD_SIGNUP_WEBHOOK_URL` (GCP Secret Manager
  `blink-discord-signup-webhook`, wired into the Cloud Run service by the deploy
  workflow) to a channel webhook URL. Each new signup posts an embed with the
  email, source, and `signup_id`. Duplicate submits are silent.
- **PostHog** — funnel events:
  - `beta_signup_submitted` (client) → `beta_signup_recorded` (server) on the
    success path.
  - `beta_signup_duplicate` (server) on already-on-list.
  - `beta_signup_failed` (client, with `kind`) on validation / network /
    rate-limit failures.
- **Postgres** — source of truth, see queries below.

## Setting up the Discord webhook

1. In Discord: channel settings → **Integrations** → **Webhooks** →
   **New Webhook**. Name it `blink-signups`, copy the URL.
2. Set the Secret Manager value (wired into the Cloud Run service by the deploy
   workflow):
   ```bash
   printf 'https://discord.com/api/webhooks/...' \
     | gcloud secrets versions add blink-discord-signup-webhook \
         --project=blink-497308 --data-file=-
   ```
3. Redeploy. To verify, submit a fresh email on the live site or curl
   directly (note the double quotes — single quotes would block the
   `$(date +%s)` substitution and every run would hit the duplicate path):
   ```bash
   curl -X POST https://api.useblink.dev/v1/beta-signup \
     -H 'content-type: application/json' \
     --data-raw "{\"email\":\"smoke+$(date +%s)@useblink.dev\",\"source\":\"smoke-test\"}"
   ```
   Expect `{"ok":true,"signup_id":"…","already_signed_up":false}` and a
   Discord ping within a few seconds. Webhook failures are logged
   (`beta_signup_discord_failed`) and never affect the signup response.

## After someone signs up

The default response time should be **under 24 hours** while the beta is
small. Once volume grows past what's manual, switch to a daily batch.

1. **Acknowledge** — reply to the Discord ping with a 👍 once you've sent
   the invite, so the channel doubles as a worklist.
2. **Pull the latest signups** to confirm the row landed:
   ```bash
   psql "$DATABASE_URL" \
     -c "SELECT email_original, source, created_at
         FROM beta_signups
         ORDER BY created_at DESC LIMIT 25"
   ```
3. **Send the invite DM / email** with:
   - the current `Blink.app` DMG download URL,
   - one-line install + first-run instructions
     (`docs/DOGFOOD_PLAYBOOK.md` is the source for this),
   - a "reply with anything weird" ask.
4. **Tag the row** — there's no status column today; until there is, mark
   sent invites in a pinned doc or by replying to the Discord embed.

## Manually inviting / removing someone

Add a row by hand (rarely needed; the public form is the canonical path):

```sql
INSERT INTO beta_signups (id, email_normalized, email_original, source, ip_hash)
VALUES (replace(gen_random_uuid()::text, '-', ''),
        lower($1), $1, 'manual', 'manual')
ON CONFLICT (email_normalized) DO NOTHING;
```

Remove someone (GDPR-style request, etc.):

```sql
DELETE FROM beta_signups WHERE email_normalized = lower($1);
```

## Health checks

- **Endpoint up?**
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' \
    https://api.useblink.dev/v1/beta-signup \
    -X POST -H 'content-type: application/json' \
    -d '{"email":"healthcheck@useblink.dev"}'
  ```
- **Storage configured?** A `503 "beta signup storage unavailable"` means
  `DATABASE_URL` is missing or the Postgres connection is broken.
- **Discord configured?** `BLINK_DISCORD_SIGNUP_WEBHOOK_URL` unset → no
  notifications, no error. Failed POSTs to Discord show up as
  `beta_signup_discord_failed` in server logs.

## Future hooks (not built)

- Status column on `beta_signups` (`invited_at`, `installed_at`) so the
  invite worklist becomes a query, not a Discord scrollback search.
- Auto-send the invite DMG link via a transactional email provider.
- Slack webhook fallback alongside Discord.
