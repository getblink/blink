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

## Deploy to Cloudflare Pages

No adapter needed — the build is pure static.

- **Framework preset:** Astro
- **Build command:** `npm run build`
- **Build output directory:** `dist`
- **Root directory:** `site`
