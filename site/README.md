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

- `PUBLIC_BETA_SIGNUP_URL` — beta-signup endpoint. Defaults to the production Railway URL (`https://blink-production-7b5a.up.railway.app/v1/beta-signup`); set to override for local/staging.
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
