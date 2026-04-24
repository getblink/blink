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
| `settings.json` | no | Snapshot of the capture settings used at trial time. Mirrors `fixture.json.capture_settings`. Tester loop writes this; research loop may skip. |
| `target_metadata.json` | no | Raw, unshortened target metadata captured at trial time. Mirrors `fixture.json.target_metadata`. Present when the emitter captures a full AX tree. |
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
    "model_latency_ms": 690
  },
  "errors": [ /* string[] — present only on error */ ],
  "warnings": [ /* string[] */ ]
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
