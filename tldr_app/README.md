# TLDR.app

`tldr_app/` is the shipped macOS surface for the TL;DR + reply suggestions
experiment. It is intentionally separate from the existing Blink app in
`app/`.

TLDR is a menubar app:

- `Ctrl+Opt+Space` (default) captures the frontmost window with ScreenCaptureKit. The hotkey is configurable via `~/.tldr/settings.json`.
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

TLDR uses Sparkle 2 for prompted updates. The release flow lives in
`tldr_app/scripts/release.sh`: it fetches the pinned Python runtime, builds,
signs, notarizes, packages the DMG, signs the update for Sparkle, writes
`tldr_app/build/appcast.xml`, and uploads the DMG + appcast to R2. Set
`TLDR_RELEASE_UPLOAD=0` for a local dry run.

### Cutting a release

1. **Bump the marketing version in `tldr_app/project.yml`** (not `Info.plist`).
   `xcodegen` regenerates `Info.plist` from `project.yml` on every build, so
   editing `Info.plist` directly is wiped. The build number is auto-stamped
   from `git rev-list --count HEAD` and does not need a manual bump.

2. **Make sure release env vars are exported.** The scripts source
   `tldr_app/scripts/config.env` automatically if it exists; alternatively,
   export the repo-root `.env` before invoking `release.sh`:

   ```bash
   set -a && source .env && set +a
   bash tldr_app/scripts/release.sh
   ```

3. **First run in a fresh workspace also needs `TLDR_SPARKLE_SIGN_UPDATE`.**
   `release.sh` validates Sparkle's `sign_update` binary up front, but Sparkle
   is fetched as a Swift Package during the build that has not happened yet.
   Either point at a sibling workspace's copy, e.g.:

   ```bash
   export TLDR_SPARKLE_SIGN_UPDATE=$(ls /Users/$USER/conductor/workspaces/blink/*/tldr_app/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1)
   ```

   or pre-resolve dependencies once (`xcodebuild -resolvePackageDependencies
   -project tldr_app/TLDR.xcodeproj`). Subsequent releases in the same
   workspace pick up the local copy automatically.

### Required environment

```bash
# Apple Developer / notarization
TLDR_TEAM_ID=8W5FCW3BXK              # team ID for codesigning fallback
TLDR_SIGN_IDENTITY=<sha-1>            # required if the keychain has multiple
                                      # "Developer ID Application: ..." certs
                                      # with the same team ID; codesign refuses
                                      # ambiguous lookups by team ID alone.
                                      # Find with: security find-identity -v -p codesigning
TLDR_NOTARY_PROFILE=TLDR-NOTARY      # default; set up once with
                                      #   xcrun notarytool store-credentials TLDR-NOTARY

# Sparkle
TLDR_SPARKLE_FEED_URL=https://<r2-public-domain>/appcast.xml
TLDR_SPARKLE_PUBLIC_ED_KEY=<base64 from Sparkle generate_keys>
# Optional: TLDR_SPARKLE_KEYCHAIN_ACCOUNT (defaults to Sparkle's lookup)
# Optional: TLDR_SPARKLE_SIGN_UPDATE (see "First run" note above)

# Cloudflare R2
TLDR_R2_BUCKET=tldr-releases
TLDR_R2_PUBLIC_DOMAIN=<pub-*.r2.dev or your custom domain>
TLDR_R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
TLDR_R2_ACCESS_KEY_ID=<S3-compatible token id>
TLDR_R2_SECRET_ACCESS_KEY=<S3-compatible token secret>

# Bundled into Contents/Resources/proxy.env at build time
TLDR_PROXY_URL=https://<railway-service>.up.railway.app/
TLDR_PROXY_TOKEN=<bootstrap token>
```

### What gets stamped at build time

`build.sh` overwrites the placeholder values in `project.yml` after `xcodegen`
runs:

- `CFBundleVersion` ← `git rev-list --count HEAD` (or `TLDR_BUILD_NUMBER`)
- `SUFeedURL` ← `TLDR_SPARKLE_FEED_URL` (placeholder stays if the var is empty)
- `SUPublicEDKey` ← `TLDR_SPARKLE_PUBLIC_ED_KEY` (placeholder stays if empty)

Both placeholders failing to be overwritten is silent — the build still
succeeds, and existing users can install the DMG, but **that build will not be
able to discover or verify any future Sparkle update**. Always confirm the
build log shows both `[tldr] stamping SUFeedURL=...` and `[tldr] stamping
SUPublicEDKey from TLDR_SPARKLE_PUBLIC_ED_KEY` lines before uploading.
