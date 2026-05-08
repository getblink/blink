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

The production build fails fast unless both public env vars are set:

- `PUBLIC_BETA_SIGNUP_URL` — JSON endpoint for the beta form, currently `https://blink-production-7b5a.up.railway.app/v1/beta-signup`
- `PUBLIC_DEMO_VIDEO_URL` — hosted MP4 demo video URL, usually an R2 object

For local work, copy `.env.example` to `.env` and adjust the URLs as needed.

## Deploy to Cloudflare Pages

No adapter needed — the build is pure static.

- **Framework preset:** Astro
- **Build command:** `npm run build`
- **Build output directory:** `dist`
- **Root directory:** `site`
- **Environment variables:** set `PUBLIC_BETA_SIGNUP_URL` and
  `PUBLIC_DEMO_VIDEO_URL` in the Cloudflare Pages dashboard.
