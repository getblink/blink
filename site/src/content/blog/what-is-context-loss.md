---
title: "What is context loss?"
description: "Context loss is the gap between what you understood a minute ago and what you can act on now. Here's how to think about it when you work with AI agents."
publishedAt: 2026-06-07
cluster: context-loss
related: ["what-is-an-agent-handoff"]
draft: false
---

context loss is the gap between what you understood a minute ago and what you can act on right now.

you had the whole picture in your head. the thread, the error, the thing the agent just told you, the reason you opened that tab. then you switched windows, or the conversation got long, or you came back after lunch, and rebuilding that picture costs you real time. that reconstruction tax is context loss.

it isn't one problem. it shows up in at least three places, and they're worth keeping separate because the fixes are different.

## the three places it hides

**in your own head.** you can hold a surprising amount of state while you're in flow, and almost none of it survives an interruption. this is the oldest version of the problem and it predates computers entirely.

**in a model's context window.** a long conversation eventually exceeds what the model can attend to well. the early turns are technically still there, but the model's grip on them weakens — it starts contradicting things it said, or forgetting a constraint you set at the top. the window has a hard limit; useful attention has a softer one that you hit first.

**between agents, or between sessions.** you finish a session with claude code, open a new one tomorrow, and everything the first session learned is gone. hand a task from one agent to another and the receiving agent starts from nothing. the work was done; the *context* of the work didn't travel.

most writing about context loss collapses these together. they shouldn't be. the first is an attention problem, the second is an architecture problem, and the third is a handoff problem.

## why it's getting worse, not better

bigger context windows feel like they should fix this. they help with the second case and barely touch the other two. the deeper shift is that more of us are now running *several* agent threads at once — a couple of coding sessions, a chat, a long-running task in the background. every one of those threads is a separate pool of context, and you are the only thing connecting them.

so the bottleneck moves. it stops being "can the model remember" and becomes "can the human keep re-loading state fast enough to stay in charge of all these threads." that re-loading is the cost. it's quiet, it's constant, and it doesn't show up on any dashboard.

## how to think about reducing it

the honest answer is that you reduce context loss by not making the human reconstruct things a machine could have kept.

if a tool can already see what's on your screen — the thread, the error, the agent's last message — then the context needed to act is sitting right there. it doesn't have to live in your head or survive your context switch. that's the bet behind blink: the reply you're about to type is usually a function of context that's already visible, and a tool that reads the screen can carry that context for you instead of asking you to rebuild it.

that's a claim about a direction, not a benchmark. when we have numbers on how much of this is actually recoverable, we'll publish them here. for now the useful move is just to notice the tax: every time you stop and think "wait, where was i," that's context loss, and most of it didn't need to be yours to pay.
