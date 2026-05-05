# TL;DR + Reply Suggestions

This is a small sibling experiment to `./capture`. It does not touch the live
copy-paste runner or `Blink.app`.

Run it from the repo root:

```bash
./tldr
```

The runner loads `.env` / `.env.local`, listens for `ctrl+shift+t`, asks macOS
to select a window screenshot, sends that single image to Gemini, and shows a
centered overlay with a one-line TL;DR plus three reply suggestions.

If both `BLINK_PROXY_URL` and `BLINK_PROXY_TOKEN` are set, the runner sends the
PNG to `POST <BLINK_PROXY_URL>/tldr` instead and uses the server-owned prompt /
model selection. Without those vars, it keeps the direct Gemini path.

Model settings are intentionally local to this experiment. The defaults live in
`gemini.py`; optional overrides can go in `scratchpad/tldr_reply/settings.json`
without affecting `./capture`.

The overlay is non-activating: it should not steal focus from the app you were
using. While it is visible, the runner temporarily treats plain `1`, `2`, `3`,
and `esc` as global choices so you do not need to click the popup first.

In the overlay:

- `1`, `2`, or `3` copies that suggestion to the clipboard and closes the panel.
- `esc` dismisses the panel without writing the clipboard.

Artifacts are written under `scratchpad/tldr_runs/<timestamp>/`:

- `screenshot.png`
- `response.json`
- `meta.json`

`meta.json` records the proxy URL when proxy mode is active.

## Fixture capture and sweeps

To capture a screenshot fixture without sending it to Gemini:

```bash
./tldr --save-fixture scratchpad/tldr_reply/fixtures/<slug>
```

Press `ctrl+shift+t`, pick the window, and the runner writes:

- `screenshot.png`
- `tldr_fixture.json`

To compare compression/OCR configs across fixtures:

```bash
python scratchpad/tldr_reply/eval_sweep.py \
  --fixtures 'scratchpad/tldr_reply/fixtures/*' \
  --configs 'scratchpad/eval_configs/tldr_*.json' \
  --out scratchpad/sweeps/tldr_{auto-timestamp}
```

The sweep writes `summary.md`, `compare.html`, and per-cell `run.json` /
`output.txt` artifacts. The OCR-backed configs run Vision OCR on the original
screenshot while the request image is compressed for Gemini. Generated request
JPEGs are written into each per-cell sweep directory, not beside the shared
fixture PNG.

Latency accounting is intentionally conservative: `summary.md` reports local
parallel prep, OCR, Gemini SDK network/model time, and total time separately.
The SDK does not expose upload time apart from the network/model call, so these
sweeps cannot prove OCR is hidden behind upload.

Known v0 limitations:

- Window capture uses `screencapture -W`, so each invocation requires clicking
  the target window.
- Sweep grading is manual; use `compare.html` to judge TLDR accuracy and reply
  plausibility before promoting any config into `tldr_app/`.
- Tone is inferred only from messages visible in the screenshot.
- The Python interpreter running this script needs Input Monitoring and Screen
  Recording permission for hotkeys and screenshots.

Follow-up ideas:

- Add an explicit auto-paste toggle. The current behavior only copies the chosen
  suggestion, which is safer, but dogfood showed it is easy to forget the final
  paste step when the original field keeps focus.
