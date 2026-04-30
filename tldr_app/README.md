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
- Swift shows a non-activating overlay with a TL;DR and three suggestions.
- `1`, `2`, or `3` chooses a suggestion while the original app keeps focus.
- Auto-paste is on by default; the menubar toggle switches to copy-only mode.

Runtime state:

- Config, credentials, and prompt overrides: `~/.tldr/`
- Run artifacts: `~/Library/Application Support/TLDR/runs/`
- Pending crash-recovery records: `~/Library/Application Support/TLDR/pending/`
- Local install: `~/Applications/TLDR.app`

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

For Gemini or proxy-backed runs, put runtime env in `~/.tldr/.env`:

```bash
GEMINI_API_KEY=...
# Optional proxy-backed server mode:
BLINK_PROXY_URL=http://127.0.0.1:8000
BLINK_PROXY_TOKEN=...
```

Optional overrides:

- `~/.tldr/settings.json`
- `~/.tldr/prompts/prompt.txt`
- `~/.tldr/runtime-config.json`
