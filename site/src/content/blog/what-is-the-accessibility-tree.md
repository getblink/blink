---
title: "What is the accessibility tree?"
description: "The accessibility tree is the structured, machine-readable version of a screen that screen readers use, and that an assistant can read too."
publishedAt: 2026-06-07
cluster: screen-aware
related: []
draft: true
---

## the screen has a second version you never see

when you look at an app, you see pixels: text, buttons, a cursor blinking in a box. underneath that, on every modern platform, there's a second representation of the same screen that's built for software to read instead of eyes. it's called the accessibility tree, and it's the thing that lets a screen reader describe an interface out loud to someone who can't see it.

it's worth knowing about because it's the cleanest way for any program (a screen reader, an automation tool, an assistant) to understand what's on your screen without staring at the pixels.

## what's actually in it

the tree is a hierarchy of elements, and each element carries a few standard pieces of information. on the web, the browser builds the accessibility tree directly from the DOM, and each object exposes a name, a description, a role, and a state, plus the actions available on it: a link can be followed, an input can be typed into ([MDN](https://developer.mozilla.org/en-US/docs/Glossary/Accessibility_tree)). the browser is essentially transforming the page into a form that's useful to assistive tech, so a screen reader can announce the role, name, state, and value of each element through a platform API ([web.dev](https://web.dev/articles/the-accessibility-tree)).

that vocabulary of roles and states is standardized. WAI-ARIA defines roles like `menu`, `slider`, `progressbar`, `heading`, and `region`, and states like `checked` and `readonly` ([W3C](https://www.w3.org/WAI/standards-guidelines/aria/)). the tree is a parallel layer of meaning, not the markup itself.

native apps work the same way in spirit. macOS represents a UI as a hierarchy of accessible elements, each with a role, title, value, children, and a role description ([Apple](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html)). reading it has a catch we ran into building blink: there's no single call to pull the whole tree at once, so you walk it element by element.

## why this matters beyond screen readers

the accessibility tree was built for assistive technology, but it turns out to be the right input for anything that needs to understand a screen, including agents that act on a computer for you. compared to running vision over screenshots, the accessibility APIs are more robust: screenshots are flaky, slow, and token-heavy, while the tree hands you structured text with roles and labels already attached ([crowecawcaw](https://crowecawcaw.github.io/general/2026/05/30/accessibility-for-computer-use.html)).

that's the bet underneath how blink reads your screen. blink reads the accessibility tree of your focused window and flattens it into compact, indented text, then sends that alongside a screenshot. the tree includes nodes that are scrolled above and below the viewport, which is exactly the context a screenshot can't give you on its own: the screenshot shows what's visible, the tree shows what's there. together they tell blink where you are in a long thread or document, not just what's on screen right now.

## the limits

the tree is only as good as the app that builds it. a well-built web page or native app exposes clean roles and names; a sloppy one exposes a pile of generic containers with no labels, and the tree degrades to mush. that's the same reason a screen reader struggles on a badly-built site: the structured layer just isn't there to read. and on macOS, the lack of a whole-tree read means walking the hierarchy has a real cost, so how you traverse it matters.

still, when the tree is good, it's the highest-signal, lowest-noise view of a screen that exists. it's the difference between guessing from pixels and reading the actual structure. for a tool that wants to understand what you're doing and stay out of the way, that's the input you want.

---

**draft notes (remove before publishing)**
- sources: https://developer.mozilla.org/en-US/docs/Glossary/Accessibility_tree ; https://web.dev/articles/the-accessibility-tree ; https://www.w3.org/WAI/standards-guidelines/aria/ ; https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html ; https://crowecawcaw.github.io/general/2026/05/30/accessibility-for-computer-use.html ; /Users/henryz2004/conductor/workspaces/blink/irvine-v2/app/Blink/WindowAXTreeCapture.swift
- [NEEDS DATA] / gaps: no ax-tree-vs-screenshots sibling post exists yet (slug unknown, no cross-link added). VoiceOver/NVDA/JAWS deliberately not named since no primary source was fetched for them.
