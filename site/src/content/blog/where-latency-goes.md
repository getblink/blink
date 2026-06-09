---
title: "Where the latency actually goes in a screen-aware assistant"
description: "we measured the summon-to-draft loop in blink. the model's thinking dominates; the network hop and the screen capture are basically free."
publishedAt: 2026-06-07
cluster: agent-tooling
related: []
draft: false
---

the whole bet behind blink is speed. a screen-aware assistant only works if the draft is there before you'd have started typing. so we went looking for where the time goes, expecting a pile of small costs we could shave. instead we found one big one and a bunch of rounding error.

## the model is the loop

the request that matters is summon-to-draft: you hit the shortcut, we capture the screen, send it up, and stream back a draft. when we break that wall-clock time into segments, almost all of it is the model thinking before it emits the first token (time to first token, or ttft).

in production over the last 30 days (n=31), the median request was 5971 ms end to end. the median time-to-first-token was 5063 ms, and the median streaming after that was 1076 ms. those are independent medians, not a clean split of one number, but the shape is unmistakable: the wait is overwhelmingly ttft. the single largest lever is what the model does before it speaks, not anything we do around it.

## the things we assumed were expensive aren't

before measuring, the suspects were the network hop and the screen capture. both turned out to be cheap.

the proxy hop is essentially free. in a replay test, a cold request routed through the full path came back in 6411 ms versus 6456 ms hitting the server more directly. that's noise, not a hop tax.

the screen capture and prep is around 52 ms. for comparison, the model work it feeds is well over a second. so the part that feels like "blink is doing something to my computer" is the part that costs the least.

what does move ttft is how hard you ask the model to think. we ran a sweep across thinking levels on the shipped model (gemini-3-flash-preview, 9 samples per level). "low" thinking added almost nothing: median ttft ~2.3s, versus ~2.4s with thinking off. but "medium" exploded to ~18s. that's not a linear scale; it's a cliff.

prod runs at the cheap end on purpose: gemini-3-flash-preview, temperature 1.0, max output tokens 4096, media resolution medium, thinking low. "low" is essentially free latency, and it's enough for a short-reply task.

that last setting matters more than it looks. on gemini 3, the thinking budget and the output budget share one pool. crank thinking up and it greedily eats the budget, which can starve the visible answer. we've watched a single response spend 1964 thinking tokens and emit only 69 visible ones. for a short-reply task that's a bad trade.

## warm beats cold, by a lot

the other real cost is cold start, and it only bites once. the macos app runs a persistent worker (`--serve`) that keeps the python process alive and holds a keep-alive connection open. that reuse saves roughly 200-300 ms of process cold start, plus about 90 ms of tcp+tls handshake per capture that you'd otherwise pay every time.

the server side has the same cliff. a cold-start ttft we measured was 9266 ms against a warm steady state around 2500 ms. that's not a typo: the first request after a scale-from-zero is nearly 4x a warm one. a warmup hook hides this so a real user doesn't eat the cold first request.

## what this means

if you're building this kind of tool, the instinct is to optimize the plumbing: faster capture, leaner serialization, a closer edge. our numbers say don't bother first. the capture is 52 ms and the proxy hop is noise. the budget lives almost entirely in model thinking, so the highest-leverage knobs are the model, the thinking level, and keeping things warm so nobody pays cold start twice.

in a screen-aware assistant, the screen isn't the slow part. the thinking is.

