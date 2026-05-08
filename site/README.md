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

Both public env vars are optional and have sensible defaults:

- `PUBLIC_BETA_SIGNUP_URL` — beta-signup endpoint. Defaults to the production Railway URL (`https://blink-production-7b5a.up.railway.app/v1/beta-signup`); set to override for local/staging.
- `PUBLIC_DEMO_VIDEO_URL` — hosted MP4 demo video URL. If unset, the page renders a "demo coming soon" placeholder in the same slot, so the build succeeds even before the video is uploaded.

For local work, copy `.env.example` to `.env` and adjust the URLs as needed.

## Deploy to Cloudflare Pages

No adapter needed — the build is pure static.

- **Framework preset:** Astro
- **Build command:** `npm run build`
- **Build output directory:** `dist`
- **Root directory:** `site`
- **Environment variables:** set `PUBLIC_DEMO_VIDEO_URL` once the demo MP4 is hosted, and `PUBLIC_BETA_SIGNUP_URL` if you ever want to point at a non-production endpoint.
