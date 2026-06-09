---
title: "What is the accessibility tree?"
description: "The accessibility tree is the structured, machine-readable version of a screen that screen readers use, and that an assistant can read too."
publishedAt: 2026-06-07
cluster: screen-aware
related: []
draft: false
---

## the screen has a second version you never see

when you look at an app, you see pixels: text, buttons, a cursor blinking in a box. underneath that, on every modern platform, there's a second representation of the same screen built for software to read instead of eyes. it's called the accessibility tree, and it's the thing that lets a screen reader describe an interface out loud to someone who can't see it.

it's also the cleanest way for any program (a screen reader, an automation tool, an assistant) to understand what's on your screen without staring at the pixels.

## what's actually in it

the tree is a hierarchy of elements. each one carries a name, a role, a state, and the actions available on it: a link can be followed, an input can be typed into ([MDN](https://developer.mozilla.org/en-US/docs/Glossary/Accessibility_tree)). on the web, the browser builds this tree from the DOM so a screen reader can announce each element through a platform API ([web.dev](https://web.dev/articles/the-accessibility-tree)).

that vocabulary is standardized. WAI-ARIA defines roles like `menu`, `slider`, `progressbar`, `heading`, and `region`, and states like `checked` and `readonly` ([W3C](https://www.w3.org/WAI/standards-guidelines/aria/)). the tree is a parallel layer of meaning, not the markup itself.

native apps work the same way. macOS represents a UI as a hierarchy of accessible elements, each with a role, title, value, and children ([Apple](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html)). one catch we ran into building blink: there's no single call to pull the whole tree at once, so you walk it element by element.

## why this matters beyond screen readers

the accessibility tree was built for assistive technology, but it turns out to be the right input for anything that needs to understand a screen, including agents that act on a computer for you. compared to screenshots, the tree is more robust: screenshots are slow and token-heavy, while the tree hands you structured text with roles and labels already attached ([crowecawcaw](https://crowecawcaw.github.io/general/2026/05/30/accessibility-for-computer-use.html)).

that's what blink reads. it pulls the accessibility tree of your focused window, flattens it into compact indented text, and sends that alongside a screenshot. the tree includes nodes scrolled above and below the viewport, which is exactly the context a screenshot misses: the screenshot shows what's visible, the tree shows what's there. together they tell blink where you are in a long thread or document, not just what's on screen right now.

## the limits

the tree is only as good as the app that builds it. a well-built page or native app exposes clean roles and names; a sloppy one exposes generic containers with no labels, and the tree degrades to mush. that's the same reason a screen reader struggles on a badly-built site: the structured layer just isn't there.

when the tree is good, it's the highest-signal, lowest-noise view of a screen that exists. not guessing from pixels, but reading the actual structure. for a tool that wants to understand what you're doing and stay out of the way, that's the input you want.

