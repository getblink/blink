# Blink

Blink is a local-first Mac assistant that reads the app in front of you and turns it into a useful next action.

The current beta focuses on one workflow: summarize the active window, suggest three replies, and let you copy or insert the right response without switching context.

<p>
  <a href="https://useblink.dev">Website</a> ·
  <a href="https://useblink.dev">Download &amp; demo</a>
</p>

## Status

Blink is early beta software for macOS 14+. Expect rough edges, especially around macOS permissions, model latency, and app-specific text fields.

The app is source-available under the Elastic License 2.0. It is not OSI open source. See [LICENSE](LICENSE).

## What It Does

- Captures the frontmost window with ScreenCaptureKit.
- Sends the request through the Blink backend or, in local development, directly to Gemini.
- Shows a small non-activating overlay with a one-line summary and three reply suggestions.
- Lets number keys expand first, repeat to copy, Return to insert, and Esc to dismiss.

The v1 client/server protocol intentionally keeps the `/v1/tldr` route and `tldr_*` storage/token names for deployed-client compatibility.

## Install

Grab the latest beta DMG from [useblink.dev](https://useblink.dev). Open the DMG, drag Blink into Applications, launch it, and grant the macOS permissions it requests. If you installed an older TLDR build, reinstall Blink — the bundle ID changed and Sparkle won't carry you over.

## Self-Host The Server

The backend is a small FastAPI app that can run on Railway or any Python host with Postgres. See [server/README.md](server/README.md) for environment variables, database schema, and endpoint contracts.

## Build From Source

The macOS app lives in [app/](app/README.md). Useful commands:

```bash
python3 -m unittest discover app/python/tests
python3 -m compileall app/python
bash app/scripts/install_local_app.sh
```

For release builds, use `app/scripts/release.sh`; it signs and notarizes the app, builds a DMG, signs the Sparkle update, and uploads the DMG/appcast to Cloudflare R2. See [app/README.md](app/README.md#sparkle-releases).

## Repository Map

- `app/` contains the shipped Blink.app Swift surface and bundled Python runner.
- `server/` contains the FastAPI backend and Railway deployment notes.
- `site/` contains the Astro landing page for `useblink.dev`.
- `scratchpad/` contains experimental capture, fixture, and sweep tooling.
- `experiments/blink-copy-paste/` contains the archived intelligent copy-paste tester app.
- `docs/` contains product, dogfood, experiment, and internal contributor notes.

Internal workspace guidance that used to live in this README has moved to [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md).

## Contributing

Blink accepts focused issues and pull requests. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

For security reports, email henry@useblink.dev instead of opening a public issue. See [SECURITY.md](SECURITY.md).
