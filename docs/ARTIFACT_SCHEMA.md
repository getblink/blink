# Blink Artifact Schema v1

See also:

- `README.md` for the repo entrypoint and quickstart
- `CLAUDE.md` for the implementation-oriented repo guide
- `scratchpad/README.md` for how the research loop emits v1 bundles
- `app/README.md` for how the tester-deployment loop emits v1 bundles
- `docs/DOGFOOD_PLAYBOOK.md` for the clean-build procedure that exercises the tester-loop emitter end-to-end

The versioned contract that bridges Blink's two independent loops:

- **Research loop** — `./capture` (scratchpad runtime) writes fixtures under `scratchpad/fixtures/<ts-slug>/` and runs under `scratchpad/runs/<ts>/`.
- **Tester-deployment loop** — `Blink.app` writes bundles under `~/Library/Application Support/Blink/runs/<ts>/`, which are exported, imported into `scratchpad/field_runs/`, and replayed by `./sweep`.

Both loops emit bundles that conform to this schema. `./sweep` must consume either without code changes.

## Schema version

- Current: `schema_version: 1`
- Source constant: `FIXTURE_SCHEMA_VERSION = 1` in `scratchpad/run_gemini_trial.py` and mirrored in `app/python/run_once.py`.
- Any change to required fields, field types, or file layout below bumps the version.

## Bundle layout

Every bundle is a flat directory keyed by timestamp. For a bundle at `<bundle_dir>/`:

| File | Required | Purpose |
| --- | --- | --- |
| `fixture.json` | yes | Sweep-replayable manifest. Primary contract. |
| `source.png` | yes | Source screenshot (PNG). Referenced by `fixture.json.source.image_path`. |
| `target.png` | yes | Target screenshot (PNG). Referenced by `fixture.json.target.image_path`. |
| `output.txt` | yes | Raw generated text from the live trial, trailing newline when non-empty. Empty file when no live call ran. Paste-normalized text is recorded separately in `run.json.paste.text` when available. |
| `run.json` | yes* | Live-trial request/response log. *Required for tester-loop bundles; optional for sweep-replay outputs because sweep writes its own run.json per cell.* |
| `host_profile.json` | no | Swift-side wall-clock profiling for `Blink.app` runs: capture, artifact prep, Python wall time, and paste timing. Tester loop only. |
| `settings.json` | no | Snapshot of the capture settings used at trial time. Mirrors `fixture.json.capture_settings`. Tester loop writes this; research loop may skip. |
| `target_metadata.json` | no | Raw, unshortened target metadata captured at trial time. Mirrors `fixture.json.target_metadata`. Present when the emitter captures a full AX tree. |
| `prepared_source.json` | no | Cached source-packet record captured at source time. Present for request modes that precompute source context. |
| `source_text.json` | no | Exact local source-text capture from AX selected text or a pasteboard-preserving Cmd+C. Present when the fast local source mode attempts text capture before OCR fallback. |
| `runtime_selection.json` | no | Runtime provider/model/request-mode snapshot for the trial. Tester loop only. |
| `target_ocr_packet.txt` | no | Paste-facing resolved target facts used by source-packet modes before any full-target-image fallback. This should stay small, usually just `FOCUSED_FIELD_LABEL` or empty. |
| `target_ocr_packet.build.json` | no | Target OCR packet diagnostics and Blink-side sufficiency evidence, including OCR block boxes, selected row text, fallback reasons, and focus/caret rectangles when available. |
| `source.request.jpg` | no | Preprocessed request image for source. Referenced by `fixture.json.source.request_image_path`. Research loop writes this; tester loop may skip. |
| `target.request.jpg` | no | Preprocessed request image for target. Same as above. |
| `ax_focused.json`, `ax_nearby.json`, `caret.json`, `geometry.json`, `clipboard.json`, `ocr.json`, `capture.json` | no | Research-loop diagnostic files. Tester loop may emit `caret.json` when AX selected-range capture succeeds. Sweep does not read these. |

Unknown files are ignored by sweep. Emitters should never overwrite or rename the required files.

### Bundle identifier naming

- **Research loop:** `YYYYMMDD-HHMMSS-mmm-<slug>` (e.g. `20260421-034447-726-conductor-unknown-role`).
- **Tester loop:** `YYYYMMDD-HHMMSS-mmm` (the `<slug>` is omitted when no deterministic slug is available).

`fixture.json.fixture_id` must equal the bundle directory basename.

## `fixture.json` schema

Top-level fields (required unless marked optional):

```jsonc
{
  "schema_version": 1,                     // int, pinned to v1
  "fixture_id": "YYYYMMDD-HHMMSS-mmm[-slug]",
  "slug": "conductor-unknown-role",        // string, defaults to fixture_id tail when none
  "created_at": "2026-04-21T03:44:47.826-07:00",  // ISO-8601 with millis + offset
  "bundle_source": "research" | "blink_app",      // optional; origin marker. Tester app emits "blink_app". Missing field reads as "research" for backwards compat with pre-v1.1 research-loop fixtures.
  "labels": [],                            // string[]
  "tags": [],                              // string[]
  "capture_settings": { /* settings.json snapshot used at capture time */ },
  "source": {
    "captured_at": "ISO-8601 or null",
    "image_path": "source.png",            // relative to bundle_dir
    "request_image_path": "source.request.jpg",  // optional; relative to bundle_dir
    "bytes": 1317252,
    "request_bytes": 251118                // optional
  },
  "target": {
    "captured_at": "ISO-8601 or null",
    "image_path": "target.png",
    "request_image_path": "target.request.jpg", // optional
    "bytes": 549617,
    "request_bytes": 177970                // optional
  },
  "app": {
    "frontmost_app": "Safari",             // resolved focused-element owner app, never silently folded with workspace_frontmost_app
    "frontmost_window_title": "Inbox · name@example.com",  // optional
    "frontmost_pid": 16941,                // optional
    "workspace_frontmost_app": "Safari",   // NSWorkspace.frontmostApplication at hotkey time; may differ from focused
    "workspace_frontmost_window_title": "…",
    "workspace_frontmost_pid": 16941,
    "focused_app": "Safari",               // owning app of the resolved focused element
    "focused_app_pid": 16941,
    "focused_app_bundle_id": "com.apple.Safari"
  },
  "warnings": [ /* string[]; mirrors target_metadata.warnings */ ],
  "target_metadata": { /* see below */ },
  "ax":       { "chrome_ax_empty": false, "focused_path": "ax_focused.json", "nearby_path": "ax_nearby.json" },
  "caret":    { "path": "caret.json" },
  "geometry": { "path": "geometry.json" },
  "clipboard":{ "path": "clipboard.json" },
  "ocr":      { "path": "ocr.json" },
  "capture":  { "path": "capture.json" }
}
```

Sweep reads exactly these fields:

- `fixture_id`
- `source.image_path`
- `target.image_path`
- `target_metadata`
- (existence of `fixture.json`; discovery predicate)

All other fields are informational but should still validate. Emitters that can't populate an optional field should omit it rather than emit a placeholder.

### `bundle_source`

- `"research"` — emitted by `scratchpad/run_gemini_trial.py` (the hotkey runner). Not currently emitted by the runner; missing `bundle_source` is treated as `"research"` by convention.
- `"blink_app"` — emitted by `app/python/run_once.py` invoked from `Blink.app` or manually.

Use this to segment sweep outputs by origin without inspecting the directory path. Consumers that branch on origin MUST tolerate the missing-field case.

## `target_metadata` schema

```jsonc
{
  "status": "ok" | "permission_denied" | "not_found",
  "frontmost_app": "Safari",
  "frontmost_window_title": "Inbox",
  "frontmost_pid": 16941,
  "workspace_frontmost_app": "Safari",
  "workspace_frontmost_window_title": "Inbox",
  "workspace_frontmost_pid": 16941,
  "focused_app": "Safari",
  "focused_app_pid": 16941,
  "focused_app_bundle_id": "com.apple.Safari",
  "focused_role": "AXTextField",
  "focused_subrole": null,
  "focused_title": null,
  "focused_description": null,
  "focused_value": "prior value — full, not shortened, in the `_full` tree",
  "focused_value_preview": "prior value — shortened to ~120 chars at the top level",
  "focused_label": "To",
  "focused_bounds": { "x": 123.0, "y": 456.0, "width": 200.0, "height": 30.0 },
  "permission": { "accessibility_trusted": true },
  "warnings": [],
  "error": null,
  "error_detail": null,
  "_full": { /* same shape, unshortened */ },
  "_debug": { /* emitter-specific diagnostics, not contractual */ }
}
```

Rules:

- A non-`ok` status MUST set `error` (and optionally `error_detail`) rather than silently emitting empty fields.
- Every field visible to the model (`frontmost_app`, `focused_*`, `workspace_frontmost_*`) must be either populated from a real AX read or explicitly `null`. Do not substitute heuristics without recording a `warnings` entry.
- Swift's native AX capture in `TargetMetadataCapture.swift` MUST reach parity with this shape. Any field it cannot populate must show up in `warnings` — never silently dropped.
- `_debug` is reserved for emitter-specific diagnostics. Consumers must not rely on its structure.

### Shortened vs full

- Top-level `focused_value` → short preview (`focused_value_preview`; ≤ `nearby_ax_value_preview_chars` from settings, default 120).
- `_full.focused_value` → full untruncated value.

## `run.json` schema (tester loop)

Emitted by `app/python/run_once.py`. Mirrors the research-loop `run.json` shape (see `scratchpad/run_gemini_trial.py:_persist_run_artifacts`) but narrower — no hotkey timings, no clipboard timings, no permissions snapshot.

```jsonc
{
  "schema_version": 1,
  "run_id": "YYYYMMDD-HHMMSS-mmm",
  "status": "ok" | "error",
  "bundle_source": "blink_app",
  "prompt_path": "/abs/path/to/prompt.txt",
  "settings": { /* snapshot */ },
  "target_metadata": { /* same as fixture.json.target_metadata */ },
  "source_packet": {
    "status": "ok",
    "prepared": true,
    "packet_chars": 1438,
    "kind": "local_source_text" | "native_ocr_paragraphs" | "model_extracted_text"
  },
  "target_context": {
    "mode": "target_ocr_packet" | "full_target_image", // optional; source-packet modes only
    "completeness": "sufficient" | "needs_target_image",
    "fallback_reasons": ["no_local_target_text"],
    "focused_label_hint": "Contact name",              // optional
    "packet_chars": 842,
    "full_target_image_role": "paste" | "extractor"    // only when mode == full_target_image
  },
  "request": {
    "model": "gemini-3.1-flash-lite-preview",
    "request_send_at": "ISO-8601",
    "prompt_chars": 612,
    "instruction_chars": 1832,
    "source_image_bytes": 251118,
    "target_image_bytes": 177970,
    "source_original_image_bytes": 1317252,
    "target_original_image_bytes": 549617,
    "images": { "source": { /* preprocessing log */ }, "target": { /* preprocessing log */ } }
  },
  "response": {
    "usage_metadata": { /* provider-specific */ },
    "chunk_count": 1,
    "response_metadata": { /* final-chunk dump */ },
    "output_tps": 42.7,
    "output_text": "…",
    "output_text_length": 123
  },
  "paste": {
    "text": "…",                   // normalized text actually returned on stdout for paste
    "model_text": "…",             // raw model output; mirrors response.output_text
    "normalized": true,
    "caret_pos": 12,               // optional
    "existing_text_length": 34     // optional
  },
  "timings": {
    "request_build_ms": 12.3,
    "source_image_prepare_ms": 3.1,
    "target_image_prepare_ms": 2.4,
    "request_send_at": "ISO-8601",
    "first_chunk_at": "ISO-8601",
    "final_chunk_at": "ISO-8601",
    "ttft_ms": 510,
    "stream_duration_ms": 180,
    "model_latency_ms": 690,
    "host_source_capture_ms": 412.7,              // optional; mirrored from host_profile.json
    "host_source_text_capture_ms": 41.2,          // optional; exact local text attempt before OCR fallback
    "host_source_prepare_source_packet_ms": 1184.2,
    "host_source_set_total_ms": 1608.4,
    "host_target_metadata_capture_ms": 44.3,
    "host_target_caret_capture_ms": 5.8,
    "host_target_screenshot_capture_ms": 271.6,
    "host_target_capture_total_ms": 321.7,
    "host_artifact_prep_ms": 18.4,
    "host_pre_python_ms": 347.9,
    "host_python_wall_ms": 1028.5,
    "host_insert_ms": 71.6,
    "host_run_target_total_ms": 1452.9
  },
  "errors": [ /* string[] — present only on error */ ],
  "warnings": [ /* string[] */ ]
}
```

Notes:

- `timings.end_to_end_ms` is the Python helper's own wall time once `run_once.py`
  has started. It does **not** include the Swift-side capture, temp-file, or
  paste phases.
- The optional `host_*` timing keys are copied into `run.json.timings` by the
  Swift app after the trial finishes so the in-app inspector can summarize them
  without opening extra files.
- `source_packet.kind` distinguishes the legacy model-extracted source packet
  from exact local source text and the deterministic native OCR paragraph packet
  used by the hybrid mode.
- When `source_packet.kind == "local_source_text"`, `source_text.json` is the
  source-of-truth capture payload and `prepared_source.json.runtime_signature`
  includes the source-text digest used to reject stale prepared packets.
- `target_context.mode` records whether the source-packet request used the
  shared local target OCR packet or routed to the pre-request full-target-image
  fallback.
- `target_context.fallback_reasons` mirrors the target packet sufficiency
  decision. Fast local source OCR and model-extracted source packets use the
  same target-context builder and fallback policy; they differ only in
  `source_packet.kind`.
- `target_ocr_packet.txt` is intentionally not a debug dump. Blink acts on
  geometry, OCR buckets, roles, and fallback reasons before generation and keeps
  those details in `target_ocr_packet.build.json` plus `run.json.target_context`.

## `host_profile.json` schema (tester loop, optional)

Emitted by the Swift side of `Blink.app` after each trial. This file records the
wall-clock phases around the Python helper and paste insertion, and mirrors the
headline timing numbers into `run.json.timings`.

```jsonc
{
  "schema_version": 1,
  "bundle_id": "YYYYMMDD-HHMMSS-mmm",
  "recorded_at": "ISO-8601",
  "source": {
    "captured_at": "ISO-8601",
    "request_mode": "baseline_full_images",
    "capture_started_at": "ISO-8601",
    "capture_finished_at": "ISO-8601",
    "capture_ms": 412.7,
    "source_text_capture_started_at": "ISO-8601",  // optional
    "source_text_capture_finished_at": "ISO-8601", // optional
    "source_text_capture_ms": 41.2,                // optional
    "source_text_status": "ok",                    // optional; "ok" or "no_text"
    "source_text_method": "ax_selected_text",      // optional; or "cmd_c"
    "source_text_chars": 1438,                     // optional
    "prepare_source_packet_started_at": "ISO-8601",   // optional
    "prepare_source_packet_finished_at": "ISO-8601",  // optional
    "prepare_source_packet_ms": 1184.2,               // optional
    "prepared_source_packet": true,                   // optional
    "set_source_started_at": "ISO-8601",
    "set_source_finished_at": "ISO-8601",
    "set_source_total_ms": 1608.4
  },
  "target": {
    "request_mode": "baseline_full_images",
    "capture_started_at": "ISO-8601",
    "capture_finished_at": "ISO-8601",
    "metadata_capture_started_at": "ISO-8601",
    "metadata_capture_finished_at": "ISO-8601",
    "metadata_capture_ms": 44.3,
    "caret_capture_started_at": "ISO-8601",
    "caret_capture_finished_at": "ISO-8601",
    "caret_capture_ms": 5.8,
    "screenshot_capture_started_at": "ISO-8601",
    "screenshot_capture_finished_at": "ISO-8601",
    "screenshot_capture_ms": 271.6,
    "capture_total_ms": 321.7,
    "artifact_prep_started_at": "ISO-8601",
    "artifact_prep_finished_at": "ISO-8601",
    "artifact_prep_ms": 18.4,
    "focused_bounds_present": true
  },
  "python": {
    "started_at": "ISO-8601",
    "finished_at": "ISO-8601",
    "wall_ms": 1028.5,
    "status": "ok"
  },
  "paste": {
    "status": "ok" | "pending" | "error" | "skipped_empty_output" | "skipped_python_failure",
    "started_at": "ISO-8601",              // optional
    "finished_at": "ISO-8601",             // optional
    "insert_ms": 71.6,                     // optional
    "error": "..."                         // optional
  },
  "summary": {
    "host_source_capture_ms": 412.7,
    "host_source_text_capture_ms": 41.2,
    "host_source_prepare_source_packet_ms": 1184.2,
    "host_source_set_total_ms": 1608.4,
    "host_target_metadata_capture_ms": 44.3,
    "host_target_caret_capture_ms": 5.8,
    "host_target_screenshot_capture_ms": 271.6,
    "host_target_capture_total_ms": 321.7,
    "host_artifact_prep_ms": 18.4,
    "host_pre_python_ms": 347.9,
    "host_python_wall_ms": 1028.5,
    "host_insert_ms": 71.6,
    "host_run_target_total_ms": 1452.9
  }
}
```

## Clock / format conventions

- Timestamps: ISO-8601 with millisecond precision and local TZ offset (e.g. `2026-04-21T03:44:47.826-07:00`). Emit via `gemini_runner.now_iso()` on the Python side; match on the Swift side.
- Timing durations: float milliseconds, rounded to 2 decimals.
- JSON: UTF-8, 2-space indent, `ensure_ascii=True` to keep artifacts diffable across platforms.
- File sizes (`bytes`, `request_bytes`): integer byte counts.

## Evolution rules

1. Any change that removes a field, renames a field, or narrows a type bumps `schema_version`.
2. Adding a new optional field without a default is allowed at v1 — consumers must tolerate unknown fields.
3. Swift and Python emitters must cut the same schema version simultaneously. Don't let them drift.
4. When bumping: update `FIXTURE_SCHEMA_VERSION` in `scratchpad/run_gemini_trial.py` and `app/python/run_once.py`, update this doc, add a migration note to `docs/EXPERIMENT_LOG.md`.
