# Scratchpad

See also:

- `README.md` for the repo entrypoint and quickstart
- `CLAUDE.md` for the current repo layout and implementation guidance
- `docs/PROJECT_BRIEF.md` for scope and success criteria
- `docs/EXPERIMENT_LOG.md` for recording experiment outcomes
- `docs/ARTIFACT_SCHEMA.md` for the versioned fixture/run bundle contract
- `docs/DEMO_FIXTURE_PLAN.md` for the demo-portfolio capture checklist
- `scratchpad/eval_configs/README.md` for sweep config file conventions
- `scratchpad/providers/README.md` for the sweep-only provider adapters

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

Or put it once in the workspace root `.env` file:

```bash
cp .env.example .env
```

Then edit `.env` and set `GEMINI_API_KEY=...`. Both `./capture` and `./sweep` will load it automatically.

3. Grant macOS permissions to the interpreter you will run:

- Input Monitoring for the global hotkeys
- Accessibility for focused-element metadata
- Screen Recording for screenshots

4. Optionally edit:

- `scratchpad/prompt.txt`
- `scratchpad/settings.json`

Keep `fixtures_dir` set to the default `"fixtures"` if you want to participate in the shared Conductor fixture pool.

5. Run:

```bash
./capture
```

If you are already inside `scratchpad/`, run:

```bash
python3 run_gemini_trial.py
```

If `scratchpad/.venv/` exists, the script will automatically re-exec itself inside that environment.

The runner stays resident and listens for these defaults:

- `ctrl+shift+c` - capture and store a new reusable source screenshot
- `ctrl+shift+v` - capture a target fixture, then optionally stream Gemini output

There is no separate reset hotkey now. Capturing a new source with `ctrl+shift+c` replaces the previous one and starts the next fixture batch from that source. Quit with `ctrl+c` in the terminal.

The default capture mode is `window`, which now starts in macOS window selection mode but automatically retries with a region capture if the selected window cannot be snapshotted.

By default, the runner also preprocesses screenshots before upload by converting them into smaller request images. The original captures are preserved on disk, but the Gemini request now uses compressed copies to reduce upload latency. With `fixture_mode: true`, those original screenshots and the request-image siblings are saved together as reusable fixture bundles under `scratchpad/fixtures/`.

Inside Conductor, `scratchpad/fixtures` is normally a symlink to the shared pool at `~/conductor/shared/blink/fixtures/`, so any fixture you capture in one workspace is immediately available in the others. If a workspace already has a populated local `scratchpad/fixtures/` directory from before shared-pool setup, run `bash .conductor/migrate_fixtures.sh` once to move it into the pool and replace it with the symlink.

If you want to confirm Conductor actually ran the repo setup hook in this workspace, check `.context/conductor/setup-receipt.json`.

The script prints:

- timestamped status lines for screenshot, AX, OCR, fixture save, and Gemini phases
- streamed model output
- end-to-end latency summary
- TTFT, model latency, and output TPS when usage metadata is present

It also writes:

- `scratchpad/last_output.txt`
- `scratchpad/last_run.json`
- `scratchpad/runs/<timestamp>/run.json`
- `scratchpad/runs/<timestamp>/output.txt`
- `scratchpad/fixtures/<timestamp>-<slug>/fixture.json`
- `scratchpad/fixtures/<timestamp>-<slug>/source.png`
- `scratchpad/fixtures/<timestamp>-<slug>/target.png`
- `scratchpad/fixtures/<timestamp>-<slug>/source.request.jpg`
- `scratchpad/fixtures/<timestamp>-<slug>/target.request.jpg`
- `scratchpad/fixtures/<timestamp>-<slug>/ax_focused.json`
- `scratchpad/fixtures/<timestamp>-<slug>/ax_nearby.json`
- `scratchpad/fixtures/<timestamp>-<slug>/caret.json`
- `scratchpad/fixtures/<timestamp>-<slug>/geometry.json`
- `scratchpad/fixtures/<timestamp>-<slug>/clipboard.json`
- `scratchpad/fixtures/<timestamp>-<slug>/ocr.json`
- `scratchpad/fixtures/<timestamp>-<slug>/capture.json`

Target metadata now records both:

- the resolved focused-element owner app used for fixture naming, geometry, and downstream target context
- the workspace-frontmost app observed at hotkey time

If those differ, the runner logs a metadata warning instead of silently folding them together.

## Offline sweeps

Run a serial fixture x config sweep with:

```bash
./sweep --fixtures 'scratchpad/fixtures/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/{auto-timestamp}
```

Each sweep writes:

- `scratchpad/sweeps/<timestamp>/sweep.json`
- `scratchpad/sweeps/<timestamp>/summary.md`
- `scratchpad/sweeps/<timestamp>/compare.html`
- `scratchpad/sweeps/<timestamp>/<fixture_id>/<config_name>/run.json`
- `scratchpad/sweeps/<timestamp>/<fixture_id>/<config_name>/output.txt`

Starter config variants live in `scratchpad/eval_configs/`.

The sweep runner is intentionally serial and file-based. It should complete even when individual cells fail, with per-cell `run.json` artifacts preserved for inspection.

The rendered sweep outputs surface the three model timings that matter most for interaction feel:

- `model_latency_ms`
- `ttft_ms`
- `stream_duration_ms`

For source-packet latency experiments, use:

```bash
scratchpad/.venv/bin/python scratchpad/benchmark_source_packet.py \
  --fixtures 'scratchpad/fixtures/*' \
  --config scratchpad/eval_configs/flash-lite-low-minimal.json \
  --out scratchpad/sweeps/source-packet-{auto-timestamp}
```

That benchmark compares the current two-image request against a cached
source-packet flow, writes per-fixture artifacts plus `benchmark.json`
and `summary.md`, and reports amortized latency estimates for reuse
counts such as 1, 3, and 5 target pastes per source capture.

For prompt-variant runs, pass explicit prompt paths and, if the packet
schema becomes more verbose, raise the packet response ceiling so the
JSON does not truncate mid-object:

```bash
scratchpad/.venv/bin/python scratchpad/benchmark_source_packet.py \
  --fixtures 'scratchpad/fixtures/*' \
  --config scratchpad/eval_configs/flash-lite-low-minimal.json \
  --extract-prompt-path scratchpad/source_packet_extract_prompt_v2.txt \
  --target-prompt-path scratchpad/source_packet_target_prompt_v2.txt \
  --max-output-tokens 2048 \
  --out scratchpad/sweeps/source-packet-v2-{auto-timestamp}
```

For an OCR-biased plain-text packet that preserves exact visible spans
instead of emitting JSON fields, switch the packet format to `text` and
use the v3 OCR prompts:

```bash
scratchpad/.venv/bin/python scratchpad/benchmark_source_packet.py \
  --fixtures 'scratchpad/fixtures/*' \
  --config scratchpad/eval_configs/flash-lite-low-minimal.json \
  --extract-prompt-path scratchpad/source_packet_extract_prompt_v3_ocr.txt \
  --target-prompt-path scratchpad/source_packet_target_prompt_v3_ocr.txt \
  --packet-format text \
  --max-output-tokens 2048 \
  --out scratchpad/sweeps/source-packet-v3-ocr-{auto-timestamp}
```

That variant writes `source_packet.txt` instead of `source_packet.json`
and treats a literal `COMPLETENESS: needs_source_image` line as the
packet's self-reported insufficiency signal.

Human-authored gold packets for the current fixture corpus live in
`scratchpad/gold_source_packets.json`. To compare a benchmark run's
generated packets against that gold corpus, use:

```bash
scratchpad/.venv/bin/python scratchpad/compare_source_packets.py \
  --pred-dir scratchpad/sweeps/source-packet-20260423-204225
```

That writes `gold_packet_compare.json` and `gold_packet_compare.md`
inside the benchmark directory so prompt revisions can be judged against
the same hand-authored packet target. The comparison tool accepts either
JSON packets (`source_packet.json`) or OCR-style text packets
(`source_packet.txt`).

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

- `target_metadata.frontmost_app` now prefers the owning app of the resolved focused AX element when available.
- `target_metadata.workspace_frontmost_app` preserves the `NSWorkspace` frontmost app seen at hotkey time for debugging.
- `geometry.json` uses AX top-left display coordinates for both window and screen frames.

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

## Field runs from the tester app

Bundles exported from `Blink.app` (the tester-deployment channel in `app/`) land here via:

```bash
python scratchpad/import_field_runs.py ~/Desktop/Blink-runs-<ts>.zip
```

Imported bundles live under `scratchpad/field_runs/<fixture_id>/` and replay through the same sweep path as research fixtures:

```bash
./sweep --fixtures 'scratchpad/field_runs/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/<name>
```

See `docs/ARTIFACT_SCHEMA.md` for the shared v1 bundle contract.

## Tests

Unit tests for scratchpad helpers (currently the clipboard `normalize_for_paste()` boundary post-processing) live under `scratchpad/tests/`. Run them with:

```bash
scratchpad/.venv/bin/python -m unittest discover scratchpad/tests
```

## Archived experiment artifacts

When a Conductor workspace is archived, `.conductor/archive.sh` always copies `scratchpad/sweeps/` and `scratchpad/runs/` to `~/conductor/archive/blink/<workspace>-<timestamp>/`. If the workspace is using the shared fixture-pool symlink, the archive step dereferences it and copies the fixture contents alongside any referenced sweeps so archived `compare.html` and `summary.md` links still work. If the workspace intentionally forked `scratchpad/fixtures/` into a real directory, that local copy is preserved as-is.

Every archive run also appends a receipt to `~/conductor/archive/blink/_archive_runs.jsonl`, and any preserved archive bundle contains `archive-receipt.json` at its root.

If you need to fork the shared corpus for a schema-incompatible experiment, replace the symlink with a real directory copy:

```bash
rm scratchpad/fixtures
cp -R ~/conductor/shared/blink/fixtures/ scratchpad/fixtures/
```

After that, captures and sweeps in that workspace use the forked local directory until you switch it back or migrate manually.

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
