# site

Marketing site for Blink. Static Astro build, deployed to Cloudflare Pages.

## Develop

```bash
cd site
npm install
npm run dev
```

Dev server: http://localhost:4321

## Build

```bash
npm run build
```

Static output lands in `site/dist/`.

Public env vars are optional and have sensible defaults:

- `PUBLIC_BETA_SIGNUP_URL` — beta-signup endpoint on the Cloud Run server. Set to `https://api.useblink.dev/v1/beta-signup` in production (or `https://api-staging.useblink.dev/v1/beta-signup` for staging). ⚠️ The in-code default in `src/pages/index.astro` still points at the **decommissioned** Railway URL (`https://blink-production-7b5a.up.railway.app/v1/beta-signup`), which no longer responds — so this env var **must** be set in the deployed site environment until that default is fixed.
- `PUBLIC_DEMO_VIDEO_URL_DESKTOP` — hosted MP4 URL(s) for the desktop demo cell (3:4 portrait next to the wordmark). Comma-separated for multiple clips (the page cross-fades between them).
- `PUBLIC_DEMO_VIDEO_URL_MOBILE` — hosted MP4 URL(s) for the mobile demo cell (3:4 portrait, `object-fit: contain` — fills the remaining vertical space below the wordmark+form). Same comma-separated format. Use a different clip if you want a tighter mobile cut, or point at the same URL as desktop.

If either is unset, that viewport's slot renders a "demo coming soon" placeholder so the build still succeeds before the videos are uploaded.

The Astro config reads env vars from the workspace-root `.env` (via `vite.envDir: ".."`), so the existing Conductor `sync_env.sh` flow (`docs/CONTRIBUTING_INTERNAL.md`) propagates them automatically — no per-workspace `site/.env` needed.

For local work, copy `.env.example` to `.env` and adjust the URLs as needed.

## Deploy to Cloudflare Pages

No adapter needed — the build is pure static.

- **Framework preset:** Astro
- **Build command:** `npm run build`
- **Build output directory:** `dist`
- **Root directory:** `site`
- **Environment variables:** set `PUBLIC_DEMO_VIDEO_URL_DESKTOP` and `PUBLIC_DEMO_VIDEO_URL_MOBILE` once the demo MP4s are hosted, and `PUBLIC_BETA_SIGNUP_URL` if you ever want to point at a non-production endpoint.
