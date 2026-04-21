# Experiment Log

Use this file to keep a durable record of what was tried, what worked, and what did not.

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
