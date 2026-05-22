# Tag-delimited output vs JSON — experiment results

Replaced JSON-mode generation (`response_mime_type=application/json` + `response_schema`) with plain-text tag-delimited output of the shape:

```
<tldr>
Headline.

Supporting beat.
</tldr>
<suggestion tags="Reply">
text
</suggestion>
<suggestion tags="Reply">
text
</suggestion>
<suggestion tags="Reply">
text
</suggestion>
```

Server-side, the same SSE events (`partial_tldr`, `partial_suggestions`, `final`) come out — client doesn't need to know. Opt-in via `preferences.output_format = "tags"`.

## Headline result

**At n=100, tag mode is faster on every latency metric AND consistently surfaces more substantive context.** Worth shipping, behind a preference for now.

| | JSON p50 | tags p50 | Δp50 | JSON p90 | tags p90 | Δp90 |
|---|---|---|---|---|---|---|
| first_partial_tldr_ms | 1760 | 1398 | **−362** | 2613 | 1678 | **−936** |
| first_partial_suggestions_ms | 2002 | 1744 | −258 | 2936 | 2046 | −890 |
| server_duration_ms | 2760 | 2428 | **−332** | 4298 | 3583 | **−716** |
| **total_wall_ms** | **2906** | **2542** | **−364** | **4393** | **3652** | **−741** |
| tldr length (chars) p50 | 198 | 229 | +16% | — | — | — |
| status=ok | 100/100 | 100/100 | — | — | — | — |
| exactly 3 suggestions | 100/100 | 100/100 | — | — | — | — |

## Setup

- 100 paired bundles, local uvicorn against `gemini-3.5-flash`, `thinking_level=off`
- Only variable: `preferences.output_format` ∈ {`json`, `tags`}
- Same captured runs in both arms; sequential to avoid Gemini contention

## Why the n=30 verdict was wrong

The earlier n=30 run showed tag mode being +140 ms p50 slower with longer TLDRs, and I called it a regression. n=100 says: that was sample variance + a flawed mental model.

What actually happened:
- At n=30, the slow tail of tag responses landed disproportionately, dragging p50 wall up.
- At n=100, both arms regress to mean and tag mode comes out unambiguously faster.
- The TLDR-length gap also shrank: at n=30 it was +34% (175→234); at n=100 it's +16% (198→229). The earlier number was over-sampling verbose outliers.

I also leaned on length-as-a-quality-proxy. **It isn't.** When tag mode is longer, it's usually because the model is using the breathing room to surface a real second beat — visa issues, sigmoid-routing context, sponsored-ad warnings, software-update heads-ups. When it's shorter, it sometimes drops specifics (Picasso/tokenmaxxing vocabulary, specific tool names).

## Qualitative pass (35 paired bundles read carefully)

Pulled the 25 bundles with the biggest TLDR-length divergence (where substance differences live) plus the 10 cases where tag mode is shortest (looking for signal loss).

### Where tags is longer (25 bundles, top by divergence)

**Tags clearly wins on substance (18/25)** by surfacing real load-bearing context that JSON drops:

| Bundle | What tags adds that JSON misses |
|---|---|
| Megatron MoE | sigmoid-routing as the real fix |
| Kevin Whinnery / Anthropic | Justin's Esthéon Studio framing |
| TCC agent recap | "Heads up: certs intermediate-state caveat" |
| Rohan Varma OpenAI credits | $10k/mo per engineer token-burn estimate |
| "Boop" sound conflict | Tauri/WebKit shortcut interception root cause |
| Jared Friedman OpenAI credits | Rohan Varma backstory ("originally broke the news") |
| David Wong zkao | reframes from "asking" to "explaining why expensive" |
| NYT headlines | 2 extra headlines beyond the lead story |
| Screen Recording perms (off) | "You'll need to toggle..." directive |
| LingonberryLess cold email | captures the worry about gap-semester reputation |
| Yann LeCun #1 | Noah Smith framing |
| TCC reset #2 | "Heads up: Info.plist changes can still trigger re-prompts" |
| Jerry Cursor /add-dir | captures the "6 repos without it being painful" pain point |
| Mark Pincus #1 | book promo ("Life at the Speed of Play") |
| PR #54 (Y-coordinate fix) | basePanelTopY-only-captured-once root cause |
| MSN home | **"Heads up: marked as sponsored — likely an ad"** (big product value) |
| Screen Recording perms (on) | "Heads up: Software Update available" |
| Tenobrus hidden text | captures the embedding-mechanism explanation |

**JSON wins (2/25)**: cases where JSON keeps memorable vocabulary or specific tool names that tags abstracts (Howard Lerman's "Picasso/tokenmaxxing"; technical detail in one PR-recap).

**Roughly tied (5/25)**: comparable framings.

### Where tags is shorter (33 bundles total, top 10 read)

When tag mode produces shorter TLDRs:
- Sometimes it's terser and equally informative (Y-coordinate fix v2, UI difference cases)
- Sometimes it loses a specific term JSON kept ("Picasso/tokenmaxxing", named finance tools)
- Once or twice it surfaces something JSON missed (concrete diff stats, "stale permission" debugging angle)

No catastrophic regressions; closer to a wash on this side.

### Attribution accuracy

The n=30 sample showed one possible Noah-vs-Yann attribution flip in a Twitter thread. I specifically looked for this pattern at n=100. **No clear attribution flips in the 35 hand-reviewed bundles**, including multiple Twitter threads with multi-actor exchanges. The earlier concern doesn't reproduce at scale.

## Verdict

**Ship as opt-in.**

- Latency: tag mode is faster on every metric at n=100, especially p90 (≥700 ms wins on server, wall, and first-token).
- Quality: tag mode is the substance-richer of the two in ~18/25 divergent cases; JSON edges it in ~2/25; the rest are wash. No schema/parse failures across 100 captures.
- The +16% TLDR length is buying real signal, not waste.

What would block landing it as the default:
- (none currently identified)

What's worth doing before landing as default:
- A real dogfood pass on the live macOS app for ~a day (the SSE event names are unchanged, so the client doesn't need any code changes to read tag-mode outputs).
- Decide whether `output_format` becomes a user-facing preference ("Output: rich") or stays a hidden runtime config.

## Code in the working tree

This experiment is opt-in behind `preferences.output_format = "tags"`. Default stays JSON. Not committed.

- `server/gemini.py` — `generate_tldr_and_suggestions_streaming_tags`, `_generate_config_tags`, `substitute_output_format_for_tags`, tag parser (`extract_partial_tldr_tags`, `extract_partial_suggestions_tags`). The **v1 (looser) prompt block** is what's currently in the file; v2 was tried and reverted as worse.
- `server/main.py` — `_ALLOWED_OUTPUT_FORMATS = {"json", "tags"}`, plumbs `preferences.output_format` through `_selected_settings`.
- `experiments/latency_replay/replay.py` — `--output-format json|tags` flag.

CSVs:
- `experiments/latency_replay/results/tags_n100_json.csv` (this run's baseline)
- `experiments/latency_replay/results/tags_n100_tags.csv` (this run's candidate)
- `experiments/latency_replay/results/tags_baseline_json.csv` + `tags_candidate.csv` (n=30 v1)
- `experiments/latency_replay/results/tags_v2_baseline_json.csv` + `tags_v2_candidate.csv` (n=30 v2 — kept for reference; v2 prompt itself reverted)

## Reproducing

```bash
bash experiments/latency_replay/start_local_server.sh &
sleep 5

# Baseline (JSON)
BLINK_PROXY_TOKEN=local-test-token python3 experiments/latency_replay/replay.py \
  --limit 100 --url http://127.0.0.1:8765 \
  --thinking off --output-format json \
  --out-csv experiments/latency_replay/results/tags_n100_json.csv

# Candidate (tags)
BLINK_PROXY_TOKEN=local-test-token python3 experiments/latency_replay/replay.py \
  --limit 100 --url http://127.0.0.1:8765 \
  --thinking off --output-format tags \
  --out-csv experiments/latency_replay/results/tags_n100_tags.csv

# Diff
python3 experiments/latency_replay/diff.py \
  experiments/latency_replay/results/tags_n100_json.csv \
  experiments/latency_replay/results/tags_n100_tags.csv \
  --paired
```
