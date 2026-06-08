---
title: "AX tree vs screenshots: what an AI actually needs to read your screen"
description: "we tested whether blink should read your screen as accessibility text or as a screenshot. the text-only path held up across every surface we tried."
publishedAt: 2026-06-07
cluster: screen-aware
related: []
draft: true
---

if you want an AI to read your screen, the obvious move is to take a screenshot and hand it the pixels. that's how most of the research in this space works: the model looks at an image and points at things. but a mac already exposes a structured description of what's on screen, the accessibility tree, and reading that text is cheaper and faster than reading pixels. so before shipping, we wanted to know which one blink actually needs.

## the two ways to read a screen

the accessibility tree (the "AX tree") is the same data screen readers use. it's the buttons, labels, text fields, and their values, already parsed into text. the alternative is a screenshot: capture the window, send the image, let the model do the parsing.

the screenshot path is where most of the public research lives, and it's vision-centric for a reason. accessibility metadata is famously unreliable on the open web. the [WebAIM annual analysis](https://arxiv.org/html/2410.05243v1) found accessibility errors on 95.9% of home pages, and the same line of work points out that rendering a page's full HTML can cost on the order of 10x the tokens of just looking at it. if you're building a general web agent, pixels are the safer bet.

but blink isn't a general web agent. it reads native mac apps and the windows in front of you, where the AX tree is in much better shape. so the question for us was empirical, not philosophical: does the text-only path actually break anywhere we care about?

## what we measured

we ran AX-tree-only against screenshot-only against a hybrid (both) as the screen input, across five surfaces.

the headline: AX-only was on par with the hybrid across all five, and no surface broke the AX-only path. that's the result that mattered most. if reading the text alone is as good as reading text plus pixels, you carry the pixels for nothing.

on latency, image-only was the slowest, around 3.3s to first token. but the bigger story is that latency is dominated by thinking, not by what you feed the model. time-to-first-token by thinking level: off at 2.2s, low at 3.8s, medium at 9.8s. the hybrid path came in at 1.9s and image-only at 3.3s. the input format is noise next to the thinking budget.

a couple of things we worried about turned out not to matter:

- the proxy hop is negligible. routing through our server added basically nothing: 6411ms vs 6456ms.
- walking the AX tree is cheap, about 60ms.
- screenshots aren't free even when they're "small." image tokens scale with resolution: 303 tokens at low media resolution, 570 at medium, 1122 at high. that's real budget spent on something the text path got for free.

given all that, we shipped the hybrid. AX-only was good enough on quality, but keeping the screenshot in the loop is cheap insurance for the surfaces where AX metadata might thin out, and it doesn't cost us on latency.

## what we capped, and how we cut it

the AX tree can get big, so there's a budget: the server keeps the first `AX_TREE_MAX_CHARS` of it, currently 40,000 characters. but the size of the budget matters less than *how* you cut when the tree runs past it. the obvious approach, keep the first N characters, can throw away the focused region, which is usually the part the model actually needs.

so we tested an alternative: an anchored window that truncates around what you're looking at instead of from the top. across 180 probe runs at a tighter budget, the anchored cut dropped the focused region in 0 of them, versus 104 for the naive keep-the-first-N-characters cut. how you truncate, by relevance instead of by position, turned a real failure mode into a non-issue.

## the honest gaps

a few things we can't put a clean number on yet:

- we don't have committed raw per-run quality tallies. the artifacts that would back the quality comparison are gitignored under `.context/qcap/`. [NEEDS DATA: committed per-run quality scores for AX-only vs hybrid across the five surfaces]
- "on par" is the verdict, but we don't have a number for how often the screenshot vs the AX tree was actually the decisive input. [NEEDS DATA: rate at which screenshot vs AX changed the answer]

so the conclusion is real but bounded: on the surfaces blink reads, the accessibility text alone carried the load, the screenshot was cheap to keep, and the latency you feel is your thinking budget, not your screen.

---

**draft notes (remove before publishing)**
- sources: memory/project_ax_vs_image_findings.md, memory/project_ax_tree_hybrid_integration.md, docs/EXPERIMENT_LOG.md, https://arxiv.org/html/2410.05243v1 (UGround), https://arxiv.org/html/2506.03143v1 (GUI-Actor, not directly cited)
- [NEEDS DATA] / gaps: committed per-run quality tallies (artifacts gitignored in .context/qcap/); rate at which screenshot vs AX was the decisive input
