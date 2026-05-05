# Experiment Log

Use this file to keep a durable record of what was tried, what worked, and what did not.

See also:

- `README.md` for the repo entrypoint and quickstart
- `docs/PROJECT_BRIEF.md` for scope and success criteria
- `docs/MANUAL_COPY_PASTE_PLAYBOOK.md` for trial structure and evaluation framing
- `scratchpad/README.md` for the current capture and sweep workflow

## Entry template

```md
## YYYY-MM-DD — Experiment Title

- **Hypothesis:**
- **Setup:**
- **Input type(s):**
- **Target field type(s):**
- **Outcome:**
- **Evidence / examples:**
- **Decision:**
- **Next step:**
```

---

## 2026-05-04 — TLDR screenshot compression + OCR sweep harness

- **Hypothesis:** Client-side JPEG/downscale can reduce TLDR screenshot upload time, and a parallel native Vision OCR packet can preserve small-text grounding well enough to justify aggressive compression.
- **Setup:** Added a TLDR-specific fixture format under `scratchpad/tldr_reply/fixtures/<slug>/`, a `./tldr --save-fixture <dir>` capture path that writes `screenshot.png` plus `tldr_fixture.json` without sending or leaving a `tldr_runs` stub, and `scratchpad/tldr_reply/eval_sweep.py` to run fixture x config sweeps. The sweep reuses `prepare_request_image(...)` for compression with request artifacts isolated to each sweep cell, reuses the native OCR packet path from `app/python/source_ocr.py`, runs OCR and image prep concurrently, sends Gemini the TLDR screenshot contents plus optional structured OCR context, and writes `summary.md`, `compare.html`, and per-cell artifacts with failure tracebacks, prompt-token deltas, and explicit latency caveats.
- **Input type(s):** Frontmost-window TLDR screenshots captured manually.
- **Outcome:** Harness implemented; needs a 6-10 fixture corpus and real sweep run before any shipped `tldr_app/` integration.
- **Evidence / examples:** `scratchpad/tldr_reply/eval_sweep.py`, `scratchpad/tldr_reply/runner.py`, `scratchpad/eval_configs/tldr_*.json`, `scratchpad/tldr_reply/README.md`.
- **Decision:** Keep this sweep-first. Do not add compression/OCR to `tldr_app/` until a config beats baseline on `total_ms` without losing manual TLDR/suggestion quality.
- **Next step:** Capture representative chat, email, docs, article, dashboard, and small-text fixtures; run the TLDR sweep; manually grade `compare.html`; then decide whether Phase B is warranted.

### Follow-up: cross-model sweep + hallucination root cause

- **Hypothesis (refined):** A real production hallucination on `gemini-3-flash-preview` ("Gemini 1.5 Pro" instead of "Gemini 3 Flash") was caused by small text being illegible at `MEDIA_RESOLUTION_LOW`; aggressive compression plus a Vision OCR packet should save latency and tokens *and* eliminate the hallucination.
- **Setup:**
  - Imported 90 production runs from `~/Library/Application Support/TLDR/runs/` via `scratchpad/tldr_reply/import_runs.py` into `scratchpad/tldr_reply/fixtures/from_runs/`. 86 of 90 are Conductor screenshots — corpus-bias caveat noted.
  - Broader sweep: 10 representative fixtures × 7 configs on `gemini-3.1-flash-lite-preview` (default), n=1.
  - Hallucination-focused high-N: 1 fixture (`20260504-024528-026`) × 7 configs × 20 trials × 4 models (`gemini-3.1-flash-lite-preview`, `gemini-2.5-flash`, `gemini-3-flash-preview`, `gemini-3-pro-preview`). Pro hit a 25 RPM quota; only 6 of 20 trials per cell completed before failures, so Pro data is partial.
  - OCR-only probe (no image): 2 fixtures × 5 trials on `gemini-3-flash-preview`.
  - Direct token-count probe: 1 image × 3 media_resolution settings on `gemini-3-flash-preview`.
- **Outcome (per question):**
  - **Token floor: confirmed.** `prompt_token_count` is flat across image bytes at fixed `media_resolution`. Compression saves wire bytes, not LLM tokens. Image-token cost on `gemini-3-flash-preview`: LOW = 255, MEDIUM = 528, HIGH = 1085. Earlier "~64 tokens at LOW" estimate was wrong.
  - **Compression latency win: real on Lite.** Broader sweep median `total_ms`: baseline (PNG, native, LOW) 2741ms → `q70_d1600` (JPEG, LOW) 2224ms = **517ms savings**, no quality regression vs `prod` column on n=10 fixtures.
  - **OCR is a net loss almost everywhere.** OCR adds ~350-450ms `ocr_ms`, only saves ~150ms `network_ms`. On the broader sweep, OCR variants land 250-370ms slower than `q70_d1600`. On the hallucination fixture, OCR-grounded configs hallucinate harder (see below).
  - **Hallucination is model-specific to `gemini-3-flash-preview`.** On the same fixture, the four models' hallucination rates at JPEG q70 d1600 LOW (n=20 each): flash-preview **18/20**, flash-lite 0/20, 2.5 Flash 0/20, Pro 0/6. Lite (the actually-shipped default) and 2.5 Flash never fabricate the version on any tested config.
  - **JPEG-at-LOW is catastrophic specifically for flash-preview.** Same fixture: PNG at LOW 0/20, JPEG q70 d1600 at LOW **18/20**, JPEG q70 d1600 at MEDIUM 0/20. Mechanism: client-side JPEG + downscale degrades the small "Gemini 3" qualifier; flash-preview's confident priors fill the gap with "Gemini 1.5". MEDIUM gives enough pixel area to read "3" reliably and the failure mode disappears.
  - **OCR doesn't rescue flash-preview.** OCR + image at LOW: 20/20 hallucinated regardless of whether the prefix was the original ("current screen evidence wins") or rewritten to invert priority ("trust OCR over image"). Even OCR-only (no image, packet text contains the literal "Gemini 3 Flash") hallucinates 13/20 — the OCR text contains "Pro" 6× without version qualifier and the model defaults to its prior. The image being present makes it worse, not better.
  - **Production hallucination not reproducible today.** Best replication was 2/20 (10%) using the production-era system prompt + post-fix thinking config. Exact production replay (PNG, LOW, no `thinking_level` override, max_output_tokens=512, gemini-3-flash-preview, current prompt): **0/20**. Most likely cause is silent preview-model drift between the production capture (2026-05-04 02:45 PDT) and replay (~7 hours later), with secondary contributions from the missing `thinking_level="low"` override (commit `4f3d7e4` landed at 02:54 PDT, 9 minutes after the failure) and a different system prompt at the time.
  - **2.5 Flash is ~2× slower than Lite or flash-preview.** High-N median `total_ms` on baseline_LOW: Lite 3310ms, flash-preview 4020ms, 2.5 Flash 7164ms. Same prompt, same fixture, same settings. Not a viable daily driver candidate purely on latency.
  - **Pro is unsuitable as default.** Median 11s+ on the cells that completed before the rate limit; rate-limit-bound at 25 RPM on the free tier we're using.
- **Recommendations across model × compression × resolution:**

  | Model | Compression | media_resolution | OCR | Verdict |
  |---|---|---|---|---|
  | `gemini-3.1-flash-lite-preview` (current default) | JPEG q70 d1600 | LOW | none | **Recommended.** ~517ms faster than baseline, identical prompt tokens, 0/20 hallucinations. |
  | `gemini-3.1-flash-lite-preview` | none (raw PNG) | LOW | none | Baseline. Acceptable but ~500ms slower than the recommendation. |
  | `gemini-3.1-flash-lite-preview` | any | MEDIUM | none | Not justified; +120ms latency, +273 prompt tokens, no quality benefit observed. |
  | `gemini-3.1-flash-lite-preview` | any | any | included | Net loss on latency. Disqualified. |
  | `gemini-3-flash-preview` | none (raw PNG) | LOW | none | Acceptable but slow (~4s baseline). Risk of preview-model drift triggering version hallucinations. |
  | `gemini-3-flash-preview` | JPEG | LOW | none | **Forbidden.** 18/20 hallucination rate. |
  | `gemini-3-flash-preview` | JPEG | MEDIUM | none | **Required if using flash-preview.** 0/20 hallucinations, ~2.3s total_ms. +273 prompt tokens vs LOW. |
  | `gemini-3-flash-preview` | any | any | included | Disqualified (20/20 hallucinations at LOW, 6/20 at MEDIUM). |
  | `gemini-2.5-flash` | any | any | none | Clean (0/20 hallucinations) but ~2× slower than Lite. Not worth shipping unless quality reasons demand it. |
  | `gemini-3-pro-preview` | any | any | any | Too slow (~11s) and rate-limited on free tier. Suitable only as a manual-pick "hard cases" model. |
- **Evidence / examples:**
  - Sweep harness: `scratchpad/tldr_reply/eval_sweep.py`, `scratchpad/tldr_reply/import_runs.py`
  - Probe scripts: `scratchpad/tldr_reply/halluc_high_n.py`, `scratchpad/tldr_reply/ask_model_version.py`, `scratchpad/tldr_reply/ocr_only_probe.py`
  - Broader sweep output: `scratchpad/sweeps/tldr_20260504-143358/`
  - High-N per-model output: `scratchpad/sweeps/tldr_halluc_high_n/{gemini-3-flash-preview, gemini-3_1-flash-lite-preview, gemini-2_5-flash, gemini-3-pro-preview}/results.json`
  - Production hallucination fixtures: `scratchpad/tldr_reply/fixtures/from_runs/{20260504-024528-026, 20260504-024931-862}/expected.json`
- **Decision:**
  - For Phase B on the currently-shipped Lite default: ship `JPEG q70 d1600` at `MEDIA_RESOLUTION_LOW`, no OCR. Latency-only win.
  - Drop OCR-grounding from the experiment plan. The "OCR rescues small-text identification" hypothesis is empirically wrong on the corpus tested.
  - If the model picker ever defaults to `gemini-3-flash-preview`: force `MEDIA_RESOLUTION_MEDIUM` and disallow client-side JPEG-at-LOW.
- **Caveats:**
  - Corpus is 96% Conductor screenshots from a single user's dogfood pattern. The Lite "no quality regression" finding has not been validated on a diverse corpus.
  - Hallucination experiment was on a single fixture (the only one in the corpus that named a Gemini version). Generalizability to other small-entity-name failure modes (app names, account names, dollar amounts, dates) is untested.
  - Pro data is partial (n=6 for cells A and B, n=20 for C, n=0 for D-G). Pro's hallucination rate could not be characterized.
  - The original production hallucination on flash-preview is no longer cleanly reproducible. Most likely cause is silent preview-model drift; the experiment cannot prove a fix because the failure no longer fires consistently.
- **Next step:**
  - Land the Phase B compression diff in `tldr_app/python/tldr_once.py` with the `q70_d1600 + LOW` settings as the new default. Mark the existing per-model overrides untouched.
  - When that ships, capture a new fixture batch over a few days of dogfood and re-run the broader sweep at n=5 to confirm the Lite quality finding holds beyond n=1.
  - Skip Phase A.5's OCR-only experimental config in production permanently. Keep the harness for future probe work but do not promote it.

### Follow-up: Phase B shipped to `tldr_app/`

- **Change:** Local Gemini path in `tldr_app/python/tldr_once.py` now compresses screenshots to JPEG q70 max-dim 1600 by default, with a per-model resolution guard that forces `MEDIA_RESOLUTION_MEDIUM` when `model == "gemini-3-flash-preview"`. Diagnostics (`image_bytes_original`, `image_bytes_compressed`, `image_prepare_ms`, `media_resolution_resolved`) flow into `response.json` and `run.json`. `prepare_request_image` is copied into `tldr_app/python/image_prep.py` (header points at `scratchpad/gemini_runner.py:56`) per the fork policy. No OCR, no prompt, no envelope, no server changes.
- **Dogfood verification (n=1 each):**
  - `gemini-3-flash-preview`: original 423,988 → compressed 206,546 bytes (**48.7%**), prep 46ms, `media_resolution_resolved=MEDIA_RESOLUTION_MEDIUM` (guard fired correctly), `duration_ms=2265`.
  - `gemini-3.1-flash-lite-preview`: original 384,985 → compressed 176,978 bytes (**46.0%**), prep 43ms, `media_resolution_resolved=MEDIA_RESOLUTION_LOW` (passthrough), `duration_ms=2207`.
- **Tests:** `python3 -m unittest discover tldr_app/python/tests` → 28 OK; covers PNG-fallback, JPEG-emit, MEDIUM-forced-on-flash-preview, LOW-passthrough-on-Lite, and run.json diagnostic plumbing.
- **Known scope gaps (not blockers, called out explicitly):**
  - **Proxy path is unaffected.** When `BLINK_PROXY_URL` + `BLINK_PROXY_TOKEN` are set, `_encode_multipart_request` uploads the raw PNG and the server (`server/gemini.py`) does no compression. Users on the production proxy install get no latency win from this change. A follow-up would either compress before proxy upload or apply the same logic server-side.
  - **Flash-preview guard is exact-string match** (`model == "gemini-3-flash-preview"`). If Google rev-suffixes the preview model, the catastrophic-failure-prevention rule silently stops applying. Preview-model drift is already on the risk list.
- **Evidence / examples:** `tldr_app/python/tldr_once.py` (`DEFAULT_SETTINGS`, `media_resolution_for_model`, `prepare_screenshot_part`), `tldr_app/python/image_prep.py`, `tldr_app/python/tests/test_tldr_once.py`. Dogfood runs at `~/Library/Application Support/TLDR/runs/20260504-185828-687/run.json` and `.../20260504-190503-147/run.json`.
- **Decision:** Phase B closed. Latency and guardrail behavior verified end-to-end on the local Gemini path.
- **Next step:** Address the proxy-path gap if production users (proxy install) are the target audience for the latency win. Otherwise, watch dogfood for any quality regressions on the under-represented surfaces flagged in the corpus-bias caveat.

## 2026-04-30 — TLDR.app native expand-first overlay

- **Hypothesis:** The Swift-shipped TLDR surface will feel safer and clearer if it matches the scratchpad prototype: number keys expand first, repeated number copies, Return inserts only after an explicit expansion, and Esc dismisses.
- **Setup:** Ported the scratchpad overlay interaction into `tldr_app/` as native AppKit UI: separate TL;DR card, pill suggestion cards, highlighted expansion, per-card Return hint, Return hotkey routing, and event/run logging for expansion, copy, insert, dismiss, and paste failures. Kept Python as the packaged `/v1/tldr` runner and left `auto_paste` decode-only for old runtime configs.
- **Input type(s):** Frontmost-window screenshot TLDR requests.
- **Target field type(s):** Reply contexts in the focused app, with insertion through the existing clipboard + Cmd+V path.
- **Outcome:** Implemented in the Swift app; validation results live in the implementing branch notes.
- **Evidence / examples:** `tldr_app/TLDR/SuggestionsOverlay.swift`, `tldr_app/TLDR/TLDRCoordinator.swift`, `tldr_app/TLDR/HotkeyManager.swift`, `tldr_app/TLDR/SuggestionChoiceState.swift`, `tldr_app/TLDRTests/SuggestionChoiceStateTests.swift`.
- **Decision:** Remove the visible auto-paste mode from the shipped surface. Keep explicit copy-vs-insert gestures instead.
- **Next step:** Dogfood in a real app after a TCC-reset install and inspect the resulting event sequence for one copied run and one inserted run.

### Follow-up: Liquid Glass parity with the Python overlay

- **Issue:** The first port used `NSVisualEffectView` with an explicit 1pt separator border and `.popover` material on suggestion pills, which read as flat white cards versus the Python overlay's translucent glass. Hint copy also drifted (`-` separators instead of `·`, plain `Return to insert` instead of `⏎ Enter to insert`).
- **Fix:** Reworked card construction around a shared `makeGlassPane` helper that uses `NSGlassEffectView` (`.regular` style, `cornerRadius` set on the glass view) when `#available(macOS 26.0, *)` and falls back to a borderless `NSVisualEffectView` (`.hudWindow`, behind-window blending) for older OSes. Numbers, labels, tints, and the `⏎ Enter to insert` footer now live on the glass `contentView`. Removed the manual layer border and added a `suppressOutline` helper that mirrors the Python `_suppress_glass_outline` (clear shadow, no focus ring, no border). Hint string aligned to the Python wording.
- **Evidence / examples:** `tldr_app/TLDR/SuggestionsOverlay.swift` (new `GlassPane`, `makeGlassPane`, `suppressOutline`, `setCornerRadius`), and the matching helpers in `scratchpad/tldr_reply/overlay.py`.
- **Validation:** `xcodebuild test -project TLDR.xcodeproj -scheme TLDR -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` and `TLDR_SKIP_TCC_RESET=1 bash tldr_app/scripts/build.sh` both pass; canonical app reinstalled via `bash tldr_app/scripts/install_local_app.sh`.
- **Caveat:** With `LSUIElement: true` (accessory) and `.nonactivatingPanel` retained, AppKit may still draw a thin outline around `NSGlassEffectView` per the comment in `scratchpad/tldr_reply/overlay.py`. The trade-off (no dock icon, no focus theft) is intentional for now; revisit if the residual outline reads as "flat" in dogfood.
## 2026-04-30 — Pasteboard type logger

- **Hypothesis:** A tiny Swift command-line logger for `NSPasteboard.general` will make app-specific clipboard behavior visible enough to decide which pasteboard types Blink should preserve or prefer during source capture.
- **Setup:** Added `experiments/pasteboard_logger/`, a SwiftPM package with a logger that polls `NSPasteboard.general.changeCount`, prints one block per change to stdout and a timestamped log file, records the best-effort frontmost app at detection time, enumerates pasteboard items/types, records byte sizes, previews common text/UTF-16 text/HTML/RTF/URL/file URL/Chromium source URL payloads, reports image dimensions for common image types, and falls back to first-64-byte hex for proprietary types. Also added an HTML preview command that can watch the pasteboard, append immutable snapshot folders, and serve a local timeline page that renders `public.html` from files when present. Added `BatchClipboardHistoryReplay`, an offline replay command that reads those immutable preview folders and emits deterministic `schema_version: 0` model-request JSON with byte-free item summaries plus separate runtime payload references. Concealed/password-like items are reported without content or type payload details and omitted from replay handles.
- **Input type(s):** Live macOS clipboard changes from manual copy actions.
- **Target field type(s):** N/A.
- **Outcome:** First runnable diagnostic and replay harness landed; build, unit tests, and CLI smoke checks pass. Initial saved run captured 7 substantive events: WebKit/Conductor rich text, PNG-only image copies, and Chromium/Google Docs or Slides selections with `public.html`, `public.utf8-plain-text`, `org.chromium.source-url`, and large `org.chromium.web-custom-data` payloads. Plain text preserved useful line breaks, while rich HTML sometimes carried very large embedded image data. Frontmost-app attribution showed Conductor for every event in this run, so the current source-app field is not reliable enough by itself.
- **Evidence / examples:** `experiments/pasteboard_logger/`; local ignored logs under `experiments/pasteboard_logger/logs/`; local ignored preview and replay outputs under `experiments/pasteboard_logger/html-preview/` and `experiments/pasteboard_logger/model-requests/`.
- **Decision:** Keep this as experiment-only research tooling, separate from `Blink.app`, `TLDR.app`, `./capture`, and `./sweep`.
- **Next step:** Run the deliberate capture session: Slides one element, Slides multi-element, Figma, webpage, PDF, screenshot, Finder multi-select, and password manager. Keep the ignored `html-preview/` corpus and replayed request JSON as local evidence for deciding the v1 clipboard capture strategy.

### 2026-04-30 update — Offline embedded-media extraction

- **Hypothesis:** Decoding obvious `data:image/...;base64,...` payloads from captured HTML into separate replay handles will make Google Slides-like clipboard evidence useful for batch-paste architecture decisions without putting embedded bytes into model-facing summaries.
- **Setup:** Extended `BatchClipboardHistoryReplay` to scan decoded `public.html`/HTML pasteboard payloads offline, preserve the original pasteboard item as `item_N`, emit derived image items like `item_1_image_1` immediately after the source item, write decoded media into replay-owned `model-requests/derived-payloads/`, and clean stale derived payloads plus stale `*.request.json` files on each run. Derived items carry `derived_from`, `derived_kind`, MIME type, byte size, dimensions when AppKit can decode them, and source UTI/path metadata.
- **Result:** Fixture coverage now includes one embedded PNG, multiple embedded images in source order, HTML plus plain-text preview preservation, byte-free redaction for HTML-only embedded images, invalid/unsupported embedded image warnings, and stale derived-output cleanup.
- **Decision:** Keep this scoped to deterministic offline evidence generation. Do not split HTML text, tables, lists, CSS backgrounds, external URLs, SVG fragments, or any product-facing rolling clipboard buffer yet.
- **Next step:** Replay the ignored Slides/web capture corpus and inspect which derived image handles would be worth feeding into the first batch-paste model prompt.

### 2026-04-30 update — Interactive batch clipboard-history dry run

- **Hypothesis:** A terminal-driven live harness can validate the batch clipboard-history loop end to end before any Blink.app paste execution, UI, reset, or pin semantics are added.
- **Setup:** Added `BatchClipboardHistoryHarness`, shared the immutable pasteboard snapshot writer with `PasteboardHTMLPreview`, and extended `PasteboardReplayCore` with multi-snapshot assembly, global `item_N` handle remapping, model-output validation, and payload resolution. The harness watches `NSPasteboard.general.changeCount`, stores non-concealed captures in a rolling in-memory buffer, accepts a typed `goal`, writes byte-free model requests plus full local artifacts, calls `experiments/pasteboard_logger/scripts/batch_model_select.py`, and stops at `resolved-selection.json`.
- **Result:** Implemented with tests for flattening multiple snapshots, remapping embedded-image parent links, omitting concealed snapshots, rejecting invalid/unknown/duplicate selections, and resolving original/derived payload paths with byte-size checks. Mock-mode smoke produced a full run bundle without provider credentials.
- **Decision:** Keep this experiment-local and dry-run only. It proves request construction, model selection contract, validation, and local payload resolution without touching the pasteboard output path.
- **Next step:** Run a real live copy sequence with provider credentials, inspect `batch-request.model.json` for prompt usefulness, then decide whether selected payloads should be stitched into a future manual paste prototype.

### 2026-04-30 update — Blink.app target-aware batch paste dogfood hotkey

- **Hypothesis:** Now that model selection and reference resolution work, a private Blink.app hotkey can validate the first true end-to-end batch paste without adding picker UI, custom goals, reset/pin semantics, or destination-specific flavor ranking.
- **Setup:** Added Cmd+Option+V to the existing CGEventTap hotkey manager. Blink.app now keeps a rolling pasteboard snapshot buffer, assembles a batch request with `goal: "paste all"`, captures the destination with the existing target metadata/screenshot/geometry path, uses `target_context.py` to build `target_ocr_packet.txt`, and attaches that target context to the batch selector request. The selected handles are validated, resolved back to runtime payload files, written to `NSPasteboard` with their original representations, pasted with one synthesized Cmd+V per selected item, and the user's prior clipboard is restored afterward. Artifacts are written under `~/Library/Application Support/Blink/batch-clipboard-history/runs/`.
- **Result:** Implemented and locally installed through the canonical `~/Applications/Blink.app` path. Build/test checks passed, the signed installed app verifies after preventing bundled Python from writing new bytecode into sealed resources, and the app default request mode now prefers the target OCR/AX context path over the old full-image baseline.
- **Decision:** Treat this as a dogfood-only bridge. It intentionally keeps the fixed `paste all` goal, but target context lets the model interpret that as "paste the matching clipboard item(s) into this focused field" when a field label is available.
- **Next step:** Re-grant Input Monitoring, Accessibility, and Screen Recording after the TCC reset, then copy two or three controlled items and trigger Cmd+Option+V in a labeled destination field. Inspect the newest batch run bundle, especially `target_ocr_packet.txt`, `batch-request.model.json`, and `model-output.raw.txt`, if selection or paste behavior is surprising.

## 2026-04-29 — TLDR v1 request envelope, event diagnostics, and pending-run recovery

- **Hypothesis:** TLDR can move from screenshot-only RPC toward a sturdier client/server shape without losing local debuggability if Swift emits a richer request envelope, preserves pending-run state locally, and the server accepts structured request/event telemetry while keeping `/tldr` compatibility.
- **Setup:** Added `POST /v1/tldr` and `POST /v1/tldr/events` on the FastAPI server, optional Postgres/Redis telemetry plumbing, cache-aware request hashing, and a legacy `/tldr` wrapper. TLDR.app now writes `request.json`, image diagnostics, focused-context metadata, and pending-run records, uploads event telemetry when proxy settings are configured, and reports abandoned runs on next launch. The packaged Python runner now forwards the Swift-generated request envelope to `/v1/tldr` in proxy mode and still falls back to direct Gemini locally.
- **Input type(s):** Frontmost-window screenshot requests, plus OCR/focused-context-ready envelope slots for future non-screenshot or hybrid runs.
- **Target field type(s):** Reply contexts visible in the active app; current focus metadata is best-effort AX context for draft-aware suggestions.
- **Outcome:** Implemented. Server contract tests passed in a dedicated `server/.venv`, packaged-runner unit tests passed, Python modules compile, and `TLDR_SKIP_TCC_RESET=1 bash tldr_app/scripts/build.sh` succeeded twice after the Swift integration.
- **Evidence / examples:** `server/main.py`, `server/cache.py`, `server/storage.py`, `docs/SERVER_CONTRACT.md`, `tldr_app/TLDR/TLDRCoordinator.swift`, `tldr_app/TLDR/PendingRunStore.swift`, `tldr_app/TLDR/TLDREventClient.swift`, `tldr_app/python/tldr_once.py`.
- **Decision:** Keep the compatibility wrapper and direct-Gemini fallback for now, but make the richer `/v1/tldr` + `/v1/tldr/events` path the preferred TLDR.app integration surface.
- **Next step:** Dogfood a real proxy-backed TLDR session against Railway or local FastAPI, inspect one stored request/event sequence in Postgres, and decide whether OCR should move into the current frontmost-window capture path next.

## 2026-04-27 — Standalone TLDR server prep

- **Hypothesis:** A tiny server-owned TLDR backend lets us dogfood the standalone Swift app without shipping a Gemini key, while keeping prompt and model iteration decoupled from app releases.
- **Setup:** Added a new `server/` package with FastAPI `/healthz` and `/tldr` endpoints, shared bearer-token validation, a deliberate fork of the TLDR Gemini helper, Railway deployment files, and server-specific docs. Updated `scratchpad/tldr_reply/` so `./tldr` can route screenshots through `BLINK_PROXY_URL` + `BLINK_PROXY_TOKEN` and still emit the same local artifacts.
- **Input type(s):** Single active-window screenshots from the TLDR runner or future standalone client.
- **Target field type(s):** Reply contexts visible inside the captured window; same TLDR/reply-suggestion surface as the local experiment.
- **Outcome:** Implementation landed. The repo now has a server contract, a proxy-capable local dogfood path, and revocable tester tokens without moving to real auth yet.
- **Evidence / examples:** `server/`, `docs/SERVER_CONTRACT.md`, `scratchpad/tldr_reply/gemini.py`, `scratchpad/tldr_reply/runner.py`, `.env.example`, `README.md`, and `CLAUDE.md`.
- **Decision:** Keep the backend intentionally narrow: no persistence, no per-user auth, and no coupling to `Blink.app`.
- **Next step:** Run the endpoint locally and through Railway with a real screenshot fixture, then let the standalone Swift workspace point at the same `/tldr` contract.

## 2026-04-27 — TL;DR + reply suggestions v0

- **Hypothesis:** A single-screenshot hotkey flow that returns a one-line TL;DR plus three paste-ready replies can validate an everyday assistant moment with less plumbing than the two-image copy-paste runner.
- **Setup:** Added an isolated `scratchpad/tldr_reply/` package and root `./tldr` wrapper. The runner listens for `ctrl+shift+t`, captures a selected window with `screencapture -W`, calls Gemini once with JSON response schema, and renders a PyObjC overlay where `1` / `2` / `3` copy a suggestion.
- **Input type(s):** One active-window screenshot from the live desktop.
- **Target field type(s):** Reply contexts visible in messaging, email, docs, or similar windows; no fixture/sweep schema.
- **Outcome:** Implementation landed. Initial dogfood confirmed the second-pass non-activating overlay keeps focus in the original app. One UX gap surfaced: after choosing a suggestion, copy-only behavior is safe but easy to forget to paste.
- **Evidence / examples:** `tldr`, `scratchpad/tldr_reply/`, `.gitignore`, `README.md`, and `CLAUDE.md`.
- **Decision:** Keep this as a sibling experiment that does not modify `./capture`, `./sweep`, or `Blink.app`.
- **Next step:** Add an explicit auto-paste toggle in a later iteration so users can choose between safe copy-only mode and direct insertion at the current caret.

## 2026-04-27 — TLDR.app Swift surface with Python internals

- **Hypothesis:** The single-screenshot TL;DR loop is ready for a shipped macOS surface if Swift owns the foreground app behavior and Python stays focused on Gemini plus artifact bundles.
- **Setup:** Added top-level `tldr_app/` as a sibling app package. Swift owns the `TLDR.app` menubar, `ctrl+shift+t` event tap, ScreenCaptureKit frontmost-window capture, non-activating overlay, numbered choice handling, and persisted auto-paste toggle. Python owns `tldr_once.py`, Gemini JSON parsing/fallbacks, and run artifacts.
- **Input type(s):** One frontmost-window screenshot captured by the Swift app.
- **Target field type(s):** Reply contexts visible in the active app; choice keys either paste into the still-focused field or copy only depending on `~/.tldr/runtime-config.json`.
- **Outcome:** Implemented and packaged. Local canonical install is `~/Applications/TLDR.app`; run bundles land under `~/Library/Application Support/TLDR/runs/`; DMG output is `tldr_app/build/TLDR-0.1.0.dmg`.
- **Evidence / examples:** `tldr_app/`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `.gitignore`; checks: `python3 -m unittest discover tldr_app/python/tests`, `python3 -m compileall tldr_app/python`, `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`, `TLDR_SKIP_TCC_RESET=1 bash tldr_app/scripts/build.sh`, `bash tldr_app/scripts/install_local_app.sh --reset-tcc --no-launch`, `bash tldr_app/scripts/make_dmg.sh`, and a bundled `tldr_once.py --skip-gemini` smoke test. Follow-up tightened the canonical installer so TCC resets by default on every TLDR rebuild.
- **Decision:** Keep `app/` and root `./tldr` intact. Treat `tldr_app/` as the TLDR-only shipped surface for v1.
- **Next step:** Launch `~/Applications/TLDR.app`, grant Input Monitoring, Accessibility, and Screen Recording, then dogfood `ctrl+shift+t` in a real conversation with auto-paste on and off.

## 2026-04-27 — Resolved-only target packets for paste

- **Hypothesis:** The paste LLM should receive resolved target facts, not Blink's evidence trail. Geometry, roles, OCR buckets, fallback reasons, and confidence limits are Blink-side routing/debug data.
- **Setup:** Slimmed `target_ocr_packet.txt` to `FOCUSED_FIELD_LABEL` when available, or empty when Blink has no resolved target fact. Kept OCR sections, focus/caret rects, role metadata, selected row text, completeness, and fallback reasons in `target_ocr_packet.build.json` / `run.json.target_context`. Updated the target-context prompt so the insertion contract lives in prompt instructions instead of the packet.
- **Input type(s):** Local target OCR packets and source-packet paste requests.
- **Target field type(s):** Google Docs pseudo-fields and generic focused fields with OCR-derived labels.
- **Outcome:** Implemented; tests assert the paste-facing packet excludes `INSERTION_CONTRACT`, `FOCUSED_FIELD_RECT`, `LIMITS`, `COMPLETENESS`, and OCR bucket sections while preserving `focused_label_hint` and fallback decisions.
- **Evidence / examples:** `app/python/target_context.py`, `app/Resources/target_context_prompt_ocr.txt`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/fixtures/manual_google_docs_target_20260425_205140.json`, `docs/ARTIFACT_SCHEMA.md`.
- **Decision:** Keep target evidence inspectable, but do not ask the text-only paste model to reason over it.
- **Next step:** Dogfood one sufficient Google Docs row and confirm `generation.request.txt` contains only the resolved label in `TARGET_CONTEXT_PACKET`.

## 2026-04-27 — Top-anchored Google Docs focus bands

- **Hypothesis:** Google Docs `Group` thin-line bounds behave like the top edge of the caret/line, not the visual center of the target row, so OCR focus bands should expand downward from that line.
- **Setup:** Changed thin-line focus inflation from center-based to top-anchored. Replayed the latest live packet geometry where the raw local line was `y=726 height=2`; the synthesized band now becomes `y=726 height=40` instead of `y=707 height=40`.
- **Input type(s):** Latest live target OCR packet plus sanitized Google Docs thin-line fixture.
- **Target field type(s):** Google Docs pseudo-fields exposed as Chromium `Group` focus rows.
- **Outcome:** Implemented; unit coverage now checks the downward expansion directly and confirms packet building keeps the raw local line as the band top.
- **Evidence / examples:** `app/python/target_context.py`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/fixtures/manual_google_docs_target_20260426_150826_thin_line.json`.
- **Decision:** Treat the local thin line as a top anchor, with only bottom clamping near the image edge.
- **Next step:** Dogfood one row per Google Docs field and use the OCR visualizer to confirm each focus band overlays the intended label row.

## 2026-04-27 — Google Docs row-label hardening and OCR visualizer

- **Hypothesis:** Google Docs thin-line packets should fail closed unless row evidence identifies the focused pseudo-field, and Control Center should make OCR geometry inspectable without opening raw JSON.
- **Setup:** Normalized caret-tainted row labels such as `Phone:|` to `Phone:`, preferred label-like OCR inside the inflated focus band, and made Google Docs thin-line packets fall back when no focused label is resolved. Added `ocr_blocks` geometry to target/source OCR build logs and a Runs-tab OCR Visualizer with source/target image selection, OCR box/text toggles, and target focus/caret overlays.
- **Input type(s):** Local target OCR packets and native source OCR build logs.
- **Target field type(s):** Google Docs pseudo-fields with `Group` focus and thin caret-line geometry.
- **Outcome:** Implemented; focused tests cover caret-suffixed labels, missing focused-label fallback, and saved OCR block geometry.
- **Evidence / examples:** `app/python/target_context.py`, `app/python/source_ocr.py`, `app/Blink/ControlCenterWindow.swift`, `app/Blink/RuntimeConfigStore.swift`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/test_hybrid_request_mode.py`.
- **Decision:** Keep the unified target packet path. Do not address native source OCR poisoning yet.
- **Next step:** Use the new visualizer on fresh Google Docs runs to compare the inflated focus band against OCR boxes before changing row-band sizing.

## 2026-04-27 — Unify target context routing for Fast local OCR

- **Hypothesis:** `source_packet_target_ocr_or_full_image` and `source_ocr_target_text_or_full_image` should differ only in source packet construction; target localization, sufficiency, fallback, prompt contract, and logging should be shared.
- **Setup:** Routed Fast local OCR through the same `build_target_ocr_packet` / `run_source_packet_target_ocr_packet` path as Auto. Added `SOURCE_PACKET_KIND` to source-packet generation requests so shared prompts can distinguish `model_extracted_text` from rawer `native_ocr_paragraphs` without forking target logic. Removed the separate target text-only prompt from the runtime snapshot/prompt picker.
- **Input type(s):** Model-extracted source packets and native OCR source paragraphs.
- **Target field type(s):** Local target OCR packet with full target image fallback.
- **Outcome:** Implemented; tests cover native source OCR using the shared target packet prompt and paste runtime, plus shared source packet kind request metadata.
- **Evidence / examples:** `app/python/run_once.py`, `app/python/source_packet.py`, `app/Resources/target_context_prompt_ocr.txt`, `app/Resources/source_packet_target_prompt_v3_ocr.txt`, `app/Blink/RuntimeConfigStore.swift`, `app/python/tests/test_runtime_split_models.py`, `app/python/tests/test_source_packet.py`.
- **Decision:** Keep Fast local OCR experimental as a source-prep variant, not a separate target pipeline.
- **Next step:** Dogfood Auto and Fast local OCR back-to-back on the same Google Docs rows and compare only source-packet quality differences.

## 2026-04-26 — Google Docs thin-line target label resolution

- **Hypothesis:** After Google Docs accessibility support is enabled, Chrome's zero/one-pixel `Group` focus line can be inflated into a reliable OCR row band and mapped to the focused field label.
- **Setup:** Added Google Docs thin-line handling in `target_context.py`: convert the focused AX line to screenshot coordinates, inflate it to a 40px row band, accept same-row colon labels that are left of or slightly overlapping the band, and emit `FOCUSED_FIELD_LABEL` plus `INSERTION_CONTRACT: focused_field_only` when resolved. Added sanitized fixture `manual_google_docs_target_20260426_150826_thin_line.json`.
- **Input type(s):** Source packet / source OCR plus local target OCR.
- **Target field type(s):** Google Docs structured document fields with accessibility-supported `Group` caret line.
- **Outcome:** Implemented. The old `Document content` fixture still fails closed, while the new thin-line fixture resolves `Contact name:` and synthetic y-shifts resolve all five visible labels.
- **Evidence / examples:** `app/python/target_context.py`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/fixtures/manual_google_docs_target_20260426_150826_thin_line.json`, `app/Resources/target_context_prompt_ocr.txt`, `app/Resources/target_text_only_prompt.txt`; focused checks: `python3 -m unittest app/python/tests/test_target_context_hint.py` and related runtime/source-packet tests.
- **Decision:** Apply the focused-field contract to target-context request modes; keep baseline/full-image modes unchanged for now.
- **Next step:** Dogfood `source_packet_target_ocr_packet`, `source_packet_target_ocr_or_full_image`, and `source_ocr_target_text_or_full_image` with the caret on each Google Docs label row.

## 2026-04-26 — Chrome text-marker caret diagnostics

- **Hypothesis:** Google Docs may expose a usable caret rect through Chrome/WebKit `AXTextMarker` attributes even when the standard selected-range bounds are degenerate.
- **Setup:** Added diagnostic probes to `TargetMetadataCapture.captureCaret()` for standard range/line parameterized attributes and private Chrome text-marker attributes such as `AXSelectedTextMarkerRange`, `AXTextMarkerForIndex`, `AXLineTextMarkerRangeForTextMarker`, and adjacent marker ranges.
- **Input type(s):** Blink.app target caret capture.
- **Target field type(s):** Google Docs document body / Chrome text surfaces.
- **Outcome:** Implemented as additive `caret.json` diagnostics only; paste behavior is unchanged until a live run proves a non-degenerate marker rect.
- **Evidence / examples:** `app/Blink/TargetMetadataCapture.swift`; checks: `CONFIG=Release BLINK_SKIP_TCC_RESET=1 bash app/scripts/build.sh`, `python3 -m unittest app/python/tests/test_source_packet.py app/python/tests/test_run_once_normalize.py`, and `python3 -m unittest discover app/python/tests`.
- **Decision:** Keep the first pass diagnostic-first so wrong-field paste behavior cannot get worse while we test whether Chrome exposes better caret geometry.
- **Next step:** Reinstall with TCC reset, run the Google Docs fixture again, and inspect `caret.json.text_marker.*.bounds.rect` plus `caret.json.range_probe.*.bounds.rect` for a non-zero, on-window caret or line rect.

## 2026-04-25 — Startup Screen Recording request and permissions window

- **Hypothesis:** After a TCC reset, `CGPreflightScreenCaptureAccess` and capture-time prompts are not enough to make Blink discoverable in the Screen Recording pane before use; Blink should create the row at startup and show the in-app permissions checklist immediately.
- **Setup:** Reintroduced `CGRequestScreenCaptureAccess()` in `AppDelegate.applicationDidFinishLaunching`, kept `IOHIDRequestAccess` for Input Monitoring registration, and made `showPermissionsWindow()` run unconditionally after menubar/hotkey setup.
- **Input type(s):** Blink.app launch / permission setup.
- **Target field type(s):** N/A.
- **Outcome:** Implemented, rebuilt, installed to the canonical `~/Applications/Blink.app`, reset TCC, and relaunched. The source now contains the startup Screen Recording request and the unconditional permissions-window call.
- **Evidence / examples:** `app/Blink/BlinkApp.swift`, `app/Blink/ScreenCapture.swift`, `docs/DOGFOOD_PLAYBOOK.md`, `app/README.md`; checks: `bash app/scripts/install_local_app.sh --reset-tcc`, bundled `python3 -m unittest discover .../Resources/tests`, and source grep for `CGRequestScreenCaptureAccess` / `showPermissionsWindow()`.
- **Decision:** Prefer discoverability and a guided first-launch permission flow over avoiding the startup Screen Recording prompt.
- **Next step:** On the next launch after TCC reset, confirm Blink appears in System Settings → Privacy & Security → Screen Recording and the in-app permissions window is visible.

## 2026-04-25 — Image-capable fallback for Google Docs target packets

- **Hypothesis:** The `[[NEEDS_REVIEW: target context needs image]]` case is the correct conservative signal for a strict OCR target packet, but Blink should automatically retry with a full target image when the target packet says the Google Docs focus context is unreliable.
- **Setup:** Inspected the latest run sequence: `source_packet_target_ocr_packet` produced `needs_target_image` with `google_docs_degenerate_focus_rect`, and `source_packet_target_ocr_or_full_image` attempted the right visual fallback but sent the screenshot to Groq `llama-3.3-70b-versatile`, which rejected image messages. Updated `run_once.py` so full-target-image routing checks provider/model `supports_vision` metadata and uses the extractor runtime when the paste runtime is text-only.
- **Input type(s):** Source packet plus target OCR packet, with fallback to target screenshot.
- **Target field type(s):** Google Docs document body with unreliable AX focus rect.
- **Outcome:** Implemented. Both `source_packet_target_ocr_packet` and `source_packet_target_ocr_or_full_image` now fall back to full target image when the target packet has `completeness: needs_target_image` or fallback reasons, and the screenshot is routed to a vision-capable runtime.
- **Evidence / examples:** `app/python/run_once.py`, `app/python/tests/test_runtime_split_models.py`; checks: `python3 -m unittest app/python/tests/test_runtime_split_models.py app/python/tests/test_target_context_hint.py app/python/tests/test_source_packet.py`, `python3 -m compileall app/python`, `python3 -m unittest discover app/python/tests`, bundled `python3 -m unittest discover .../Resources/tests`, and `bash app/scripts/install_local_app.sh --reset-tcc`.
- **Decision:** Keep Groq text-only paste for fast packet-sufficient cases, but reroute visual target fallback to Gemini/extractor when needed.
- **Next step:** Re-test the same Google Docs target; the fallback run should show `fell_back_to_full_target_image` plus `full_target_image_used_extractor_runtime` instead of a Groq image-content error.

## 2026-04-25 — Manual Google Docs fixture regression tests

- **Hypothesis:** Synthetic unit tests are not enough for the Google Docs target ambiguity; a sanitized fixture from the manual run sequence should catch drift in the real target metadata, OCR-packet, prompt-metadata, and runtime-routing contracts.
- **Setup:** Added `app/python/tests/fixtures/manual_google_docs_target_20260425_205140.json`, distilled from runs `20260425-205140-853`, `20260425-205246-898`, and `20260425-205156-195`. The fixture includes only JSON/text artifacts: target metadata, caret, geometry, sanitized OCR blocks, expected packet text, and the extractor/paste runtime selection.
- **Input type(s):** Sanitized Google Docs target run artifacts.
- **Target field type(s):** Google Docs document body with `Document content` AX metadata and a 1px focus rect.
- **Outcome:** Implemented targeted regression coverage for `build_target_ocr_packet`, `build_target_ocr_text`, `compact_target_metadata`, `_full_target_image_role`, `_should_use_full_target_image`, and the mocked `run_once.main()` fallback branch.
- **Evidence / examples:** `app/python/tests/fixtures/`, `app/python/tests/fixture_helpers.py`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/test_source_packet.py`, `app/python/tests/test_runtime_split_models.py`; focused checks: `python3 -m unittest app/python/tests/test_target_context_hint.py app/python/tests/test_source_packet.py app/python/tests/test_runtime_split_models.py`.
- **Decision:** Keep live manual artifacts as small sanitized unit fixtures, not as dependencies on the local Blink run directory.
- **Next step:** When a future manual dogfood failure has a distinct artifact shape, add one fixture at the contract boundary that failed rather than copying the whole run bundle.

## 2026-04-25 — Google Docs target-focus fallback and permission prompt cleanup

- **Hypothesis:** The latest Google Docs target failures are caused by unreliable AX target focus, not by a stale install: Google Docs reports the focused field as `Document content`, a 1px-high focus rect near the toolbar, and a zero-width-only focused value, so text/OCR-only target routing cannot identify the active blank line.
- **Setup:** Inspected the latest Blink app bundles `20260425-201938-559` and `20260425-202012-949`; verified the installed app already contained the caret metadata patch; added guards that treat Google Docs `Document content` + degenerate focus rect as unreliable, strip zero-width-only `existing_text`, and route native-source text-only mode to full-target-image fallback instead of claiming a text-only hint. Also stopped calling `CGRequestScreenCaptureAccess()` at app launch so Screen Recording prompts happen at capture time rather than immediately after every TCC reset/relaunch.
- **Input type(s):** Latest live Google Docs source/target runs, target OCR artifacts, AX `target_metadata.json`, `caret.json`, `geometry.json`, and bundled app resources.
- **Target field type(s):** Google Docs document body used as a structured pseudo-form with labeled blank lines.
- **Outcome:** Implemented and reinstalled. Existing latest runs were not using `baseline_full_images`; they used `source_ocr_target_text_or_full_image` and `source_packet_target_ocr_packet`, so the baseline-only caret patch was not on the critical path. New guards make this failure mode explicit as `google_docs_degenerate_focus_rect` / `needs_target_image` instead of building a confident target packet around toolbar text.
- **Evidence / examples:** `app/python/target_context.py`, `app/python/source_packet.py`, `app/python/run_once.py`, `app/Blink/BlinkApp.swift`, `app/python/tests/test_target_context_hint.py`, `app/python/tests/test_source_packet.py`; local and bundled checks: `python3 -m unittest discover app/python/tests`, `python3 -m compileall app/python`, bundled `python3 -m unittest discover .../Resources/tests`, and `bash app/scripts/install_local_app.sh --reset-tcc`.
- **Decision:** Keep text-only routing conservative for Google Docs document bodies until Blink has a reliable caret/line signal there. This avoids broad wrong pastes when the active line cannot be proven.
- **Next step:** Re-test one Google Docs target run. If it now returns `[[NEEDS_REVIEW: target context needs image]]` in `source_packet_target_ocr_packet`, switch to an image-capable target mode/model for this scenario or add a separate visual-caret strategy.

## 2026-04-25 — Baseline caret-context metadata for Google Docs

- **Hypothesis:** Baseline source-image + target-image mode needs explicit AX caret context in `TARGET_METADATA_JSON` for Google Docs, where the focused AX value is the whole document and the screenshot caret is too small to disambiguate the intended blank line.
- **Setup:** Added caret-aware split rendering to `app/python/source_packet.py` behind `caret_format="split"`: `focused_field.caret`, `text_before_caret`, `text_after_caret`, and `text_selected` for selection replacement. Threaded `caret.json` into the baseline instruction builder in `app/python/run_once.py`, kept OCR/hybrid request modes on their existing metadata path, and updated the baseline prompt copy to tell the model to insert between the split fields.
- **Input type(s):** AX target metadata with `focused_value` plus `caret.json`; existing baseline field-run replay and synthetic Google-Docs-shaped unit fixtures.
- **Target field type(s):** Google Docs / WebKit contenteditable documents and ordinary text fields on the baseline full-image path.
- **Outcome:** Implemented and locally verified. Unsupported/missing caret falls back to the prior `existing_text` metadata. Offset carets window to 600 chars before and 300 chars after; `line_only` carets fall back to line-split context. Baseline skipped replay now writes caret-aware `target_metadata.prompt.json` when caret capture is present.
- **Evidence / examples:** `app/python/source_packet.py`, `app/python/run_once.py`, `app/Resources/prompt.txt`, `app/python/tests/test_source_packet.py`, `app/python/tests/test_run_once_normalize.py`; local checks: `python3 -m unittest discover app/python/tests`, `python3 -m compileall app/python`, and skipped replay bundle `.context/caret-replay/baseline-skip-replay-3/`.
- **Decision:** Keep v1 as the explicit split-key format rather than an inline marker so the request is inspectable and future prompt-format A/Bs can slot in behind `caret_format`.
- **Next step:** Dogfood the same structured Google Doc manually in baseline mode and compare each labeled blank line against the earlier noisy outputs; only revisit OCR/hybrid if the retest shows the same caret ambiguity there too.

## 2026-04-24 — Blink.app host-side profiling in run bundles

- **Hypothesis:** Mirroring Swift-side wall-clock phases into each Blink.app run bundle will make live latency investigations materially easier than relying on Python/model timings alone.
- **Setup:** Added Swift-side profiling around source capture, optional source-packet prep, target metadata/caret/screenshot capture, temp artifact prep, Python wall time, and paste insertion. Persisted the full record as `host_profile.json` beside each run, and mirrored the headline `host_*` timing keys into `run.json.timings` so Control Center can summarize them immediately.
- **Input type(s):** Blink.app live dogfood trials across baseline and source-packet request modes.
- **Target field type(s):** Any live focused text field captured by the tester app.
- **Outcome:** Every successful bundled run can now answer both "how long did the model call take?" and "how long did the live app spend before/after the model call?" without separate profiler tooling.
- **Evidence / examples:** `app/Blink/TrialCoordinator.swift`, `app/Blink/ControlCenterWindow.swift`, `docs/ARTIFACT_SCHEMA.md`, `docs/DOGFOOD_PLAYBOOK.md`.
- **Decision:** Treat `run.json` + `host_profile.json` as the default latency evidence surface for Blink.app dogfood sessions.
- **Next step:** Re-run a live dogfood session and compare the new `host_pre_python_ms`, `host_python_wall_ms`, and `host_run_target_total_ms` breakdown against the offline sweep numbers.

## 2026-04-20 — Repository initialization

- **Hypothesis:** A clean operating framework will improve experiment quality and reduce repo chaos.
- **Setup:** Added foundational repository docs and agent guidance.
- **Input type(s):** N/A
- **Target field type(s):** N/A
- **Outcome:** Repo now contains clear mission, scope, constraints, and logging format.
- **Evidence / examples:** `README.md`, `AGENTS.md`, `docs/PROJECT_BRIEF.md`, and this file.
- **Decision:** Proceed to first intelligent copy-paste manual experiment.
- **Next step:** Define experiment #1 with concrete source/target pair and evaluation criteria.


## 2026-04-20 — Manual copy-paste experiment protocol (generalized prompt; Facebook relist first scenario)

- **Hypothesis:** Adding explicit field metadata (focus, existing text, caret context) will materially reduce wrong-field and formatting errors in screenshot-only prompting.
- **Setup:** Defined a two-screenshot capture protocol (source + target), metadata schema, and a generalized response template for Gemini-assisted field filling across apps. Facebook relisting remains the first recommended manual validation scenario.
- **Input type(s):** Any on-screen source screenshot paired with a target field screenshot. Initial scenario: Marketplace listing screenshots (source) and listing form screenshots (target).
- **Target field type(s):** General form fields. Initial scenario: title, price, condition, description.
- **Outcome:** Protocol drafted; execution pending manual trials.
- **Evidence / examples:** `docs/MANUAL_COPY_PASTE_PLAYBOOK.md`.
- **Decision:** Run 10-15 single-field trials before attempting multi-field automation.
- **Next step:** Execute trials, log pass/fail by failure mode, and compare correction time to manual re-entry baseline.


## 2026-04-20 — Facebook relist manual trial #1

- **Hypothesis:** A strong visual focus indicator in the target UI may remove the need for explicit field metadata in at least some screenshot-to-field copy-paste flows.
- **Setup:** Used Facebook Marketplace listing screenshots as the source context and Marketplace create-listing form screenshots as the target context. The active target field was visibly highlighted, so no extra metadata was supplied for focus or caret state. Prompting was performed manually through Google AI Studio.
- **Input type(s):** Marketplace listing screenshots with title, price, structured attributes, and description text.
- **Target field type(s):** At least one focused listing field in the Marketplace create flow. Initial observed target included a clearly highlighted text field.
- **Outcome:** First live manual trial appears successful. The model selected the intended field correctly without additional metadata, which suggests highlighted focus state can sometimes be read directly from the UI. End-to-end interaction time was about 5 seconds, which feels too slow for a polished product even if acceptable for an early manual experiment.
- **Evidence / examples:** User-provided source and target screenshots from the Facebook Marketplace relist flow; qualitative report that the first test "seems to go well."
- **Decision:** Keep validating the screenshot-based interaction loop, but start treating latency as a core product constraint rather than a later optimization.
- **Next step:** Run additional single-field trials across title, price, condition, and description; separate model latency from tool/UI overhead where possible; note when highlighted focus is sufficient versus when metadata is still required.


## 2026-04-20 — Scratchpad trial-bundle generator

- **Hypothesis:** A disposable experiment packet generator will improve iteration speed more than further early repo structure work, while still keeping trials reusable and comparable.
- **Setup:** Added a `scratchpad/` workspace with a small Python script that packages source images, target images, optional target-context JSON, and optional annotation hints into a run folder with `prompt.txt`, `trial.json`, `trial.md`, and `preview.html`.
- **Input type(s):** Any local source/target screenshot pair or multi-image set used for manual copy-paste experiments.
- **Target field type(s):** General text-entry targets, including blank fields, partially filled fields, and cross-app writing tasks such as emailing a friend about a listing.
- **Outcome:** Scratchpad tooling added; ready for repeatable manual trials without committing to automation architecture.
- **Evidence / examples:** `scratchpad/README.md`, `scratchpad/make_trial.py`.
- **Decision:** Use the scratchpad as the default place for quick experiment packets while leaving product-facing structure minimal.
- **Next step:** Run a few real trial bundles, then decide whether target-context JSON and annotation hints should stay manual or become generated from UI metadata later.


## 2026-04-20 — Folder-based Gemini scratchpad runner with profiling

- **Hypothesis:** A no-arguments runner with fixed `source/` and `target/` folders will improve iteration speed for manual multimodal trials, while local timing plus Gemini token metadata will be enough to start profiling the workflow meaningfully.
- **Setup:** Added `scratchpad/run_gemini_trial.py`, `scratchpad/prompt.txt`, `scratchpad/settings.json`, and fixed `scratchpad/source/` and `scratchpad/target/` folders. The runner reads local images, optional target-context JSON, calls Gemini directly through the API, prints the model output, and saves a profiling record to `scratchpad/last_run.json`.
- **Input type(s):** Local screenshot sets placed into fixed source and target folders.
- **Target field type(s):** General text insertion targets, including blank fields, partially filled fields, and cross-app writing tasks.
- **Outcome:** Fast-path experiment runner added; ready for repeated manual tests with less setup friction and better latency visibility.
- **Evidence / examples:** `scratchpad/run_gemini_trial.py`, `scratchpad/settings.json`, `scratchpad/prompt.txt`, `scratchpad/README.md`.
- **Decision:** Use the folder-based runner as the default manual Gemini test loop; treat richer automation and AX-tree-derived metadata as later work.
- **Next step:** Run a few real Gemini trials, compare prompt/token/runtime patterns across scenarios, and decide which latency segment is the dominant constraint.


## 2026-04-20 — Resident Quartz hotkey profiling runner

- **Hypothesis:** A resident hotkey-driven scratchpad that reuses source context, captures compact focused-element metadata, and streams Gemini output will produce a more honest latency profile than the folder-based manual loop.
- **Setup:** Replaced the primary scratchpad runner with a Quartz event-tap hotkey loop, interactive `screencapture` source/target capture, compact AX metadata capture, streaming Gemini calls through `google-genai`, clipboard copy, persistent source state, and timestamped run directories with per-run profiling logs.
- **Input type(s):** On-demand source and target region screenshots captured from the live desktop, plus compact metadata about the focused destination element when Accessibility access is available.
- **Target field type(s):** Focused text-entry targets across apps, optimized for repeated source reuse and latency profiling rather than end-user automation polish.
- **Outcome:** Hotkey runner implemented. The scratchpad now measures queue delay, metadata capture time, screenshot time, TTFT, stream duration, model latency, end-to-end latency, and output TPS when Gemini usage metadata is present.
- **Evidence / examples:** `scratchpad/hotkey.py`, `scratchpad/run_gemini_trial.py`, `scratchpad/requirements.txt`, `scratchpad/settings.json`, `scratchpad/README.md`.
- **Decision:** Use the resident runner as the primary profiling path. Keep the packet generator as a secondary manual-experiment aid.
- **Next step:** Run live hotkey sessions under real permissions, compare repeated target runs against a fixed source snapshot, and decide whether image compression or extra metadata improves latency/accuracy tradeoffs enough to justify the added complexity.


## 2026-04-20 — Hotkey and capture-mode adjustment

- **Hypothesis:** `ctrl+shift+c` / `ctrl+shift+v` bindings and interactive window snapshots will better match copy/paste mental models and reduce capture friction compared with the initial option-key shortcuts and freeform region mode.
- **Setup:** Updated the scratchpad defaults so source capture uses `ctrl+shift+c`, target generation uses `ctrl+shift+v`, and `screencapture` defaults to interactive window mode. Also improved capture error printing so failures are easier to diagnose from the terminal.
- **Input type(s):** Live desktop windows selected through macOS window snapshot UI.
- **Target field type(s):** Focused fields whose source and destination context are easiest to capture as whole windows rather than arbitrary regions.
- **Outcome:** Tooling adjusted; ready for another live profiling pass with a more natural hotkey layout and window-based capture flow.
- **Evidence / examples:** `scratchpad/settings.json`, `scratchpad/run_gemini_trial.py`, `scratchpad/README.md`.
- **Decision:** Keep window capture as the default until real runs show it is either slower or materially less accurate than region capture.
- **Next step:** Re-run the resident runner, capture a source window with `ctrl+shift+c`, then capture a target window with `ctrl+shift+v`, and inspect the next `last_run.json` if any capture or metadata issue persists.


## 2026-04-20 — Window-first capture with region fallback

- **Hypothesis:** Starting interactive capture in window mode while automatically retrying with region selection on native window-snapshot failures will preserve the window-first workflow without blocking live profiling sessions.
- **Setup:** Updated the scratchpad capture path so `capture_mode: "window"` uses `screencapture -i -W` instead of strict `-w`, and retries once with region selection if macOS reports `could not create image from window`. Added the new fallback setting to scratchpad defaults and documentation.
- **Input type(s):** Live desktop source and target captures initiated from the resident hotkey runner.
- **Target field type(s):** Focused UI fields whose surrounding context is often easiest to capture as a whole window, but which may still require manual region selection on apps that reject native window snapshots.
- **Outcome:** Tooling updated; the next live run should be more resilient to window-capture failures while keeping the same hotkeys and overall workflow.
- **Evidence / examples:** `scratchpad/run_gemini_trial.py`, `scratchpad/settings.json`, `scratchpad/README.md`.
- **Decision:** Keep `window` as the default requested mode, but treat region fallback as part of the normal profiling path rather than as a separate mode switch.
- **Next step:** Re-run the hotkey flow, confirm whether source capture now succeeds, and inspect the next per-run `run.json` for `attempts`, `effective_capture_mode`, and fallback timing if macOS still rejects specific windows.


## 2026-04-20 — Run-log persistence hardening

- **Hypothesis:** Some live runs are succeeding far enough to produce screenshots and model output, but the JSON log writer is failing on response payload serialization, which hides the real latency and failure signals we need for profiling.
- **Setup:** Updated scratchpad log persistence to sanitize payloads before JSON serialization and to write a fallback `persistence_error` log if saving the full run record still fails.
- **Input type(s):** Any live hotkey-driven source/target run, especially Gemini responses with unusual response metadata payloads.
- **Target field type(s):** General text insertion targets across apps.
- **Outcome:** The next run should always produce a `run.json` and update `last_run.json`, even if the response payload contains non-JSON-native values.
- **Evidence / examples:** `scratchpad/run_gemini_trial.py`.
- **Decision:** Treat durable per-run logging as mandatory infrastructure for latency profiling, even before further capture or prompt tuning.
- **Next step:** Re-run one live source/target attempt and inspect the newly written `run.json` to determine whether the remaining issue is screenshot capture, API timeout, or response handling.


## 2026-04-20 — Request-side screenshot compression

- **Hypothesis:** The current PNG uploads are materially inflating end-to-end latency even when Gemini token usage is modest, so compressing request images should reduce TTFT more effectively than prompt tweaks alone.
- **Setup:** Added request-side image preprocessing to the scratchpad runner. Captured screenshots are still preserved as original PNGs, but Gemini requests now default to compressed JPEG copies with a 1600px max dimension and quality 80. The run log now records original bytes, request bytes, preprocessing timings, and the assembled output text.
- **Input type(s):** Live desktop screenshots captured through the resident hotkey runner.
- **Target field type(s):** General screenshot-to-text insertion targets across apps.
- **Outcome:** Tooling updated; the next live run should provide a clearer before/after comparison on upload-heavy latency.
- **Evidence / examples:** `scratchpad/run_gemini_trial.py`, `scratchpad/settings.json`, `scratchpad/README.md`.
- **Decision:** Keep request-side compression on by default while profiling, since it is reversible and does not alter the original captured artifacts.
- **Next step:** Re-run the same source/target scenario and compare `ttft_ms`, `model_latency_ms`, and `request.images.*.request_bytes` against the prior uncompressed run.


## 2026-04-21 — Fixture-library capture and offline sweep harness

- **Hypothesis:** Splitting live capture from offline evaluation will remove the biggest prompt-iteration bottleneck and make qualitative model comparisons much faster.
- **Setup:** Added reusable fixture capture to the resident hotkey runner, richer AX/caret/geometry/clipboard/OCR collection, root wrapper scripts, shared Gemini request helpers, and a serial sweep CLI that writes `summary.md` plus `compare.html`.
- **Input type(s):** Live source and target screenshots captured from the desktop, then replayed offline as fixture bundles.
- **Target field type(s):** Focused text-entry targets across apps, especially form fields where AX metadata and visible OCR context both help.
- **Outcome:** Tooling added; ready for the first real `fixtures x configs` qualitative sweep.
- **Evidence / examples:** `capture`, `sweep`, `scratchpad/run_gemini_trial.py`, `scratchpad/gemini_runner.py`, `scratchpad/ocr.py`, `scratchpad/eval_sweep.py`, `scratchpad/eval_configs/`.
- **Decision:** Use fixture capture as the default path for new trials and keep the sweep loop serial until actual rate limits or throughput needs justify parallelism.
- **Next step:** Capture a small Chrome-heavy fixture set, run an initial sweep, and ask Claude to fill the judging rubric in the generated `summary.md`.


## 2026-04-21 — Shared fixture pool rollout

- **Hypothesis:** Moving fixtures into a shared pool across Conductor workspaces will reduce recapture churn without breaking sweep outputs or archive bundles.
- **Setup:** Updated `.conductor/setup.sh`, `.conductor/archive.sh`, `.gitignore`, and docs; added `.conductor/migrate_fixtures.sh`; migrated the existing `kyiv` fixture corpus into `~/conductor/shared/blink/fixtures/`; ran a 9-fixture post-migration sweep with `flash-lite-low-minimal`; and dry-ran archive behavior for symlinked and forked fixture cases in isolated temp workspaces.
- **Input type(s):** Existing screenshot fixture bundles already captured in `kyiv`.
- **Target field type(s):** Mixed focused text fields captured during the 2026-04-21 fixture-library session.
- **Outcome:** Migration succeeded cleanly for all 9 fixtures. `scratchpad/fixtures` now symlinks to the shared pool, `setup.sh` re-runs idempotently, the sweep still enumerates all fixtures through the symlink, and archive bundles remain self-contained for both symlinked and forked fixture layouts.
- **Evidence / examples:** `.conductor/setup.sh`, `.conductor/archive.sh`, `.conductor/migrate_fixtures.sh`, `scratchpad/eval_sweep.py`, `scratchpad/sweeps/post-migration-relative/summary.md`, `scratchpad/sweeps/post-migration-relative/compare.html`.
- **Decision:** Keep the shared-pool workflow as the default Conductor setup and preserve fork-on-demand only for schema-incompatible experiments.
- **Next step:** Run one live `./capture` after the next manual session to confirm newly captured fixtures land directly in the shared pool under the normal hotkey flow.


## 2026-04-22 — Swift tester-app channel: Phases 0/1/4 gates

- **Hypothesis:** A second, independent deployment loop (signed Swift `.app` → bundled Python → exportable artifact bundles) can coexist with the dev research loop if bridged by a single versioned bundle schema, without touching `./capture` / `./sweep`.
- **Setup:** Implemented per `.context/attachments/plan.md` v3. Phase 0 added `docs/ARTIFACT_SCHEMA.md` (schema v1, field-by-field) and `scratchpad/field_runs/`. Phase 1 forked `app/python/gemini_runner.py` from `scratchpad/gemini_runner.py@192d8c5` and added `app/python/run_once.py`, a CLI emitting `fixture.json` + `source.png` + `target.png` + `run.json` + `output.txt` in schema-v1 shape. Phase 4 added `scratchpad/import_field_runs.py` for zip/dir import into `scratchpad/field_runs/`. Phases 2/3/5/6 scaffolded (Swift sources, XcodeGen spec, scripts) but not yet exercised end-to-end.
- **Input type(s):** Existing fixture bundle `20260421-034447-726-conductor-unknown-role` used as a source/target pair for the gate runs.
- **Target field type(s):** Schema-contract validation, not a real copy-paste trial.
- **Outcome:** Phase 0 gate — `./sweep` accepts `scratchpad/field_runs/*` as a fixture glob unchanged. Phase 1 gate — `run_once.py --skip-gemini` emits a v1 bundle to `/tmp/blink-phase1/<ts>/` that `./sweep` replays (status=ok, first chunk returned). Phase 4 gate — round-tripped: run_once → zip → `import_field_runs.py <zip>` → `./sweep --fixtures 'scratchpad/field_runs/*'` → `compare.html`/`summary.md` rendered. Phase 2 gate (live dogfood in Xcode) and Phase 6 gate (notarized external-tester run) still pending; both require build infrastructure that isn't wired up yet.
- **Evidence / examples:** `docs/ARTIFACT_SCHEMA.md`, `app/README.md`, `app/python/run_once.py`, `app/python/gemini_runner.py`, `scratchpad/import_field_runs.py`, `app/Blink/*.swift` (typechecks via `swiftc -typecheck` against the macOS 14 SDK).
- **Decision:** Land the scaffolded Swift/Xcode/sign/notarize paths so a follow-up session can run the remaining gates without re-planning. Keep the research loop untouched — no changes to `./capture`, `./sweep`, or any file outside `app/`, `docs/ARTIFACT_SCHEMA.md`, `scratchpad/field_runs/`, `scratchpad/import_field_runs.py`.
- **Next step:** Install XcodeGen locally, run `app/scripts/fetch_python.sh` → `app/scripts/build.sh`, exercise the Phase 2 dogfood gate on the dev box (hotkey → capture → paste → bundle), then thread the Phase 6 sign/notarize/DMG chain through.


## 2026-04-23 — Source-packet latency benchmark against shared fixtures

- **Hypothesis:** Caching source understanding into a reusable text packet will reduce paste-time request latency enough to offset the extra source-precompute call, especially when the same source is reused across multiple target pastes.
- **Setup:** Added `scratchpad/benchmark_source_packet.py` plus two experiment prompts for source-packet extraction and target-only paste generation. Ran the corrected benchmark over all 9 shared fixtures with `scratchpad/eval_configs/flash-lite-low-minimal.json`, comparing the current two-image baseline against: (1) source-packet extraction from the source image, then (2) a target-only request using `TARGET_IMAGE` + `TARGET_METADATA_JSON` + `SOURCE_PACKET_JSON`. The benchmark wrote per-fixture artifacts and an aggregate summary under `scratchpad/sweeps/source-packet-20260423-204225/`.
- **Input type(s):** Existing shared fixture bundles in `scratchpad/fixtures/*`, each containing `source.png`, `target.png`, and `fixture.json`.
- **Target field type(s):** Mixed focused text fields from the current Blink fixture corpus, including Conductor text areas and a Microsoft Edge text area.
- **Outcome:** The naive generic source-packet design reduced paste-time request latency, but not quality. Across 9 fixtures, the baseline average request path was `1978.94 ms`; source-packet extraction averaged `2295.71 ms`; target-only packet playback averaged `1525.83 ms`; baseline TTFT averaged `1648.25 ms`; packet TTFT averaged `1382.71 ms`; exact-match vs baseline was `0/9`; and 7/9 runs self-reported that the source packet was insufficient without the original source image. Amortized over 3 reuses the packet path was still slower than baseline (`2291.07 ms` vs `1978.94 ms`), and even at 5 reuses it only reached rough parity (`1984.98 ms` vs `1978.94 ms`).
- **Evidence / examples:** `scratchpad/benchmark_source_packet.py`, `scratchpad/source_packet_extract_prompt.txt`, `scratchpad/source_packet_target_prompt.txt`, `scratchpad/sweeps/source-packet-20260423-204225/benchmark.json`, `scratchpad/sweeps/source-packet-20260423-204225/summary.md`.
- **Decision:** Keep the source-packet direction open as a latency lever, but reject this first prompt/schema as shippable. The current packet is too generic and too lossy: it speeds up the target-time call, yet quality collapses and the upfront extraction cost is too high unless reuse is unusually high.
- **Next step:** Try a tighter packet contract that extracts only a few candidate field values plus brief style hints, then re-run the same fixture benchmark and compare both latency and exact-match rate against this first packet baseline.


## 2026-04-23 — Human gold packets for source-packet evaluation

- **Hypothesis:** A hand-authored gold packet corpus over the current shared fixtures will make it clear whether the first source-packet attempt is failing because of the schema, the extraction prompt, or both.
- **Setup:** Inspected the actual `source.png` images in all 9 shared fixtures and authored a gold packet for each one in `scratchpad/gold_source_packets.json`, keeping the same broad packet schema so the current model packets stay comparable. Added `scratchpad/compare_source_packets.py` and ran it against the corrected benchmark artifacts in `scratchpad/sweeps/source-packet-20260423-204225/`.
- **Input type(s):** Existing shared fixture bundles in `scratchpad/fixtures/*`, using the real source screenshots rather than relying on OCR alone.
- **Target field type(s):** Source-packet extraction quality only; this pass judges packet fidelity before any paste-time target routing.
- **Outcome:** The first packet prompt is substantially below a reasonable human baseline. Against the gold corpus, salient-text recall was `26/66` (`0.394`), candidate-field strict recall was `11/28` (`0.393`), loose candidate-field recall was `13/28` (`0.464`), and `can_answer_without_source_image` matched the gold judgment only `4/9` times. The worst misses were terminal-log sources and longer document sources, where the model tended to summarize chrome or metadata instead of extracting the exact visible values and failure strings that matter for paste-time decisions.
- **Evidence / examples:** `scratchpad/gold_source_packets.json`, `scratchpad/compare_source_packets.py`, `scratchpad/sweeps/source-packet-20260423-204225/gold_packet_compare.json`, `scratchpad/sweeps/source-packet-20260423-204225/gold_packet_compare.md`.
- **Decision:** Keep the gold packet corpus as the regression target for future source-packet prompt work. The current generic extraction prompt should not be iterated blindly; it needs to be tightened toward exact visible spans and better insufficiency detection, especially for terminal logs and partially visible docs.
- **Next step:** Design a v2 extraction prompt that prefers exact field/value spans over prose summaries, then rerun both the latency benchmark and the gold-packet comparison to see whether recall improves without giving back the target-time latency win.


## 2026-04-23 — Source-packet v2 prompt guided by gold packets

- **Hypothesis:** Tightening the source-packet contract around exact visible spans, explicit source kinds, and stricter insufficiency rules will materially improve packet fidelity and reduce unnecessary fallback, even if it makes extraction a bit slower.
- **Setup:** Added `scratchpad/source_packet_extract_prompt_v2.txt` and `scratchpad/source_packet_target_prompt_v2.txt`, then updated `scratchpad/benchmark_source_packet.py` to accept prompt-path overrides plus a `--max-output-tokens` override. The first v2 run at the default `512` output-token ceiling truncated 3 packet JSON responses mid-object and was discarded. The corrected run used `--max-output-tokens 2048` and wrote artifacts to `scratchpad/sweeps/source-packet-v2-20260423-213453/`, then compared the generated packets against the gold corpus with `scratchpad/compare_source_packets.py`.
- **Input type(s):** Existing shared fixture bundles in `scratchpad/fixtures/*`, using the same 9-fixture corpus as the original source-packet benchmark.
- **Target field type(s):** Mixed text-entry targets across Conductor and Microsoft Edge, plus packet-quality comparison against the human gold corpus.
- **Outcome:** Packet fidelity improved substantially, but end-to-end quality is still not good enough. On the gold-packet comparison, salient-text recall improved from `26/66` (`0.394`) to `45/66` (`0.682`), strict candidate-field recall rose from `11/28` (`0.393`) to `12/28` (`0.429`), source-kind accuracy improved from `0/9` to `8/9`, and `can_answer_without_source_image` accuracy improved from `4/9` to `6/9`. On the latency benchmark, target-only request time improved modestly relative to the first packet run (`1421.27 ms` vs `1525.83 ms`), candidate fallback count dropped from `7` to `1`, and the amortized packet path became better than the live two-image baseline by about `247 ms` at `5` reuses per source. But extraction got slower (`2730.73 ms` vs `2295.71 ms`), and exact-match vs the current two-image baseline stayed at `0/9`.
- **Evidence / examples:** `scratchpad/source_packet_extract_prompt_v2.txt`, `scratchpad/source_packet_target_prompt_v2.txt`, `scratchpad/benchmark_source_packet.py`, `scratchpad/sweeps/source-packet-v2-20260423-213453/summary.md`, `scratchpad/sweeps/source-packet-v2-20260423-213453/gold_packet_compare.json`, `scratchpad/sweeps/source-packet-v2-20260423-213453/gold_packet_compare.md`.
- **Decision:** Keep the v2 packet contract as the better extraction baseline, especially for source-kind classification and fallback gating, but do not treat it as shippable. The remaining weakness is not generic packet detection anymore; it is mapping longer visible source passages into the exact candidate fields and paste outputs we want.
- **Next step:** Move to a more target-aware packet design: either extract a small fixed set of field candidates per source class (for example, listing fields vs chat instruction blocks vs doc answer blocks) or run a second lightweight packet-normalization step that rewrites the exact visible spans into paste-oriented candidate fields before the target-only call.


## 2026-04-23 — OCR-style source packet as plain text instead of JSON

- **Hypothesis:** If the cached source packet is biased toward OCR-like exact visible text instead of a structured JSON summary, the model will preserve more reusable source content while still reducing paste-time latency on the target-only path.
- **Setup:** Added `scratchpad/source_packet_extract_prompt_v3_ocr.txt` and `scratchpad/source_packet_target_prompt_v3_ocr.txt`, then updated `scratchpad/benchmark_source_packet.py` and `scratchpad/compare_source_packets.py` to support a plain-text packet mode via `--packet-format text`. The extractor now emits a compact text packet with ordered sections like `SOURCE_KIND`, `SCENE`, `EXACT_TEXT`, `TEXT_BLOCKS`, `LAYOUT_HINTS`, `LIMITS`, and `COMPLETENESS`, and the target-time prompt consumes that text directly instead of JSON. Ran the benchmark over the same 9 shared fixtures with `scratchpad/eval_configs/flash-lite-low-minimal.json`, writing artifacts to `scratchpad/sweeps/source-packet-v3-ocr-20260423-215930/`, then compared the generated text packets against the gold corpus.
- **Input type(s):** Existing shared fixture bundles in `scratchpad/fixtures/*`, using the same 9-fixture source/target image corpus as the earlier packet runs.
- **Target field type(s):** Mixed text-entry targets across Conductor and Microsoft Edge, plus source-packet extraction quality compared against the human gold corpus.
- **Outcome:** The OCR-text packet materially improved source fidelity and reuse economics, but not final paste quality. On the gold comparison, salient-text recall rose to `55/66` (`0.833`), loose candidate-field recall rose to `18/28` (`0.643`), and source-kind accuracy reached `9/9`. Extraction also got faster than the v2 JSON packet (`2343.48 ms` vs `2730.73 ms`). On the latency benchmark, target-only packet playback averaged `1454.85 ms`, still much faster than the live two-image baseline at `2463.73 ms`, and the amortized packet path beat baseline by about `540 ms` at `5` reuses per source. But exact-match vs baseline remained `0/9`, and the plain-text packet became less conservative about insufficiency: candidate fallback count dropped to `0`, while `can_answer_without_source_image` agreement with the gold judgment fell to `5/9`.
- **Evidence / examples:** `scratchpad/source_packet_extract_prompt_v3_ocr.txt`, `scratchpad/source_packet_target_prompt_v3_ocr.txt`, `scratchpad/benchmark_source_packet.py`, `scratchpad/compare_source_packets.py`, `scratchpad/sweeps/source-packet-v3-ocr-20260423-215930/summary.md`, `scratchpad/sweeps/source-packet-v3-ocr-20260423-215930/gold_packet_compare.json`, `scratchpad/sweeps/source-packet-v3-ocr-20260423-215930/gold_packet_compare.md`.
- **Decision:** Keep the OCR-text packet as the best extraction-oriented source-packet variant so far. It is noticeably better than the JSON packets at preserving exact source content and may be the right cached representation if the paste-time model is expected to synthesize structure itself. Do not ship it yet: the current target-time prompt is still not turning that improved packet fidelity into correct paste outputs, and the completeness signal needs to become more conservative again.
- **Next step:** Either tighten the `COMPLETENESS` rule so long docs and partial screenshots self-report insufficiency more often, or pair this OCR-text packet with a second lightweight paste-time prompt that first selects the exact source spans to reuse before synthesizing the final paste.


## 2026-04-24 — Target-side OCR packet and focused-crop benchmark

- **Hypothesis:** On top of the cached OCR-style source packet, replacing the full target image with either (a) a local OCR plus AX packet or (b) a focused crop around the likely active field can reduce target-time latency without giving up too much destination-field signal.
- **Setup:** Added `scratchpad/benchmark_target_context.py`, `scratchpad/target_context_prompt_ocr.txt`, and `scratchpad/target_context_prompt_crop.txt`. The benchmark reuses `source_packet_extract_prompt_v3_ocr.txt` for source extraction, then compares four target-side modes per fixture: source packet + full target image, source packet + local target OCR packet, source packet + focused target crop, and source packet + OCR packet with routing fallback to the full target image when the OCR packet self-reports insufficient target context. The target OCR packet is built locally from Vision OCR blocks plus AX metadata, with an OCR-anchor fallback that tries to localize the focused field from visible text already in the target field when AX geometry is unusable. The first run at `scratchpad/sweeps/target-context-20260424-101945/` had a timing bug: `request_build_ms` was measured after the model call for the OCR and crop variants, so that run should be ignored. The corrected run wrote artifacts to `scratchpad/sweeps/target-context-20260424-102428/`.
- **Input type(s):** Existing shared fixture bundles in `scratchpad/fixtures/*`, using the same 9-fixture source/target image corpus as the source-packet benchmarks.
- **Target field type(s):** Mixed text-entry targets across Conductor and Microsoft Edge, including fixtures with missing focused bounds, fixtures with visible existing target text, and fixtures where the focused field could be localized from OCR anchors.
- **Outcome:** The corrected benchmark shows a real target-side latency win for the OCR packet, but not a quality win yet. Across 9 fixtures, the current two-image baseline averaged `1517.39 ms`; source-packet extraction averaged `1900.33 ms`; source packet + full target image averaged `1237.31 ms`; source packet + target OCR packet averaged `1098.52 ms`; source packet + focused crop averaged `1431.04 ms`; and the OCR-or-full-image fallback route averaged `1198.48 ms`. Local OCR averaged `366.09 ms` per target, while the full-target-image path spent only `52.46 ms` on target image preparation; the OCR packet still won on target-only latency because the remote model call shrank materially (`716.89 ms` average model latency vs `1184.28 ms` for the full target image, and `581.45 ms` average TTFT vs `1009.49 ms`). The crop path did not pay off: its build stage averaged `248.95 ms`, and even with fewer image tokens it remained slower than the full-target-image path. Quality remains unresolved. Exact-match vs the original two-image baseline was `0/9` for every target variant, and even against the source-packet + full-target-image path the pure OCR target packet matched only `0/9` fixtures. The OCR packet also returned `[[NEEDS_REVIEW: target context needs image]]` on `4/9` fixtures, all of which had missing `focused_bounds`.
- **Evidence / examples:** `scratchpad/benchmark_target_context.py`, `scratchpad/target_context_prompt_ocr.txt`, `scratchpad/target_context_prompt_crop.txt`, `scratchpad/sweeps/target-context-20260424-102428/summary.md`, `scratchpad/sweeps/target-context-20260424-102428/benchmark.json`, `scratchpad/sweeps/target-context-20260424-102428/20260421-140159-935-conductor-axtextarea/target_ocr_packet.txt`, `scratchpad/sweeps/target-context-20260424-102428/20260421-200834-043-microsoft-edge-axtextarea/target_ocr_packet.txt`.
- **Decision:** Keep the OCR target packet as a promising latency lever, but do not treat it as ready for product routing. The latency result is encouraging: once source packets are in place, a local OCR packet can beat the full target image on target-only latency. The current packet format and prompt are still too lossy and too conservative in the wrong places, especially when focused bounds are missing. The focused-crop path is not the next bet; it is slower than the OCR packet and usually slower than the full target image once crop-building overhead is included.
- **Next step:** Iterate on the target OCR packet rather than the crop path. Tighten the packet around the exact text nearest the focused field, reduce irrelevant neighboring OCR spans, and add a clearer routing rule for missing `focused_bounds` so the OCR-or-full-image fallback path only uses the OCR packet when AX plus OCR evidence is actually strong.


## 2026-04-24 — Source-side Vision OCR inspection before packet integration

- **Hypothesis:** Running local Vision OCR directly over source screenshots, then postprocessing it with simple deterministic grouping, will preserve more literal source content than the current model-extracted packet path while making sidebar / toolbar noise directly inspectable.
- **Setup:** Added `scratchpad/benchmark_source_ocr.py` as a scratchpad-only experiment runner. It accepts source image or run-bundle globs, runs local Vision OCR, writes raw block artifacts plus deterministic postprocessed views (`ocr.filtered.json`, `ocr.paragraphs.json`, `ocr.sections.json`, `ocr.packet.txt`), and renders `preview.html` overlays per source. Ran it over 12 recent Blink app run bundles under `~/Library/Application Support/Blink/runs/`, writing artifacts to `scratchpad/sweeps/source-ocr-20260424-1543/`.
- **Input type(s):** Recent Blink app source screenshots, including repeated Google Doc startup-application captures and a Cloudflare dashboard page.
- **Target field type(s):** None; this was source-side OCR inspection only.
- **Outcome:** The experiment was useful immediately. Across 12 sources, raw Vision OCR averaged `51.92` blocks / `2021.08` chars per screenshot; the simple dominant-column filter reduced that to `31.67` blocks / `1851.58` chars on average, dropping about `20.25` blocks while retaining most document text. On the Google Doc captures, the filtered packet usually preserved the major content sections (`description`, `team`, `other information`, `founder profile`) and dropped most browser/sidebar chrome; for example, run `20260424-150813-405` kept `1938/2176` chars after filtering. On the noisiest Cloudflare dashboard case (`20260424-144133-644`), the filter dropped `42/58` blocks and cut retained chars to `538/1050`, successfully keeping the main registration cards while shedding most left-nav noise. The remaining failure mode is visible selection/UI residue: in the selected-text Google Doc case (`20260424-150934-843`), the filtered packet still leaked `*/ Refine 8G` into the final grouped section, so the current grouping is good enough for inspection but not yet clean enough for product use.
- **Evidence / examples:** `scratchpad/benchmark_source_ocr.py`, `scratchpad/sweeps/source-ocr-20260424-1543/summary.md`, `scratchpad/sweeps/source-ocr-20260424-1543/index.html`, `scratchpad/sweeps/source-ocr-20260424-1543/20260424-144133-644/preview.html`, `scratchpad/sweeps/source-ocr-20260424-1543/20260424-150813-405/ocr.packet.txt`, `scratchpad/sweeps/source-ocr-20260424-1543/20260424-150934-843/ocr.packet.txt`.
- **Decision:** Keep source-side Vision OCR exploration open and keep it outside the product path for now. The experiment validated that local OCR is a strong literal evidence source, but it also showed that naive grouping still leaks UI affordances and selection chrome. Treat the current runner as an inspection tool, not yet as a packet generator for the shipping app.
- **Next step:** Expand the inspection corpus with a few more non-doc source types, then tighten the deterministic grouping around header/body separation and explicit chrome dropping (especially selection toolbars) before comparing a Vision-OCR packet against the current model-extracted source packet on the same sources.


## 2026-04-24 — Cross-model bake-off on the v3.1 source-packet extraction prompt

- **Hypothesis:** Some non-Gemini model (Claude Haiku 4.5, Qwen-3-VL-30b ± thinking, Kimi K2.5, Llama-4-Scout, GPT-5 mini) or a different Gemini variant (2.5 Flash Lite, 3 Flash, Flash Lite high-resolution) can match or beat Gemini 3.1 Flash Lite preview on v3.1 extraction quality (salient recall, source-kind accuracy, can_answer accuracy, candidate-field loose recall) and/or extraction latency.
- **Setup:** Built `scratchpad/bench_extract_cross_model.py` — a single-image extraction harness that loads each `scratchpad/eval_configs/*.json` config through the existing `providers/` dispatch layer (existing `benchmark_source_packet.py` is hard-coded Gemini-only; existing `eval_sweep.py` is the legacy two-image sweep), writes per-fixture `source_packet.txt` outputs, then scores via `compare_source_packets.py`. Ran v3.1 extraction prompt across 12 configs × 9 fixtures with `--max-output-tokens 2048` overriding every config's per-config cap (several configs ship with `512`/`768`) so each model gets equal headroom for fair comparison; this means cost is not faithful to any individual config's official cap. Sweep dir: `scratchpad/sweeps/v3-1-cross-model-20260424-1750/`.
- **Input type(s):** The existing 9-fixture corpus (Conductor chats, AX-textarea forms, marketplace listing, terminal log) under `scratchpad/fixtures/`.
- **Target field type(s):** None. Source-side extraction only — no target image is sent.
- **Outcome:** Five distinct findings, ranked by significance.
  1. **`flash-lite-high-minimal` strictly dominates the current `flash-lite-low-minimal` baseline.** Same Gemini 3.1 Flash Lite preview model, but `MEDIA_RESOLUTION_HIGH` instead of `LOW`. Salient recall went from `64/66` to `65/66` (`+1`), source-kind from `8/9` to `9/9` (`+1`), candidate-field loose recall from `19/28` to `20/28` (`+1`), can_answer held at `6/9`. Latency cost: `+1220 ms` mean (`2128 ms` → `3348 ms`). For the production extractor where extraction is amortized over reuse, this is a clear win.
  2. **`qwen3-vl-30b-thinking` is the only model that nails the chat-completeness gap.** can_answer accuracy `8/9` (`0.889`), beating every Gemini variant including the v3.1-baseline `6/9`. The Conductor-chat fixtures where v3.1 misclassifies "messages above visible top" as `sufficient` are exactly where this model wins. Cost is severe: `~36 s` mean extraction latency. Practical reading: explicit reasoning budget (not just prompt wording) is what closes the chat-completeness gap; worth a follow-up to test thinking-on Gemini variants on the same metric.
  3. **`gemini-3-flash` hit a confusing can_answer regression.** Quality on the literal-content metrics is tied for best (salient `65/66`, source-kind `9/9`, loose `20/28`), but can_answer collapsed to `1/9` — even worse than refined-v3 (`2/9`). The newer model appears to over-confidently mark every fixture `sufficient`. Not ready for use without prompt re-tuning specific to it.
  4. **`claude-haiku-4.5-openrouter` clean source-kind but slow.** `9/9` source-kind, `63/66` salient (slight regression vs baseline), `5/9` can_answer, but `~10 s` mean latency makes it impractical for the live path.
  5. **Kimi K2.5 routing is broken across both providers tested.** `kimi-k2.5-cloudflare` streams 2052 chunks but emits zero `delta.content` (likely puts content in a non-standard streaming field; `finish_reason: length`). `kimi-k2.5-openrouter-baseten` 429-rate-limited on every fixture. Both ship as `0/66` salient — confirmed harness limitation for Cloudflare path, real upstream issue for OpenRouter/BaseTen path. Not blocking.
  6. **`llama-4-scout-groq` is the latency winner** (`1867 ms` mean, beating baseline by `~261 ms`) but pays for it in candidate-field loose recall (`16/28`, worst non-broken config).
- **Evidence / examples:** `scratchpad/sweeps/v3-1-cross-model-20260424-1750/summary.md`, `scratchpad/sweeps/v3-1-cross-model-20260424-1750/summary.json`, per-config `gold_packet_compare.md` files, and per-fixture `source_packet.txt` / `run.json` artifacts. Smoke-test reproduction of the v3.1 baseline (salient `64/66`, source-kind `8/9`, loose `19/28`, can_answer `6/9`) is at `scratchpad/sweeps/v3-1-cross-model-smoke/`.
- **Decision:** Promote `flash-lite-high-minimal` as the new default for v3.1 extraction (strict quality win at +1.2 s latency cost, amortized over reuse). Hold `qwen3-vl-30b-thinking` as a candidate for fixing the 3-of-9 chat can_answer gap, but not in the production path until thinking-on Gemini variants have been tested on the same chat fixtures (which is a much smaller follow-up). Do not promote `gemini-3-flash` despite its quality numbers — the can_answer regression to `1/9` is a real product hazard.
- **Next step:** Two follow-ups. (1) Run a small thinking-on Gemini sweep (Gemini 3.1 Flash Lite + thinking_budget non-zero, plus a Gemini 3 Flash with thinking) against the same 9 fixtures and check whether the chat can_answer score moves toward Qwen-thinking's `8/9` — if yes, that's a cheaper fix than swapping providers. (2) Investigate the Kimi-Cloudflare empty-stream issue — the model may be emitting to `delta.reasoning_content` or similar; if so, the OpenAI-SDK adapter could be extended once and unblock that route for any reasoning model. Out of scope for this experiment but worth a small ticket.


## 2026-04-25 — Split extractor vs paste model

- **Hypothesis:** Routing the source-packet extract (Stage A, image input) and the paste-time generation (Stage B, text only when using `source_packet_target_ocr_packet`) to *different* providers lets us pair a strong vision model (Gemini 3.1 Flash Lite) with a fast text-only paste model (e.g. Groq `llama-3.3-70b-versatile`), halving Stage B latency without losing source-image quality.
- **Setup:** Reshaped `~/.blink/runtime-config.json` from v1 (single `selected_provider_preset_id` + `model`) to v2 (`extractor` + `paste` `ProviderModelSelection` rows), with transparent migration from v1 on first read. Control Center now renders two rows ("Source packet extractor", "Paste-time model") with their own preset/model pickers. The Python runtime resolves two settings dicts and memoizes one runtime per role; routing follows: Stage A (`build_source_packet`) → extractor; baseline / native-OCR single-call modes → extractor (extractor "owns the source-image path"); two-call paste sites (`run_source_packet_target_full_image` / `_ocr_packet`) → paste. v1 fallbacks preserve `./sweep` replay of historic bundles. `run.json.runtime` is reshaped to expose `runtime.extractor.{model,provider_preset_id,base_url}` and `runtime.paste.{...}` (no `schema_version` bump per `docs/ARTIFACT_SCHEMA.md` Rule 2).
- **Input type(s):** Existing live-capture flow; this change is pure plumbing — no new fixtures.
- **Target field type(s):** Unchanged.
- **Outcome:** Implemented; quality / latency measurement still TODO. Repro of the original failure (Groq llama-3.3-70b for both stages on `source_packet_target_ocr_packet`) now fails fast in Stage A (image-rejection from a text-only model) — the failure mode this split is designed to resolve. The fix path (Gemini extractor + Groq paste) is now expressible in the UI and runtime; verifying the latency / quality gain is the next step.
- **Evidence / examples:** `app/Blink/RuntimeConfigStore.swift`, `app/Blink/ControlCenterWindow.swift`, `app/python/run_once.py`, `app/python/prepare_source.py`.
- **Decision:** Ship the split as the default config shape (v2). All existing v1 configs migrate to v2 with both rows seeded identically, so the behavior change is opt-in by editing the second row.
- **Next step:** Capture a small bake-off: Gemini-only baseline vs Gemini-extractor + Groq-llama-paste on `source_packet_target_ocr_packet` across the 9-fixture corpus, comparing end-to-end paste latency and extraction-quality stability.


## 2026-04-25 — Paste-latency stopwatch, stage timings, and ⌃⇧C pre-warmed Python worker

- **Hypothesis:** (1) Surfacing per-paste latency and per-stage timings makes the dominant cost localizable per fixture rather than averaging over noisy field runs. (2) Speculatively spawning a `run_once.py --wait-on-stdin` worker at ⌃⇧C source-prep time eliminates Python cold-start (~200–300 ms) on the user-visible ⌃⇧V paste path.
- **Setup:** `FeedbackCenter` gained a `StopwatchHandle` API (start/update/stop) that adds a third monospaced-digit `NSTextField` to the existing notification panel and refreshes elapsed time at 30 Hz; `TrialCoordinator` swaps the paste-flow `notify` calls for stopwatch ones, freezing the value and dismissing 1.2 s after success / failure. `PythonRunner.startWarmWorker` spawns the resident Python with stdin piped in, waits up to 5 s for a `READY <pid>` line on stdout, and returns a handle the coordinator stashes alongside the prepared source. On ⌃⇧V the coordinator hands the handle to `runOnce`, which writes the JSON args dict to stdin and reads pasted text from the worker's stdout. A new ⌃⇧C kills any leftover unconsumed worker; on any error reading from a worker, `runOnce` falls back to a fresh spawn. Workers self-time-out at 30 s (`select` on stdin). Both `google.genai` and `openai` SDKs are eagerly imported in the worker so a Groq-paste invocation does not pay first-import latency. `run.json` gained a `timings.{python_startup_ms, target_capture_ms, target_ocr_ms, source_packet_build_ms, source_packet_reused, via_warm_worker}` block — additive only. `app/scripts/install_local_app.sh` runs `python -m compileall app/python` so the cold-spawn fallback path also avoids per-launch parser work.
- **Input type(s):** Existing live capture flow.
- **Target field type(s):** Unchanged.
- **Outcome:** Implemented; in-the-wild numbers still TODO. Recent field runs averaged ~1.7–2.1 s end-to-end on `source_packet_target_ocr_packet`, ~820–1320 ms of which was the model call. The stopwatch makes the residual ~370–1260 ms (capture + Vision OCR + Python cold-start + clipboard + ⌘V) directly observable per paste. The warm worker should remove ~200–300 ms of that on hits; misses (no source set, >30 s pause) fall back transparently.
- **Evidence / examples:** `app/Blink/FeedbackCenter.swift`, `app/Blink/PythonRunner.swift`, `app/Blink/TrialCoordinator.swift`, `app/python/run_once.py`.
- **Decision:** Ship as the default for the tester app; no kill switch (warm-worker failure is silently soft-fallback).
- **Next step:** Capture a few field runs back-to-back, compare `timings.via_warm_worker == true` vs `false` on the same source, and verify the expected ~200–300 ms shave. If that holds, evaluate whether `python_startup_ms`, `target_capture_ms`, or `target_ocr_ms` is the next-largest non-model contributor and target it.


## 2026-04-25 — Dogfood fixes for Flash Lite errors, paste stopwatch latency, and YC field disambiguation

- **Hypothesis:** Three small fixes will remove the current dogfood blockers: avoid sending `thinkingLevel` to Gemini 2.5 Flash Lite, stop counting clipboard-restore delay as user-visible insertion time, and add a focused-field OCR label hint to text-only target packets.
- **Setup:** Added a narrow Gemini thinking-config compatibility guard for `gemini-2.5-flash-lite`, moved `Inserter` success completion to immediately after Cmd+V synthesis while keeping delayed clipboard restore, and threaded `focused_label_hint` from target OCR geometry into `source_packet_target_text_only` prompts. The hint starts from OCR blocks immediately above or left of the focused rect and only accepts label-like text ending in `?`, `:`, or `*`.
- **Input type(s):** Recent YC dogfood run analysis plus unit-test fixtures that mimic a YC form with multiple question labels and blank text areas.
- **Target field type(s):** Gemini Direct paste/extractor configs, macOS clipboard insertion, and text-only OCR target routing for web form text areas.
- **Outcome:** Implemented. Local tests pass: `python3 -m unittest discover app/python/tests`, `scratchpad/.venv/bin/python -m unittest discover scratchpad/tests`, and `bash app/scripts/install_local_app.sh --reset-tcc`. The canonical app was rebuilt, installed to `~/Applications/Blink.app`, TCC was reset for `com.blink.tester.Blink`, and the app relaunched.
- **Evidence / examples:** `app/python/gemini_runner.py`, `app/Blink/Inserter.swift`, `app/python/target_context.py`, `app/python/source_packet.py`, `app/python/run_once.py`, `app/Resources/target_text_only_prompt.txt`, `app/python/tests/test_gemini_thinking_config.py`, `app/python/tests/test_target_context_hint.py`.
- **Decision:** Ship all three fixes together. Keep the thinking compatibility guard intentionally narrow to `gemini-2.5-flash-lite` for this pass, then expand only when dogfood evidence or current provider docs require it.
- **Next step:** Dogfood the YC cofounder field again and verify `host_insert_ms < 50 ms`, no Flash Lite `thinkingLevel` 400s, and `run.json.target_context.focused_label_hint` matches the focused question.


## 2026-04-25 — Model parameter compatibility probe across all preset/model combos

- **Hypothesis:** The single `DEFAULT_SETTINGS` dict in `app/python/run_once.py` blanket-applies `thinking_level: MINIMAL` and `media_resolution: MEDIA_RESOLUTION_LOW` to every (provider, model) combo. Some combos must be rejecting these params silently or with HTTP 400. We need a comprehensive matrix before adding a denylist or per-model parameter routing.
- **Setup:** Wrote `scratchpad/probe_model_capabilities.py` — a runner that loops over every `(preset, suggested_model)` pair from `app/Resources/provider_presets.json` and fires four 64-token probes per combo: `text_default` (baseline params), `image_default` (text + tiny 32x32 PNG), `text_no_thinking` (drop `thinking_level`), `image_no_thinking`. Reuses the production `model_runner.generate_completion` so the request shape matches what `run_once.py` would send. Probe artifacts: `scratchpad/sweeps/model-capability-probe-20260425-153623/{results.json, summary.md}`.
- **Input type(s):** Synthetic — the same trivial `"Reply OK."` text + a 32x32 black PNG for every combo. The point is API-level parameter acceptance, not generation quality.
- **Target field type(s):** None.
- **Outcome:** 12 of 14 combos tested (3 OpenAI Responses combos skipped — no `OPENAI_API_KEY` in `~/.blink/.env`). Five distinct findings:
  1. **Every Gemini 2.5 model rejects `thinking_level`**, not just `gemini-2.5-flash-lite` as the dogfood audit suggested. `gemini-2.5-flash-lite`, `gemini-2.5-flash`, and `gemini-2.5-pro` all return `400 INVALID_ARGUMENT — "Thinking level is not supported for this model."` Only `gemini-3.1-flash-lite-preview` accepts `thinking_level` natively. The fallback path in `app/python/gemini_runner.py:238–247` (which would send `thinking_budget: 0` for `MINIMAL`) is dead code today because the installed `google-genai` SDK exposes `thinking_level` on `types.ThinkingConfig`, so the `if "thinking_level" in thinking_fields` branch always wins. The right routing is by model family: Gemini 3.x → `thinking_level`, Gemini 2.5 Flash/Flash Lite → `thinking_budget` with `MINIMAL=0`, Gemini 2.5 Pro → `thinking_budget` with `MINIMAL=128`, anything else → omit.
  2. **`google/gemini-2.5-flash-lite` works fine through OpenRouter** even though the same model fails directly through `gemini-direct`. OpenRouter sanitizes/translates the params before forwarding. So the failure is provider-shaped, not model-shaped — OpenRouter is a viable workaround for any Gemini-thinking incompatibility.
  3. **Groq's `llama-3.3-70b-versatile` rejects images** with `Error code: 400 - {'error': {'message': 'messages[1].content must be a string', ...}}` — confirms the v2 plan's repro case. The detection rule is the model passing `text_*` probes but failing `image_*` probes. Worth surfacing as a `supports_vision: false` capability flag on the preset row so users can't pick it as the **extractor** by mistake.
  4. **Two combos stream chunks but emit empty `output_text`**: `openai/gpt-5-mini` via OpenRouter on the image probe, and `@cf/moonshotai/kimi-k2.5` via Cloudflare on the image probe. Status reads `ok` (no API error) but `output_text_length: 0`. This matches the "Kimi-Cloudflare empty-stream issue" already noted in the 2026-04-24 cross-model bake-off — likely the model emitting to `delta.reasoning_content` instead of `delta.content`. Independent fix in `model_runner._generate_openai`'s chat-completions stream loop.
  5. **`openai-responses` preset is dead in current setup** — no `OPENAI_API_KEY` in `~/.blink/.env`. Either drop the preset from `provider_presets.json` until a key arrives, or document the omission. OpenRouter exposes `openai/gpt-5-mini` and other OpenAI models through its `chat_completions` adapter, so the preset isn't strictly required.
- **Evidence / examples:** `scratchpad/probe_model_capabilities.py`, `scratchpad/sweeps/model-capability-probe-20260425-153623/summary.md`, `scratchpad/sweeps/model-capability-probe-20260425-153623/results.json`. Specific failure strings:
  - Gemini 2.5 family: `"400 INVALID_ARGUMENT. {'error': {'code': 400, 'message': 'Thinking level is not supported for this model.', 'status': 'INVALID_ARGUMENT'}}"`
  - Groq llama-3.3-70b on image: `"Error code: 400 - {'error': {'message': 'messages[1].content must be a string', 'type': 'invalid_request_error', 'param': 'messages[1].content'}}"`
- **Decision:** The fix is two-track and small. Track 1: rewrite the Gemini thinking-config builder to dispatch by model name prefix (`gemini-3.*` → `thinking_level`, `gemini-2.5-flash*` → `thinking_budget=0` for MINIMAL, `gemini-2.5-pro` → `thinking_budget=128` for MINIMAL). Track 2: annotate each model in `provider_presets.json` with a `supports_vision` flag (`true` by default; only `groq-chat:llama-3.3-70b-versatile` is `false` today) and gate the **extractor** Control Center picker so vision-incompatible models are visibly disabled or warning-flagged when paired with a request_mode that requires image input.
- **Next step:** Capture these as `.context/attachments/plan-v3-model-capabilities.md` and ship Track 1 first (it unblocks four of the five suggested Gemini paste models). Track 2 is a smaller UI change but requires deciding whether to auto-disable or just warn — defer until Track 1 lands.


## 2026-04-25 — Per-model Gemini thinking routing and extractor vision warning

- **Hypothesis:** Routing Gemini thinking params by model family and warning on text-only extractor selections will make the Control Center's suggested model combos safer before the user spends a live copy/paste cycle.
- **Setup:** Replaced the SDK-field probe in `app/python/gemini_runner.py` with model-family dispatch: Gemini 3.x sends `thinking_level`, Gemini 2.5 Flash/Flash Lite sends `thinking_budget` with `MINIMAL=0`, Gemini 2.5 Pro sends `thinking_budget` with `MINIMAL=128`, and older/unknown Gemini models omit thinking config. Added `supports_vision` metadata plus a `model_overrides` entry for `groq-chat:llama-3.3-70b-versatile`, then surfaced a Control Center warning when the extractor selection is text-only and the active request mode needs an image-capable extractor.
- **Input type(s):** Production provider preset metadata and the 2026-04-25 model capability probe findings.
- **Target field type(s):** Runtime model selection, not a paste-quality trial.
- **Outcome:** Implemented. The first post-fix full probe (`scratchpad/sweeps/model-capability-probe-20260425-154804/`) showed Flash and Flash Lite fixed but exposed `gemini-2.5-pro` rejecting `thinking_budget=0`; after mapping Pro `MINIMAL` to `128`, the full probe at `scratchpad/sweeps/model-capability-probe-20260425-155238/` reports all `gemini-direct` probes as `ok`. Remaining expected failures are Groq `llama-3.3-70b-versatile` image probes; OpenAI Responses remains skipped for missing `OPENAI_API_KEY`. Local Python tests and `bash app/scripts/install_local_app.sh --reset-tcc` pass.
- **Evidence / examples:** `app/python/gemini_runner.py`, `app/python/tests/test_gemini_thinking_config.py`, `app/Resources/provider_presets.json`, `app/Blink/RuntimeConfigStore.swift`, `app/Blink/ControlCenterWindow.swift`, `scratchpad/sweeps/model-capability-probe-20260425-155238/summary.md`.
- **Decision:** Warn rather than auto-disable text-only extractor models because `source_ocr_target_text_or_full_image` can intentionally avoid source-image extraction.
- **Next step:** Dogfood the Control Center warning manually: Groq `llama-3.3-70b-versatile` should warn in source-packet modes and clear in `source_ocr_target_text_or_full_image`.
