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

Known v0 limitations:

- Window capture uses `screencapture -W`, so each invocation requires clicking
  the target window.
- There is no replay/sweep support and no schema-v1 fixture compatibility.
- Tone is inferred only from messages visible in the screenshot.
- The Python interpreter running this script needs Input Monitoring and Screen
  Recording permission for hotkeys and screenshots.

Follow-up ideas:

- Add an explicit auto-paste toggle. The current behavior only copies the chosen
  suggestion, which is safer, but dogfood showed it is easy to forget the final
  paste step when the original field keeps focus.
