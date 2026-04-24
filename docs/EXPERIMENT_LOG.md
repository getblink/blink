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
