---
title: "What is context loss?"
description: "Context loss is when the thing about to do the work no longer has the context the work needs, and you end up re-carrying it by hand."
publishedAt: 2026-06-07
cluster: context-loss
related: []
draft: true
---

## the short version

context loss is when the thing about to do the next step no longer has the context that step needs. someone, or something, had it a moment ago. now it's gone, and the work stalls until you carry it back over by hand.

it shows up in three places. your own head, when you get interrupted. a model's context window, over a long conversation. and the seam between agents or sessions, at a handoff. they look like different problems. they're the same problem wearing different clothes.

## in your own head

you're in the middle of something, a message lands, you deal with it, and then you have to find your place again. that "find your place again" is context loss. you held the state of the task in your head, the interruption knocked it out, and getting it back costs you.

you've probably seen the claim that it takes 23 minutes to recover from an interruption, usually pinned to gloria mark at uc irvine. worth knowing: that exact number doesn't appear in her peer-reviewed work. it traces to interviews and talks, not the paper ([sourcing critique](https://blog.oberien.de/2023/11/05/23-minutes-15-seconds.html)). so i won't quote it as a stat.

what her actual peer-reviewed paper found is more useful anyway. in [the cost of interrupted work: more speed and stress](https://ics.uci.edu/~gmark/chi08-mark.pdf) (chi 2008), interrupted work got finished in the same or even less time, but at the cost of more stress, more effort, higher workload, more frustration, and more time pressure. the tax isn't always on the clock. it's the effort of rebuilding the state you were holding. that's context loss you pay for with attention.

## in a model's context window

people assume that once a model can hold the whole conversation, context loss is solved. just use a bigger window. but a window you can fit things into isn't the same as a window the model reads evenly.

[lost in the middle](https://aclanthology.org/2024.tacl-1.9/) (liu et al., tacl 2024) showed that a model does best when the relevant information sits at the start or the end of the input, and gets noticeably worse when it has to use something buried in the middle of a long context. the information is technically there. the model just doesn't reliably reach it.

chroma pushed on this directly. their [context rot](https://www.trychroma.com/research/context-rot) writeup (july 2025) tested 18 frontier models and found every one of them degrades as the input gets longer, often well before the window is anywhere near full. so a 200k or million-token window isn't a 200k or million-token window you can count on. having the room is not the same as using the room. that's context loss happening inside a single, technically-sufficient window.

## at the handoff

this is the one a bigger window doesn't touch, because it happens in the gap between windows.

context windows are already enormous. gemini runs around a million tokens (pro up to ~2m), gpt-4.1 around a million, claude 200k by default with 1m in beta ([overview](https://www.morphllm.com/claude-context-window)). and yet the moment one agent finishes and the next one starts, or you pick a session back up tomorrow, the new step begins from nothing. whatever the last step knew is sitting in a window you just walked away from.

that's the seam. you become the transport layer. you read what one side figured out and re-type it into the other, by hand, every time. the window can be as big as you like; it doesn't help across a boundary it was never on.

## why this matters for blink

[blink](/blog/what-is-blink)'s bet is that most of what you type is contextual continuation: the thread already tells you what to say, the agent already gave you the answer. an agent is a thread that wants a response, and the response is usually a function of context the agent just handed you.

context loss is the gap in that loop. the next step needs context that's technically right there on your screen, and the only thing moving it across is you, by hand. so the fix isn't a bigger window. it's a tool that reads the screen, so the context the next step needs is already visible instead of re-carried by you.

that's the whole job. blink reads what's there and writes the rest, so the handoff stops landing on your keyboard.

---

**draft notes (remove before publishing)**
- sources: https://aclanthology.org/2024.tacl-1.9/ ; https://www.trychroma.com/research/context-rot ; https://ics.uci.edu/~gmark/chi08-mark.pdf ; https://blog.oberien.de/2023/11/05/23-minutes-15-seconds.html ; https://www.morphllm.com/claude-context-window ; /Users/henryz2004/conductor/workspaces/blink/irvine-v2/site/src/content/blog/what-is-blink.md (voice + framing) ; /Users/henryz2004/conductor/workspaces/blink/irvine-v2/site/src/content.config.ts (frontmatter contract)
- [NEEDS DATA] / gaps: no defensible peer-reviewed number for "minutes to resume after an interruption" exists (the 23-min figure is not in mark's papers); used the qualitative chi 2008 finding instead. no in-repo quantified context-loss metric (reroll rate, time saved) was available for this definition post. context-window sizes are mid-2026 secondary-source estimates (morph) and should be checked against vendor docs if stated as firm figures. cross-link to companion post `what-is-an-agent-handoff` deliberately omitted: it was removed as a placeholder in commit 6f61e34 and is not in the live build, so it is not in `related`; re-add it there only if that post returns.
