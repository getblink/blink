# Scratchpad

This folder is for fast, disposable experiment work.

The primary workflow is now a resident hotkey runner for profiling the real screenshot-to-completion pipeline.

## Hotkey runner

1. Create a local virtualenv and install dependencies:

```bash
python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install -r scratchpad/requirements.txt
```

Use a real `python3.11` binary here, not macOS's default `/usr/bin/python3`, which is typically still 3.9.

2. Export your Gemini API key:

```bash
export GEMINI_API_KEY=your_key_here
```

3. Grant macOS permissions to the interpreter you will run:

- Input Monitoring for the global hotkeys
- Accessibility for focused-element metadata
- Screen Recording for screenshots

4. Optionally edit:

- `scratchpad/prompt.txt`
- `scratchpad/settings.json`

5. Run:

```bash
python3 scratchpad/run_gemini_trial.py
```

If you are already inside `scratchpad/`, run:

```bash
python3 run_gemini_trial.py
```

If `scratchpad/.venv/` exists, the script will automatically re-exec itself inside that environment.

The runner stays resident and listens for these defaults:

- `ctrl+shift+c` - capture and store the reusable source screenshot
- `ctrl+shift+v` - capture target metadata, capture target screenshot, stream Gemini output
- `ctrl+option+r` - reset the stored source
- `ctrl+option+q` - quit the runner

The default capture mode is `window`, which now starts in macOS window selection mode but automatically retries with a region capture if the selected window cannot be snapshotted.

By default, the runner also preprocesses screenshots before upload by converting them into smaller request images. The original captures are preserved on disk, but the Gemini request now uses compressed copies to reduce upload latency.

The script prints:

- streamed model output
- end-to-end latency summary
- TTFT, model latency, and output TPS when usage metadata is present

It also writes:

- `scratchpad/last_output.txt`
- `scratchpad/last_run.json`
- `scratchpad/runs/<timestamp>/run.json`
- `scratchpad/runs/<timestamp>/output.txt`
- `scratchpad/runs/<timestamp>/source.png`
- `scratchpad/runs/<timestamp>/target.png`

## What `run_gemini_trial.py` profiles

- queue delay between hotkey and work starting
- target metadata capture time
- target screenshot time
- source and target request-image preparation time
- request build time
- time to first streamed chunk
- stream duration
- total model latency
- end-to-end latency from hotkey press to clipboard-ready
- source/target image byte sizes
- original vs request image byte sizes
- Gemini usage metadata when returned by the API
- output TPS when candidate token usage is present

This is intended to separate local workflow overhead from model latency as much as possible without building a full benchmark harness.

## Capture behavior

- `capture_mode: "window"` starts interactive capture in window mode.
- If macOS returns `could not create image from window`, the runner immediately retries with a freeform region selection.
- `capture_mode: "region"` forces drag-to-select region capture from the start.

This keeps the default flow aligned with the copy/paste mental model while avoiding hard failures on apps or windows that do not cooperate with native window snapshots.

## Request image preprocessing

- `preprocess_request_images: true` enables request-side image compression by default.
- `request_image_format: "jpeg"` converts uploaded request images to JPEG.
- `request_image_max_dimension: 1600` constrains the longest edge before upload.
- `request_image_jpeg_quality: 80` controls JPEG quality for request images.

Each run log records both the original screenshot bytes and the smaller request-image bytes under `request.images.source` and `request.images.target`.

## Optional packet generator

`make_trial.py` still packages:

- one or more source images
- one or more target images
- optional structured target-context metadata
- optional annotation hints

into a single run folder under `scratchpad/runs/`.

Each run folder contains:

- `prompt.txt` - reusable prompt text for manual model experiments
- `trial.json` - structured record of the trial inputs
- `trial.md` - human-readable packet
- `preview.html` - local side-by-side viewer for sources, targets, and prompt
- copied source/target image assets

## Why this exists

- Faster iteration on manual experiments
- Reusable prompt packets for repeated trials
- A place to capture optional target metadata without locking in a product design

## Packet generator usage

```bash
python3 scratchpad/make_trial.py fb-description \
  --source /absolute/path/to/source-1.png \
  --source /absolute/path/to/source-2.png \
  --target /absolute/path/to/target-1.png \
  --intent copy_exact \
  --target-context-file /absolute/path/to/target-context.json \
  --notes "Facebook relist description field"
```

This writes a run bundle to `scratchpad/runs/<timestamp>-fb-description/`.

## Optional target-context JSON

Use this when the visual target is ambiguous, when the field is partially filled, or when you want a compact bridge between UI state and prompt context.

Example:

```json
{
  "focused_role": "textField",
  "focused_label": "Description",
  "focused_value": "",
  "existing_field_text": "",
  "caret_context": "replace all",
  "nearby_labels": ["Condition", "More details"],
  "section_title": "Item for sale",
  "output_constraints": "Keep original detail; no markdown"
}
```

## Optional annotation hints JSON

This is a lightweight place to store intended visual annotations before deciding how they should be rendered.

Example:

```json
{
  "note": "Potential future box around target field",
  "target_box": [24, 610, 450, 170]
}
```

These hints are recorded in the bundle but are not rendered onto images yet.
