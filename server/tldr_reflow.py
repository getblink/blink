#!/usr/bin/env python3
"""Deterministic post-process: turn an *announced* inline enumeration in a TL;DR
into a scannable vertical list (one item per line, single \\n). High precision by
design — it only fires when the lead-in explicitly announces a count of a
list-noun ("four options:", "three directions:"), which is the exact shape the
model produces for the run-on case and almost never appears in normal prose.

Intended home: server main.py, applied to the *final* tldr before returning
(or app-side before render). Pure function, no deps.
"""
from __future__ import annotations
import re

_NUMWORD = r"(?:two|three|four|five|six|2|3|4|5|6)"
_LISTNOUN = (r"(?:options|paths|choices|directions|scenarios|findings|things|"
             r"steps|ideas|ways|areas|approaches|changes|fixes|reasons|points|tradeoffs)")
# Lead-in that ANNOUNCES a list, ending at the colon that introduces it. The
# [^:(]* (no paren, no colon) stops it crossing into a parenthetical labelled
# list like "(A: x, B: y)" — anchoring on that inner colon mangles the output.
_ANNOUNCE = re.compile(rf"\b{_NUMWORD}\s+(?:\w+\s+){{0,3}}{_LISTNOUN}\b[^:(]*:\s+", re.I)
# Explicit item markers already in the text.
_MARKER = re.compile(r"(?:(?<=\s)|^)(?:\d{1,2}[.)]|[A-F][.):])\s+")
# A sentence boundary (". " before a capital) — used to peel a trailing sentence
# off the last list item when the list and the prose share one beat.
_SENT = re.compile(r"\.\s+(?=[A-Z])")


def _split_items(body: str) -> tuple[list[str], str | None] | None:
    """Return (items, trailing_prose). Prefer explicit markers, then semicolons,
    then long comma clauses. None when the body isn't a real >=3-item list."""
    body = body.strip()
    items: list[str] | None = None
    # 1) explicit numbered/lettered markers
    marks = list(_MARKER.finditer(body))
    if len(marks) >= 3:
        idx = [m.start() for m in marks] + [len(body)]
        items = [re.sub(_MARKER, "", body[idx[i]:idx[i + 1]], count=1).strip()
                 for i in range(len(idx) - 1)]
    # 2) semicolons
    elif body.count(";") >= 2:
        segs = [re.sub(r"^(?:and|or)\s+", "", s.strip()) for s in body.split(";") if s.strip()]
        if len(segs) >= 3:
            items = segs
    # 3) commas — only long clauses (short word-lists stay inline prose)
    else:
        segs = [s.strip() for s in re.split(r",\s+(?:or\s+|and\s+)?", body) if s.strip()]
        if len(segs) >= 3 and sum(len(s) for s in segs) / len(segs) >= 25:
            items = segs
    if not items or len(items) < 3:
        return None
    # peel a trailing sentence off the last item ("...d. It then asks you to X.")
    trailing = None
    parts = _SENT.split(items[-1], maxsplit=1)
    if len(parts) == 2 and len(parts[1]) > 15:
        items[-1], trailing = parts[0], parts[1]
    items = [s.rstrip(" .,;") for s in items]
    return items, trailing


def reflow_tldr(tldr: str) -> str:
    """Turn an announced inline enumeration into a vertical list. No-op for
    everything else. Safe to apply to any final tldr string."""
    if not tldr or ":" not in tldr:
        return tldr
    out_beats = []
    for beat in tldr.split("\n\n"):
        if "\n" in beat:                       # already structured, leave it
            out_beats.append(beat); continue
        m = _ANNOUNCE.search(beat)
        if not m:
            out_beats.append(beat); continue
        res = _split_items(beat[m.end():])
        if not res:
            out_beats.append(beat); continue
        items, trailing = res
        out_beats.append(beat[:m.end()].rstrip() + "\n" + "\n".join(items))
        if trailing:
            out_beats.append(trailing.strip())
    return "\n\n".join(out_beats)


if __name__ == "__main__":
    import json, os, sys
    idx = os.path.join(os.path.dirname(__file__), "..", ".context", "runs_index.jsonl")
    tldrs = [json.loads(l).get("tldr") or "" for l in open(idx)]
    changed = [(t, reflow_tldr(t)) for t in tldrs if t and reflow_tldr(t) != t]
    print(f"corpus tldrs: {len(tldrs)} | changed by reflow: {len(changed)} "
          f"({100*len(changed)/len(tldrs):.1f}%)\n")
    for before, after in changed:
        print("BEFORE:", before[:220].replace("\n", " / "))
        print("AFTER :")
        for ln in after.split("\n"):
            print("   |", ln)
        print()
