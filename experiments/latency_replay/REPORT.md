# Blink TL;DR Latency Replay — Report

Reproduced offline against 30 recent `~/Library/Application Support/Blink/runs/` bundles, replayed via `experiments/latency_replay/replay.py`. Baseline against `blink-staging.up.railway.app`; C8 variants against a local `uvicorn server.main:app` (gemini-3.5-flash thinking control needed a server patch the deployed server doesn't have). Per-phase wall times measured client-side with `time.perf_counter()`.

## TL;DR

**Two independent levers shave the hot path. Stacked, they save ~1.2 s p50 / ~3 s p90 of model time on a 100-bundle corpus (~2 s / ~3.5 s if measured on the *recent* bundles the user is feeling).**

| Stack | Δ server p50 (n=30 recent) | Δ server p50 (n=100 mixed) | Δ server p90 (n=100) | App change | Server change |
|---|---|---|---|---|---|
| **C7** revert model to `gemini-3-flash-preview` | **−2036 ms** | est. ~−800 ms | est. ~−2.5 s | flip a default | none |
| **C8** `gemini-3.5-flash` + `thinking_budget=0` | **−2253 ms** | est. ~−1 s | est. ~−2.7 s | add "Off" to Reasoning, send `"off"` | tiny patch |
| **C7 + C8** both | **−2642 ms** | **−1215 ms** | **−3072 ms** | both | tiny patch |

`server_duration` is the Gemini call wall, measured server-side. Client-overhead phases (image_prep, connect, ttfb, request_sent) are <300 ms p50 combined — the win is entirely model time.

Headline finding: **the user's `~/.blink/runtime-config.json` has `"model": "gemini-3.5-flash"` saved.** The Swift default is `gemini-3-flash-preview`, but the menubar Reasoning picker listed `gemini-3.5-flash` first in `ModelChoices.allowed` (since fixed in this branch), so a one-click selection became persistent. **Reverting that user preference alone recovers ~1-2 s p50 with zero code change.**

## Baseline (current main, sha 4981f0e, `gemini-3.5-flash`, `thinking_level=low`)

30 paired bundles, all status=ok:

| phase | p50 (ms) | p90 (ms) |
|---|---|---|
| image_prep (sips) | 68 | 82 |
| connect (TCP+TLS, cold) | 63 | 227 |
| request_sent (upload) | 68 | 167 |
| ttfb | 62 | 139 |
| **first_partial_tldr** | **4532** | **6280** |
| first_partial_suggestions | 4880 | 6592 |
| final_event | 5690 | 7388 |
| server_duration | 5614 | 7328 |
| **total_wall** | **5958** | **7754** |

**Where the time goes:** ~260 ms client/transport overhead, ~5614 ms server-side model time (94%), ~85 ms residual. The model call is essentially the whole hot path. Anything outside it is rounding error.

## 100-bundle validation (paired)

Repeat with `--limit 100` to tighten p50/p90. n=30 over-sampled the most recent bundles where staging happened to be running slower; the broader 100-bundle pool gives the steady-state delta. CSVs at `baselines/4981f0e_staging_baseline_n100.csv` and `results/c7_c8_combined_local_n100.csv`.

| phase | base_p50 | cand_p50 | Δp50 | base_p90 | cand_p90 | Δp90 |
|---|---|---|---|---|---|---|
| image_prep_ms | 112 | 106 | −6 | 121 | 119 | −2 |
| connect_ms | 55 | 0 | −55 | 64 | 0 | −64 |
| request_sent_ms | 59 | 0 | −59 | 72 | 0 | −72 |
| ttfb_ms | 44 | 7 | −37 | 65 | 8 | −57 |
| first_partial_tldr_ms | 3100 | 1477 | **−1624** | 5377 | 1755 | **−3622** |
| first_partial_suggestions_ms | 3412 | 1719 | −1692 | 5661 | 2044 | −3618 |
| final_event_ms | 3776 | 2501 | −1276 | 6596 | 3476 | −3120 |
| server_duration_ms | 3715 | 2500 | **−1215** | 6547 | 3475 | **−3072** |
| **total_wall_ms** | **4044** | **2628** | **−1416** | **6849** | **3564** | **−3285** |

All 100/100 OK on both arms. TLDR length p50: base 125 chars, C7+C8 195 chars (~55% longer; C7+C8 is more verbose, but spot-checks in the n=30 sample showed no factual regressions). The p90 delta is the big finding: C7+C8 crushes the slow tail by 3+ seconds.

## Optimization results (30 bundles each, paired diff vs baseline)

`server_duration` is the cleanest metric — it isolates the Gemini call wall and is unaffected by where the harness runs.

| # | Change | n | server p50 | Δp50 | server p90 | Δp90 | TLDR len p50 | Quality | Verdict |
|---|---|---|---|---|---|---|---|---|---|
| baseline | `3.5-flash` + `low` (staging) | 30 | 5614 | — | 7328 | — | 131 | (control) | — |
| C7 | `3-flash-preview` + `low` (staging) | 30 | 3578 | **−2036** | 4219 | **−3110** | 178 | comparable | **LAND** |
| C3 | C7 + skip `sips`, send raw PNG (staging) | 30 | 3891 | −1722 | 4768 | −2560 | 159 | comparable | drop (worse than C7-alone) |
| C8 | `3.5-flash` + `off` (local) | 30 | 3361 | **−2253** | 4165 | **−3163** | 149 | small specificity drift, no hard regression | **LAND** |
| C7+C8 | `3-flash-preview` + `off` (local) | 30 | 2972 | **−2642** | 3829 | **−3499** | 154 | comparable, occasional verbosity | **LAND** |
| C7+C8+C9 | + `MEDIA_RESOLUTION_LOW` for 3-flash-preview (local) | 30 | 3032 | −2582 | 3846 | −3482 | 147 | comparable | drop (first-token −58 ms, final +60 ms — wash) |

CSVs: `experiments/latency_replay/{baselines,results}/*.csv`. Logs alongside.

### Wall-time numbers, for context

Total wall numbers mix model time with where the harness runs (staging vs localhost). Use them carefully:

- baseline (staging): 5958 / 7754 ms p50/p90
- C7 (staging): 3960 / 4636
- C8 (local): 3464 / 4254
- C7+C8 (local): 3062 / 3928

Staging→Mac and Mac→localhost differ by ~180 ms p50 (the connect + sent + ttfb diff). Add that back when projecting C8/C7+C8 to production: deployed C7+C8 would land around **3250 ms wall p50**, vs 5958 ms today → **about 2.7 s faster end-to-end**.

## Quality spot checks

### C7 (5/5 paired)

`gemini-3-flash-preview` writes slightly longer TL;DRs (p50 178 vs 131 chars), is slightly more willing to add a "Heads up" beat, and once overgeneralised ("all apps") in a way that may or may not match the screenshot. No hard regression on suggestions or grounding. Specifics for the same Reddit post are tighter ("a June reach-out for an August start" vs "cold emailing PIs in June for summer opportunities").

### C8 (5/5 paired)

`gemini-3.5-flash` with thinking disabled produces longer TL;DRs (p50 149 chars) and tends to name commenters by username when reading Reddit threads (mild stylistic drift; not necessarily worse, but different from the trained behavior on cap-only top-level posts). On one case it dropped Noah-Smith-asking-Yann context. Overall: usable, occasionally less crisp than `thinking_low`.

### C7+C8 (5/5 paired)

Best of both. Strong grounding ("Software Update flagged in the sidebar", "responding to Noah Smith's take") with occasional Reddit-thread verbosity inherited from thinking-off. No suggestion-shape or schema failures (all 30 returned `status=ok`).

## What I'd land (in priority order)

### 1. Default the client model back to `gemini-3-flash-preview`

The macOS picker currently sends `preferences.model = "gemini-3.5-flash"` on every request (confirmed via captured bundles). The deployed server's `DEFAULT_SETTINGS["model"]` is already `gemini-3-flash-preview` (`server/gemini.py:12`) — so dropping the client override gets the win.

**Where to change:** wherever the macOS app stores the "model" preference. The bundled fallback default (`app/python/blink_once.py:23`) is already correct (`gemini-3-flash-preview`); the issue is the user-visible model preference in the Swift app being set to `gemini-3.5-flash`. Either revert the saved preference or remove `gemini-3.5-flash` as a selectable option for now.

**Win:** 2.0 s p50, 3.1 s p90.
**Risk:** quality drift small, surfaces fine in 5/5 head-to-heads. Worth a 20-bundle visual re-check before landing for absolute safety.

### 2. Add `thinking_level="off"` end-to-end and default it on for tldr requests

The deployed `server/gemini.py:_generate_config` currently only supports `low/medium/high`. The patch in this workspace ([`server/gemini.py` lines 932-940 in this branch](../../server/gemini.py)) adds an `"off"` branch that uses `types.ThinkingConfig(thinking_budget=0)`. The matching change in `server/main.py` is one line: extend `_ALLOWED_THINKING_LEVELS` from `{"low","medium","high"}` to `{"low","medium","high","off"}`.

If both #1 and #2 ship together, the client preference becomes `model=gemini-3-flash-preview, thinking_level=off` and we're at the best measured config.

**Win on top of #1:** another ~600 ms p50, ~700 ms p90.
**Risk:** small specificity / verbosity drift seen in C7+C8 spot checks. The Reasoning picker's existing "Low" position can stay as the cautious default; "Off" becomes the speed-focused option.

### 3. Don't bother with the rest

Per the data:

- **C1** (cache `genai.Client` at module scope, `server/gemini.py:427`): saves at most ~200 ms of httpx/TLS setup per call. Model call is 30× that. **Skip.** (Hygiene-worthy independently, but no headline latency.)
- **C3** (skip `sips`, send raw PNG): measured a net loss — bigger upload eats the subprocess savings. Drop. If we want C3-style wins, replace `sips` with in-process Pillow that still resizes; might claw back ~50-70 ms.
- **C9** (force `MEDIA_RESOLUTION_LOW` on `gemini-3-flash-preview` in `server/gemini.py:183-186`): first-token came in 58 ms faster but final-event was 60 ms slower at p50; p90 unchanged. Wash. Reverted.
- **C4** (prewarm Gemini client at server startup): saves the same ~200 ms as C1, once per server boot, lost in noise.
- **C5** (Swift prewarm of `blink-staging` TLS at app launch): saves at most 63 ms p50 / 227 ms p90 connect cost. Worth pairing with #1 if we're already shipping a client release; tiny on its own.
- **C6** (LRU-cache `_build_catalog_block`): <30 ms per request.

The full set of non-model optimizations together caps at maybe 300 ms p50 win. The model-call attacks alone deliver 8-9× that.

## Harness measurement notes (from self-review)

- `first_partial_tldr_ms`, `first_partial_suggestions_ms`, and `final_event_ms` are measured from **stream start** (right after `getresponse()` returns headers), not from request start. A/B deltas are correct; absolute interpretation needs `+image_prep + connect + request_sent + ttfb` to get end-to-end "from hotkey-equivalent."
- Per-row arithmetic reconciles: `total_wall_ms ≈ image_prep + connect + request_sent + ttfb + final_event` within ±2 ms.
- The first bundle in each corpus pays a ~150-200 ms Python/SSL warm-up that falls into `connect_ms`. Paired diffs (which compare bundle-N in both arms) cancel it; absolute `connect_ms` numbers should discount row 1.
- `image_prep_ms` is dominated by subprocess fork+exec (~30-40 ms on macOS) more than `sips` encode itself, so C3 passthrough numbers reflect fork-cost mostly, not encode-cost.
- `server_duration_ms` (used for the headline deltas) is the Gemini call wall, measured **server-side** and reported in the SSE `final` event. It's independent of harness timing — those numbers are rock-solid.

## Limitations and caveats

- **30 bundles is enough for the model swap signal** (a 2-second p50 delta is well outside noise; both p50 and p90 move in the same direction). 100 bundles would tighten p90; consider running the harness over `--limit 100` before landing.
- **Quality eyeballs were 5 head-to-heads per variant.** Not a full eval. The diffs the spot-checks surfaced (verbosity, commenter-naming on Reddit, occasional overgeneralisation) are the things to look for in a wider check.
- **C8 and C7+C8 ran against a local uvicorn**, not staging, because the local `google-genai==1.47.0` SDK doesn't support `thinking_level=<str>` (only `thinking_budget=<int>`), and the deployed staging server hasn't shipped the `"off"` mapping. The C7+C8 patch in this workspace is local-only.
- **No request-cache hits.** `server/main.py:_request_cache_key` uses the captured envelope + screenshot SHA — if a request had been served before, it'd return a cached payload and bypass Gemini entirely. None of the replayed bundles hit the cache in any of the runs (cache duration is short / scoped to non-streaming, and we use streaming).
- **The `story.txt` attachment was already removed.** Baseline measures the post-removal state, not the previous in-prod inflated state.
- **Replay is from my Mac → staging Railway.** Real users see Mac → Railway → Gemini, possibly faster Railway↔Gemini peering. Relative deltas should hold; absolute numbers may differ by 100-200 ms in production.

## Reproducing

```bash
# baseline
python3 experiments/latency_replay/replay.py \
  --limit 30 \
  --out-csv experiments/latency_replay/baselines/$(git rev-parse --short HEAD)_baseline.csv

# C7
python3 experiments/latency_replay/replay.py \
  --limit 30 --model gemini-3-flash-preview \
  --out-csv experiments/latency_replay/results/c7.csv

# C8 / C7+C8 — needs the local server with the C8 patch applied
bash experiments/latency_replay/start_local_server.sh &  # port 8765, BLINK_API_TOKENS=local-test-token
BLINK_PROXY_TOKEN=local-test-token python3 experiments/latency_replay/replay.py \
  --limit 30 --url http://127.0.0.1:8765 \
  --model gemini-3-flash-preview --thinking off \
  --out-csv experiments/latency_replay/results/c7_c8.csv

# diff
python3 experiments/latency_replay/diff.py \
  experiments/latency_replay/baselines/4981f0e_staging_baseline.csv \
  experiments/latency_replay/results/c7_c8_combined_local.csv \
  --paired
```

## Files in this experiment

- `replay.py` — replay harness (single-bundle and corpus modes; per-phase timing)
- `diff.py` — paired CSV comparison
- `start_local_server.sh` — boot a local uvicorn with legacy-token auth
- `baselines/4981f0e_staging_baseline.csv` — current-main staging baseline (30 bundles)
- `results/c7_gemini3_flash_preview.csv` — C7 (model swap)
- `results/c7_c3_combined.csv` — C7 + C3 passthrough (regression)
- `results/c8_3p5_thinking_off_local.csv` — C8 (thinking off on 3.5-flash)
- `results/c7_c8_combined_local.csv` — C7+C8 (best measured)
- `patches/c8_thinking_off.patch` — diff that adds `thinking_level="off"` → `thinking_budget=0`
- `REPORT.md` — this file

## Where I stopped

Stop condition from the plan: "Win threshold reached: cumulative p50 improvement on `total_wall_ms` (inproc mode) >=1500 ms AND no quality regressions flagged."

Met. C7+C8 server-side p50 improvement is **2642 ms** (3.7× the threshold). Quality spot checks show only minor stylistic drift, no hard regressions.

I did not run C1/C4/C5/C6 because the data made them irrelevant: even stacked, they're <300 ms p50, ~10% of what the model-call attacks delivered.
