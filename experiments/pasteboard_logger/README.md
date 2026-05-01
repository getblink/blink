# Pasteboard Logger Experiment

Small Swift command-line probe for building empirical intuition about what macOS apps put on `NSPasteboard.general`.

## Run

```bash
cd experiments/pasteboard_logger
swift run PasteboardLogger
```

The logger writes to stdout and to a timestamped file under `logs/`, for example:

```text
experiments/pasteboard_logger/logs/pasteboard-20260430-143012.log
```

Useful options:

```bash
swift run PasteboardLogger --dump-current
swift run PasteboardLogger --interval 0.1 --preview 500
swift run PasteboardLogger --log-file logs/google-slides.log
```

To keep a live browser preview of the current clipboard while you run the logger:

```bash
swift run PasteboardHTMLPreview --watch --out html-preview
open http://127.0.0.1:8765/index.html
```

The preview process starts a local server, appends an immutable snapshot folder every time `NSPasteboard.general.changeCount` changes, and updates the timeline sidebar in place. Past clipboard contents remain selectable without replacing older captures or flickering the selected viewer. It renders `public.html` when present, falls back to image or plain text rendering, and each snapshot has tabs for HTML source, plain text, dumped payload files, and pasteboard types.

For a one-shot dump to a temp folder, omit `--watch` and `--out`; the command prints the generated `index.html` path.

To replay an existing HTML preview corpus into deterministic model-request JSON:

```bash
swift run BatchClipboardHistoryReplay --input html-preview --out model-requests
```

The replay command is offline only. It reads `timeline.json` plus each `snapshots/<id>/items/item-N/` payload directory and writes one `schema_version: 0` request file per snapshot, for example `model-requests/<snapshot-id>.request.json`.
Before writing, it removes stale `*.request.json` files from the output directory so the directory reflects the current timeline. Non-concealed snapshots fail replay when expected item payload folders or raw item payloads are missing; concealed snapshots remain explicit omissions.
The command also owns `model-requests/derived-payloads/`: each run removes the stale derived payload tree before decoding current embedded media.

Each request keeps model-facing summaries byte-free:

- `snapshot` records the snapshot ID, observation time, change count, source URL, and rendered kind.
- `items` emits one handle per non-concealed pasteboard item as `item_1`, `item_2`, and so on, preserving item order.
- `allowed_handles` is the ordered list of emitted handles.
- `runtime_payloads` maps each handle to relative raw/decoded file paths, UTIs, byte sizes, and representation metadata.
- HTML items include decoded text preview when available, `has_embedded_image_data`, and `embedded_image_count` when the HTML references `data:image/...;base64,...`; preview text redacts `data:` URLs so embedded bytes stay out of model-facing summaries.
- Embedded HTML images are decoded into derived image handles immediately after their source item, for example `item_1_image_1`. Derived image items include `derived_from`, `derived_kind: "embedded_html_image"`, MIME type, byte size, dimensions when AppKit can decode them, and source UTI/path metadata.
- Derived image payload files live under `derived-payloads/<snapshot-id>/` in the replay output directory. Original pasteboard payload paths remain relative to the HTML preview input directory.
- Image items include dimensions when AppKit can decode the dumped raw image file.
- Invalid or unsupported embedded image payloads add warnings and do not stop replaying the rest of the snapshot.
- Concealed/password-like snapshots omit item handles and include `concealed_content_omitted`.

To run the live batch clipboard-history dry-run harness:

```bash
cd experiments/pasteboard_logger
swift run BatchClipboardHistoryHarness --work-dir batch-harness --history-limit 20
```

For real model calls, the harness chooses a Python executable at startup. By
default it prefers the repo dev venv at `scratchpad/.venv/bin/python`, then the
app bundled interpreter at `app/python-dist/bin/python3` when present, and only
falls back to `/usr/bin/python3` last. Override it explicitly when needed:

```bash
swift run BatchClipboardHistoryHarness \
  --work-dir batch-harness \
  --python ../../scratchpad/.venv/bin/python
```

Copy items as usual while the harness is running, then use terminal commands:

```text
goal <typed destination/task description>
list
run
clear
quit
```

`run` builds a combined request from the current non-concealed in-memory history,
calls `scripts/batch_model_select.py`, validates the returned
`{"selected_handles":[...]}` JSON, and resolves selected handles back to payload
files. It writes one timestamped folder under `batch-harness/runs/`:

- `batch-request.full.json` — local artifact with runtime payload references.
- `batch-request.model.json` — byte-free model prompt payload containing only the typed goal, item summaries, and `allowed_handles`.
- `model-output.raw.txt` and `model-output.json`.
- `resolved-selection.json` — ordered selected handles plus raw/decoded payload paths, UTIs, expected byte sizes, actual byte sizes, and resolution errors.

For a no-credential smoke test, pass a mock response:

```bash
swift run BatchClipboardHistoryHarness --work-dir batch-harness --mock-response '{"selected_handles":["item_1"]}'
```

The harness stops at the resolution manifest. It does not write selected items
back to `NSPasteboard`, paste into apps, or implement reset/pin semantics.

The tool polls `NSPasteboard.general.changeCount` and prints one terminal block per clipboard change. Each block includes:

- timestamp and `changeCount`
- the frontmost app at detection time: name, bundle ID, PID, and path
- number of pasteboard items
- full UTI/type list per item
- byte size per type
- decoded previews for common text, UTF-16 text, HTML, RTF, URL, file URL, and Chromium source URL types
- image dimensions for PNG, TIFF, and JPEG data when AppKit can decode them
- first 64 bytes as hex for unknown/proprietary types

If an item advertises `org.nspasteboard.concealedtype` or a type name that looks password/secret-related, the logger only reports that concealed content appeared and skips all content/type payload logging for that item.

App attribution is best-effort: `NSPasteboard.general` does not expose the writer app, so the logger records `NSWorkspace.shared.frontmostApplication` when it observes the `changeCount` change.

## Suggested Manual Pass

Start the logger, then copy from:

- Google Slides: one element, then multiple elements
- a webpage
- a PDF
- a screenshot
- Finder file selection
- Photoshop or Figma
- a password manager

Keep the saved log file as raw evidence for deciding which pasteboard types are useful to Blink source capture.
