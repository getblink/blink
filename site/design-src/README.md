# design source assets (not deployed)

Originals that don't ship. `public/` is copied verbatim into the build, so keep
large source files out of it.

- `pointilism-3_upscaled.webp` — 7200×5752 upscale of the hero painting.
  The deployed `public/pointilism-3-hd.webp` (2800px, q82) is derived from it:

      npx sharp -i design-src/pointilism-3_upscaled.webp -o public/pointilism-3-hd.webp resize 2800 -- webp --quality 82

  (the animation samples the small `public/pointilism-3.webp`; the HD is only
  the static `.hero::before` / `.join__card::before` the reveal lands on.)
