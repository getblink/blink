---
title: "What is an agent handoff?"
description: "An agent handoff is the moment one agent or session passes work to another. It's where context usually gets dropped — here's how to think about it."
publishedAt: 2026-06-07
cluster: agent-tooling
related: ["what-is-context-loss"]
draft: false
---

an agent handoff is the moment work passes from one agent — or one session — to another.

it happens more than you'd think. you finish a planning chat and start a fresh session to do the build. one agent writes code and a second one reviews it. a long-running task hands its result back to you, and you hand it on to a teammate. each of those is a handoff: a boundary where the work keeps going but the *context* of the work has to cross over with it.

the work usually crosses fine. the context usually doesn't.

## what actually gets dropped

the receiving side starts from less than the sending side ended with. the first agent knew which approaches it had already ruled out, why it chose the file it chose, what the user actually meant by the vague third sentence. almost none of that is in the artifact it hands over. so the second agent re-derives it, or worse, doesn't — and quietly redoes a decision the first one had already made for a good reason.

it's the same shape whether the boundary is between two agents or between two of your own sessions a day apart. you are also a receiver of handoffs, and a tired you tomorrow gets a thin one from a sharp you today.

## why it's not just a bigger-window problem

a roomier context window helps inside a single session. it does nothing at a handoff, because the handoff is exactly the point where you leave that window behind. whatever didn't make it into the message, the file, or the commit simply isn't there on the other side. the boundary is the leak, and the boundary doesn't go away when the window gets bigger.

it tends to get worse as you run more threads at once, because every extra thread is another edge where a handoff can happen and another place for context to fall through.

## how to think about reducing it

the move is to make less of the context something a human has to carry across by hand. if a tool can see the screen the first agent left behind — the thread, the diff, the last message — then the context the next step needs is already sitting in plain sight, not locked in the previous session's memory.

that's the same bet behind blink, pointed at the seam between steps: the next thing you'd type or pass along is usually a function of what's already visible, and a tool that reads the screen can carry that across the handoff instead of asking you to retype it.

this is a claim about a direction, not a measurement. the practical thing for now is just to notice the seam: every time you open a fresh session and think "okay, where did i leave this," that's a handoff, and most of what got dropped didn't have to.
