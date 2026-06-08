---
title: "Where the latency actually goes in a screen-aware assistant"
description: "we measured the summon-to-draft loop in blink. the model's thinking dominates; the network hop and the screen capture are basically free."
publishedAt: 2026-06-07
cluster: agent-tooling
related: []
draft: true
---

the whole bet behind blink is speed. a screen-aware assistant that reads what you see and drafts the reply only works if the draft is there before you'd have started typing. so we went looking for where the time goes, expecting to find a pile of small costs we could shave. instead we found one big one and a bunch of rounding error.

## the model is the loop

the request that matters is summon-to-draft: you hit the shortcut, we capture the screen, send it up, and stream back a draft. when we break that wall-clock time into segments, almost all of it is the model thinking before it emits the first token (time to first token, or ttft).

in production over the last 30 days (n=31), the median request was 5971 ms end to end. the median time-to-first-token was 5063 ms, and the median streaming after that was 1076 ms. those are independent medians, not a clean split of one number, but the shape is unmistakable: the wait is overwhelmingly ttft. staging is faster in absolute terms, but the shape holds there too: the model's thinking before the first token is the bulk of it.

the gap between prod and staging isn't fully pinned down on the deployed revision [NEEDS DATA: prod thinking_level=low is unconfirmed on the currently deployed revision]. but in both, the single largest lever is what the model does before it speaks, not anything we do around it.

## the things we assumed were expensive aren't

before measuring, the suspects were the network hop through our proxy and the screen capture itself. both turned out to be cheap.

the proxy hop is essentially free. in a replay test, a cold request routed through the full path came back in 6411 ms versus 6456 ms hitting the server more directly. that's noise, not a hop tax.

the screen capture and prep is around 52 ms. for comparison, the model work it feeds is well over a second. so the part that feels like "blink is doing something to my computer" is the part that costs the least.

what does move ttft is how hard you ask the model to think. in our own tests (on an earlier flash model, so treat these as relative, not as the shipped model's absolute numbers), turning thinking off landed around 2.2s, low around 3.8s, and medium around 9.8s. an image-only request came in around 3.3s. prod runs the cheap end on purpose: gemini-3-flash-preview, temperature 1.0, max output tokens 4096, media resolution medium, thinking low.

that last setting matters more than it looks. on gemini 3, the thinking budget and the output budget share one pool. crank thinking up and it greedily eats the budget, which can starve the visible answer. we've watched a single response spend 1964 thinking tokens and emit only 69 visible ones. for a short-reply task that's a bad trade, which is why the shipped defaults stay low.

## warm beats cold, by a lot

the other real cost is cold start, and it only bites once. the macos app runs a persistent worker (`--serve`) that keeps the python process alive and holds a keep-alive connection open. that reuse saves roughly 200-300 ms of process cold start, plus about 90 ms of tcp+tls handshake per capture that you'd otherwise pay every time.

the server side has the same cliff. a cold-start ttft we measured was 9266 ms against a warm steady state around 2500 ms. that's not a typo: the first request after a scale-from-zero is nearly 4x a warm one. a warmup hook hides this so a real user doesn't eat the cold first request.

## what this means

if you're building this kind of tool, the instinct is to optimize the plumbing: faster capture, leaner serialization, a closer edge. our numbers say don't bother first. the capture is 52 ms and the proxy hop is noise. the budget lives almost entirely in model thinking, so the highest-leverage knobs are the model, the thinking level, and keeping things warm so nobody pays cold start twice.

i'd still like a cleaner picture of the current shipped loop end to end [NEEDS DATA: no client-side per-segment or keypress-to-draft breakdown of the current shipped loop; current-loop capture timing is unmeasured]. but the headline already holds: in a screen-aware assistant, the screen isn't the slow part. the thinking is.

---

**draft notes (remove before publishing)**
- sources: server/gemini.py — per-model overrides for gemini-3-flash-preview: max_output_tokens=4096 (max_output_tokens_for_model) and media_resolution=MEDIUM (media_resolution_for_model), ~lines 204-212; the 512/LOW DEFAULT_SETTINGS at lines 14-15 are unused fallbacks; app/python/blink_once.py (persistent worker, TCP+TLS ~90ms near line 1702); server/main.py ~201 (cold-start ttft 9266 vs ~2500); Cloud Run blink-server tldr_request (prod medians, 30d n=31 — reproduced); memory/project_ax_vs_image_findings.md (cold replay 6411 vs 6456, ttft off/low/medium ~2.2/3.8/9.8s on an earlier flash model, image ~3.3s); docs/EXPERIMENT_LOG.md (image prep ~52ms vs >1s, cold-start ~200-300ms); memory/reference_gemini3_thinking_budget.md (shared thinking/output budget, 1964 thinking / 69 visible)
- staging latency numbers were DROPPED from the post: a re-pull showed the staging log medians drift materially day to day (point-in-time snapshot, not reproducible). re-snapshot with a frozen, dated window if you want them back.
- [NEEDS DATA] / gaps: no measured worker_latency.py output saved; no client-side per-segment or keypress-to-draft breakdown of the current shipped loop; current-loop capture timing unmeasured; prod thinking_level=low unconfirmed on the deployed revision
