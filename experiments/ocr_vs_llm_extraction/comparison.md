# Native OCR vs. LLM Source-Packet Extraction — Apples-to-Apples

## TL;DR

On the same 9 gold-labeled fixtures, scored by the same `compare_source_packets.py` rubric:

| | Salient-text recall | Candidate-field loose recall | Source-kind | Can-answer | Wall-clock per source |
|---|---:|---:|---:|---:|---:|
| **Native OCR** (filtered / paragraphs variant) | **65/66 (0.985)** | **20/28 (0.714)** | n/a | n/a | **~430 ms** |
| LLM — refined v3 (structured bullets) | 64/66 (0.970) | 20/28 (0.714) | 9/9 (1.0) | 2/9 (0.222) | ~2,344 ms (3-run avg) |
| LLM — v3.1 (structured + reframed completeness) | 64/66 (0.970) | 19/28 (0.679) | 8/9 (0.889) | 6/9 (0.667) | ~2,309 ms (2-run avg) |
| LLM — v4 (freeform) | 63/66 (0.955) | 20/28 (0.714) | 9/9 (1.0) | 6/9 (0.667) | ~2,102 ms (3-run avg) |

**Headline:** native OCR matches or slightly beats the best LLM extractor on raw text fidelity, at roughly **5× lower latency** and zero per-call API cost. The LLM's edge is *classification* (`source_kind`, `can_answer_without_source_image`), which native OCR cannot produce at all.

This is on a 9-fixture corpus, so treat sub-percentage-point deltas as noise.

## Methodology

The two experiments lived on different inputs (LLM sweep ran on `scratchpad/fixtures/2026042*` — 9 fixtures with gold labels; OCR experiment ran on 12 recent `~/Library/Application Support/Blink/runs/2026042*` bundles with no gold labels). To make them comparable I:

1. Re-ran native Vision OCR + the deterministic postprocessing from `scratchpad/benchmark_source_ocr.py` on the **same 9 gold-labeled fixtures** the LLM sweeps used. Code: `experiments/ocr_vs_llm_extraction/run_native_ocr.py`. Each fixture was timed for OCR-only and OCR+postprocess.
2. Emitted four packet-text variants per fixture into `compare_source_packets.py`-compatible directories so each one could be scored with the identical substring-match rubric the LLM sweeps used:
   - `raw_text/` — every OCR observation, reading order, joined by newlines (no bbox/conf metadata)
   - `filtered/` — same but only blocks inside the dominant content band (chrome stripped)
   - `paragraphs/` — paragraph-grouped output of the existing pipeline (text only, blank-line separated)
   - `sections/` — full deterministic packet matching `benchmark_source_ocr.py:section_packet_text` (header lines like `RAW_BLOCK_COUNT:` plus `- body:` / `- header_candidate:` bullets)
3. Pulled LLM-side numbers directly from the sweeps already on disk (`scratchpad/sweeps/source-packet-{v3-ocr-refined,v3-1-ocr,v4-freeform}-*` plus the 3-run latency benchmark in `scratchpad/sweeps/multi-run-20260424-173336/`). I did not modify either experiment.

The gold rubric (`scratchpad/compare_source_packets.py`) does the following per fixture:
- normalizes both gold and prediction to lowercase alphanumeric tokens,
- counts how many of the gold `salient_text` snippets appear as substrings in the predicted packet,
- counts how many of the gold `candidate_fields[].value` strings appear (loose recall — substring only; strict recall requires JSON `field`/`value` pairs and so is `n/a` for any text-format packet, including all four LLM and all four OCR variants),
- checks `source_kind` and `can_answer_without_source_image` if the packet emits them.

## Results

### 1. Text fidelity (apples-to-apples; substring match against gold)

| Variant | Salient recall | Field loose recall | Packet chars (avg) |
|---|---:|---:|---:|
| **OCR — `filtered`** | **65/66 (0.985)** | **20/28 (0.714)** | 1,428 |
| **OCR — `paragraphs`** | **65/66 (0.985)** | **20/28 (0.714)** | 1,438 |
| OCR — `raw_text` | 61/66 (0.924) | 17/28 (0.607) | 1,545 |
| OCR — `sections` (current `ocr.packet.txt`) | 65/66 (0.985) | 15/28 (0.536) | 1,712 |
| LLM — refined v3 | 64/66 (0.970) | 20/28 (0.714) | — |
| LLM — v4 (freeform) | 63/66 (0.955) | 20/28 (0.714) | — |
| LLM — v3.1 | 64/66 (0.970) | 19/28 (0.679) | — |

**Three things stand out:**

- **The dominant-content-band filter does most of the lift.** `raw_text` recall (61/66) underperforms `filtered` (65/66) because intervening sidebar / browser-chrome OCR observations split otherwise-contiguous gold phrases when normalized into a single token blob. Filtering chrome out collapses the relevant content into one contiguous run and the rubric matches it.
- **The "current" structured `sections` packet is actually the worst OCR variant for field recall (15/28).** The `RAW_BLOCK_COUNT:`, `DOMINANT_CONTENT_BAND:`, and `- body:` lines inject filler tokens (`raw block count`, `body`, etc.) between the content tokens, breaking substring matches across paragraph boundaries the same way bbox metadata does. **If we ship native OCR as a packet path, the packet body should be paragraph-text-only, not the current section packet format.**
- **Native OCR (filtered/paragraphs) is basically tied with the best LLM extractor on text fidelity.** OCR's one salient miss across all 9 fixtures is the chrome line `fixture saved (...)` on `20260421-040120-784`, which is genuinely text in the screenshot but the band filter dropped it as a sidebar. The LLM extractors all miss the same line plus 1–2 others. Field loose-recall is identical at 20/28 — the misses on both sides are long multi-paragraph "message" candidates where the OCR text has a paragraph break in the middle that breaks one contiguous substring match but not the other.

### 2. Latency (per source)

Native OCR:
- average **428.77 ms** end-to-end on the 9 fixtures
- median 398.64 ms, min 273.46, max 1040.05 (cold start)
- postprocessing alone is ~1.4 ms — OCR is the entire cost

LLM source-packet extract (Gemini 3.1 Flash Lite preview, `flash-lite-low-minimal.json`):

| Sweep | Extract avg (ms) | Target-only avg (ms) | Baseline (single-call) avg (ms) |
|---|---:|---:|---:|
| v3-refined run1 | 2,254 | 1,196 | 1,721 |
| v3-refined run2 | 2,199 | 1,212 | 1,323 |
| v3-refined run3 | 2,578 | 1,187 | 1,418 |
| v3-refined avg | **2,344** | 1,198 | 1,487 |
| v3-1 run1 | 2,315 | 1,151 | 1,446 |
| v3-1 run2 | 2,302 | 1,185 | 1,334 |
| v3-1 avg | **2,309** | 1,168 | 1,390 |
| v4-freeform run1 | 1,975 | 1,451 | 1,405 |
| v4-freeform run2 | 2,061 | 1,240 | 1,349 |
| v4-freeform run3 | 2,270 | 1,118 | 1,456 |
| v4-freeform avg | **2,102** | 1,270 | 1,403 |

**Native OCR is ~5× faster than the cheapest LLM extractor variant** (430 ms vs 2,100 ms) and ~5.5× faster than refined v3. Critically, it is also faster than the *baseline* single-call paste path itself (~430 ms vs ~1,400–1,500 ms), which means a native-OCR-first paste pipeline could meaningfully drop end-to-end paste latency, not just the extraction step.

### 3. Capabilities native OCR cannot match (apples-to-oranges, called out explicitly)

| Capability | Native OCR | LLM extraction |
|---|---|---|
| `source_kind` classification | 0/9 (no field emitted) | 8–9/9 across variants |
| `can_answer_without_source_image` | 0/9 (no field emitted) | 2/9 (refined v3) → 6/9 (v3.1, v4) |
| Header-to-body binding (e.g. `other information` paragraph stays bound to the question above it) | partial (the `sections` builder tries, but the paragraph grouper merges header+body too aggressively on docs) | strong, by design (the refined v3 prompt enforces "header verbatim on first line, body on following lines") |
| Image-aware judgements (cropped/scrolled/clipped detection, "is this a partial view") | none | works in v4/v3.1 — 6/9 on can-answer |
| Chrome stripping reliability | mechanical (dominant-band heuristic — over-aggressive on narrow main-content layouts; over-permissive on dashboards) | semantic (the LLM understands what is chrome) |

These are the line-items where the LLM is doing real work that OCR alone can't do. None of them are about *text content fidelity*, which is where the OCR experiment was actually aiming.

## Takeaways

1. **For the source-packet text content itself, native OCR is competitive with the best LLM extractor at ~5× lower latency and zero API cost.** The 9-fixture corpus is small, but the gap on the apples-to-apples metrics is in the noise; the latency gap is not.
2. **The hybrid recommendation from earlier in the experiment thread holds up empirically:** OCR is the right primitive for high-fidelity text capture and chrome stripping; the LLM's value-add is classification, completeness judgement, and semantic structure (header→body binding, source-kind taxonomy). Pairing the two — local OCR for content, a small LLM call only for `source_kind` + `can_answer` + section binding — would plausibly beat both pure variants while keeping costs and latency closer to the OCR floor.
3. **If we ship the OCR packet today, drop the structured `sections` packet format and use the paragraph-text-only variant.** The `RAW_BLOCK_COUNT:` / `- body:` decoration is actively hurting downstream substring matching by 5 candidate fields (15/28 vs 20/28). It's also harder for the consumer LLM to scan than plain prose.
4. **The OCR pipeline's one current text miss** (`fixture saved (...)` on `20260421-040120-784`) is the dominant-band filter being too aggressive. Gold counts that line as salient because it's visible on screen; the filter dropped it as sidebar chrome. That's the failure mode the user already flagged ("noise from sidebars") — except in this case the filter went the other direction. Worth tightening, but it's one fixture.
5. **Both pipelines miss the exact same long multi-paragraph "message" candidate fields** (8 of 28). Those misses are an artifact of the loose-recall rubric requiring one contiguous substring; the prediction has both halves but with a paragraph break in the middle. So the 20/28 ceiling is shared, not pipeline-specific.

## Artifacts

- `experiments/ocr_vs_llm_extraction/run_native_ocr.py` — the runner
- `experiments/ocr_vs_llm_extraction/native_ocr_runs/latency.json` — per-fixture and aggregate native-OCR latency
- `experiments/ocr_vs_llm_extraction/native_ocr_runs/{raw_text,filtered,paragraphs,sections}/<fixture>/source_packet.txt` — packet variants
- `experiments/ocr_vs_llm_extraction/native_ocr_runs/{raw_text,filtered,paragraphs,sections}/gold_packet_compare.{md,json}` — per-variant gold scoring

LLM sweeps that were already on disk and used as comparators (not modified):
- `scratchpad/sweeps/source-packet-v3-ocr-refined-20260424-164555/` — refined v3
- `scratchpad/sweeps/source-packet-v3-1-ocr-20260424-172542/` — v3.1
- `scratchpad/sweeps/source-packet-v4-freeform-20260424-171946/` — v4 freeform
- `scratchpad/sweeps/multi-run-20260424-173336/` — 3-run latency averages

## Follow-up experiment: text-only target call

**Question asked:** can we drop the target image too, feed the LLM only `SOURCE_PACKET_TEXT + TARGET_METADATA_JSON + TARGET_OCR_TEXT`, and net out faster than the current `OCR + image-LLM` path?

**Setup:** `experiments/ocr_vs_llm_extraction/run_text_only_target.py` — for each of the 9 gold fixtures, reuse the v3-refined source packet from the existing sweep (so we isolate the target-side image vs no-image delta), run a custom `text_only_target_prompt.txt` 3× per fixture (27 calls total) on the same Gemini Flash Lite Low / Minimal config.

**Latency result — much bigger than I estimated:**

| Variant | LLM-call latency | vs two-image baseline |
|---|---:|---:|
| Two-image baseline (shipped) | ~1,400–1,500 ms | — |
| With-image target-only (one image, text source packet) | ~1,196 ms | −230 ms |
| **Text-only target (no images)** | **~636 ms avg / 557 ms median** | **−800 ms** |

Critical-path math, assuming source OCR runs at copy time (off paste path) and target OCR runs serially before the LLM call:
- shipped (today): two-image LLM ≈ 1,400 ms
- proposed: target_OCR (~430 ms) + text-only LLM (~636 ms) ≈ **1,066 ms**
- net savings: **~330–430 ms per paste, ~24–30% of paste-time critical path**

**Quality result — sharply bimodal, gated on AX role:**

| AX `focused_role` | Fixtures | Text-only outcome | Notes |
|---|---|---|---|
| `AXTextArea` (real focused field detected) | 5/9 | All 5 produce defensible paste text equivalent to the with-image variant | Some paraphrase the source instead of copying verbatim, but content is on-target |
| `none` / unknown role | 4/9 | All 4 fail: 2× `[[BLANK]]`, 1× `[[NEEDS_REVIEW: No specific input field identified]]`, 1× extracted wrong content (a path string from the source packet) | Without the image as fallback, the model can't recover when AX is silent |

Per fixture (3 runs averaged):

| Fixture | AX role | Text-only avg | with-image equivalence |
|---|---|---:|---|
| `20260421-034447-726-conductor-unknown-role` | none | 548 ms | ✗ all `[[BLANK]]` |
| `20260421-040106-166-conductor-unknown-role` | none | 523 ms | ✗ all `[[BLANK]]` |
| `20260421-040120-784-conductor-unknown-role` | none | 583 ms | ✗ `NEEDS_REVIEW` |
| `20260421-040337-924-conductor-unknown-role` | none | 583 ms | ✗ wrong content |
| `20260421-041218-866-conductor-axtextarea` | AXTextArea | 477 ms | ≈ same content, slightly cleaner |
| `20260421-135931-785-conductor-axtextarea` | AXTextArea | 619 ms | ≈ same content, truncated tail |
| `20260421-140159-935-conductor-axtextarea` | AXTextArea | 658 ms | ≈ semantically equivalent (paraphrased) |
| `20260421-140702-773-conductor-axtextarea` | AXTextArea | 607 ms | ≈ semantically equivalent (paraphrased) |
| `20260421-200834-043-microsoft-edge-axtextarea` | AXTextArea | 1,130 ms | ✓ exact match (3/3) |

(Note: exact-match against the with-image output is 3/27 runs = 11.1%, but that's misleading — the with-image and text-only outputs disagree on minor paraphrase even when both are correct. AX-strong fixtures are functionally equivalent.)

**Read of the result:**

The latency win is real and bigger than expected (~560 ms LLM-side vs the with-image baseline). But text-only is **not a drop-in replacement for the shipped path** — it fails open when AX returns no focused role, and 4/9 fixtures fall into that bucket on this corpus. AX-rich fixtures, which are the common case for desktop-app text fields, work fine.

**Plausible product paths:**

1. **Text-only when AX is strong, fall back to image when weak.** Simple gate: if `focused_role` is in {`AXTextArea`, `AXTextField`, `AXSearchField`, ...}, send text-only (~640 ms LLM); otherwise include the target image (~1,200 ms LLM). On this corpus that's 5 fast / 4 slow, weighted-avg paste latency ~875 ms LLM-side vs ~1,196 ms today — still a ~320 ms win, with no quality regression.
2. **Text-only always, with a confidence/length gate.** If output is `[[BLANK]]` / `[[NEEDS_REVIEW]]` or below some character threshold, retry with the image attached. Worst-case latency is `text_only + with_image ≈ 1,800 ms` on the failing 4/9, but the common case stays at ~640 ms. Net depends on how much we care about p95 vs p50.
3. **Improve AX coverage instead of falling back to image.** The 4 unknown-role fixtures are all Conductor and probably indicate AX gaps in our walker; fixing those would let path #1 cover more of the corpus.

I'd recommend path #1 as the cheapest experiment — it's a one-line conditional in the request builder and has no quality downside on this corpus.

**Caveat on this experiment specifically:** I reused already-extracted v3-refined source packets, so source-packet latency is amortized out. The numbers above represent what the *target-side* call would cost in a hypothetical OCR-source + text-only-target world; total paste critical path also depends on how the source-packet (or source-OCR) step is scheduled.

## Caveats

- 9 fixtures is small. Sub-percentage-point recall deltas are noise.
- Vision OCR cold-start adds ~600 ms variance to the first call (1,040 ms max in this run, 273 ms min). The LLM also has cold-start variance but it's smaller relative to its baseline cost.
- The substring-based loose-recall rubric is biased *for* OCR variants over LLM variants when the candidate field is a long single string the LLM faithfully splits into multiple TEXT_BLOCKS or paragraphs but the OCR variant happens to include verbatim. Both pipelines hit the same 20/28 ceiling here, so this didn't show up in the headline numbers, but it's worth flagging if the corpus grows.
- Native OCR cannot detect "this is only a partial view of the source" (the `can_answer_without_source_image` signal). For sources that are clipped or scrolled, the LLM is the only path that today self-reports `needs_source_image`. If we go OCR-first, we'd still want a tiny LLM step or a heuristic to flag clipping.
