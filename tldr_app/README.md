# TLDR.app

`tldr_app/` is the shipped macOS surface for the TL;DR + reply suggestions
experiment. It is intentionally separate from the existing Blink app in
`app/`.

TLDR is a menubar app:

- `Ctrl+Shift+T` captures the frontmost window with ScreenCaptureKit.
- Swift builds a request envelope with image diagnostics, focused-context facts,
  pending-run metadata, and behavior events.
- The bundled Python runtime calls the TLDR server when `BLINK_PROXY_URL` +
  `BLINK_PROXY_TOKEN` are configured, and otherwise falls back to direct Gemini.
  `TLDR_DISABLE_PROXY=1` forces direct-Gemini regardless (used when iterating
  on the bundled prompt locally without redeploying the server).
- Swift shows a non-activating overlay with a TL;DR and three suggestions.
- `1`, `2`, or `3` expands a suggestion while the original app keeps focus.
- Pressing the same number again copies that suggestion and closes the overlay.
- `Return` inserts the expanded suggestion through the clipboard + Cmd+V path.
- Pressing `4` focuses the custom reply field; custom replies become the
  highest-quality local voice samples for future suggestions.
- `Return` with no expanded suggestion falls through to the focused app.
- `Esc` dismisses the overlay.

Runtime state:

- Config, credentials, and prompt overrides: `~/.tldr/`
- Run artifacts: `~/Library/Application Support/TLDR/runs/`
- Pending crash-recovery records: `~/Library/Application Support/TLDR/pending/`
- Local install: `~/Applications/TLDR.app`

Stateful POC:

- Before each request, `tldr_once.py` scans recent local run artifacts.
- It includes up to five user-typed custom replies as voice samples.
- It includes up to three recent same-surface outcomes when the app bundle and
  focused title match within a 15-minute window.
- The proxy receives this as `stateful_context`; the server may use it for model
  context, but storage redacts text fields unless content retention is enabled.

## Build

```bash
bash tldr_app/scripts/fetch_python.sh
TLDR_SKIP_TCC_RESET=1 bash tldr_app/scripts/build.sh
bash tldr_app/scripts/install_local_app.sh
bash tldr_app/scripts/make_dmg.sh
```

The DMG lands at `tldr_app/build/TLDR-0.1.0.dmg`.

Use `install_local_app.sh` for dogfood rebuilds. It resets TCC by default after
installing `~/Applications/TLDR.app`; pass `--skip-tcc-reset` only when you are
doing a non-dogfood script check and do not want to re-grant permissions.

`scripts/build.sh` stamps the built bundle's `CFBundleVersion` from
`git rev-list --count HEAD`; set `TLDR_BUILD_NUMBER=` when cutting a release
from a dirty or otherwise non-linear tree.

`scripts/fetch_python.sh` pins the python-build-standalone tarball by SHA256.
When bumping `PYTHON_VERSION`, `PBS_RELEASE`, `ARCH`, or `BUILD`, update the
case table in that script with the matching upstream `.sha256` release asset.

For Gemini or proxy-backed runs, put runtime env in `~/.tldr/.env`:

```bash
GEMINI_API_KEY=...
# Optional proxy-backed server mode:
BLINK_PROXY_URL=http://127.0.0.1:8000
BLINK_PROXY_TOKEN=...
# Force direct-Gemini routing even when the two proxy vars (or a bundled
# Resources/proxy.env) are populated. Use while iterating on the bundled
# prompt locally without redeploying the server.
TLDR_DISABLE_PROXY=1
```

## Signed Dogfood DMG

One-time local notarization setup:

```bash
xcrun notarytool store-credentials TLDR-NOTARY
```

Create `tldr_app/scripts/config.env` locally; it is gitignored:

```bash
TLDR_TEAM_ID=YOUR_TEAM_ID
TLDR_PROXY_URL=https://your-railway-service.up.railway.app
TLDR_PROXY_TOKEN=revocable-dogfood-token
```

`make_dmg.sh` builds the app if needed, verifies the bundled runtime, signs and
notarizes `TLDR.app`, packages the DMG, then signs, notarizes, staples, and
assesses the DMG. The build writes the proxy values into
`Contents/Resources/proxy.env` with mode `600`, so users do not need to create
`~/.tldr/.env`. Treat the token as compromised after shipping; cap it with the
server-side per-token rate limit (`TLDR_TOKEN_RATE_LIMIT_PER_MINUTE`, backed by
`REDIS_URL` when available) and revoke it in `BLINK_API_TOKENS` when needed.

Optional overrides:

- `~/.tldr/settings.json`
- `~/.tldr/prompts/prompt.txt`
- `~/.tldr/runtime-config.json`

## Sparkle Releases

TLDR uses Sparkle 2 for prompted updates. Generate the EdDSA key once with
Sparkle's `generate_keys` tool, store the private key in Keychain, and put the
public key plus R2 appcast URL in `tldr_app/scripts/config.env`:

```bash
TLDR_SPARKLE_FEED_URL=https://downloads.example.com/tldr/appcast.xml
TLDR_SPARKLE_PUBLIC_ED_KEY=...
TLDR_SPARKLE_SIGN_UPDATE=/path/to/sign_update
TLDR_SPARKLE_KEYCHAIN_ACCOUNT="TLDR Sparkle EdDSA"
TLDR_R2_BUCKET=tldr-downloads
TLDR_R2_PUBLIC_DOMAIN=downloads.example.com
```

`bash tldr_app/scripts/release.sh` fetches the pinned Python runtime, builds,
signs, notarizes, packages the DMG, signs the update for Sparkle, writes
`tldr_app/build/appcast.xml`, and uploads the DMG/appcast to R2. Set
`TLDR_RELEASE_UPLOAD=0` for a local dry run.
