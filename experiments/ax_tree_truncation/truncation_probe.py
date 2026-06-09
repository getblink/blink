#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


AX_TREE_RE = re.compile(r"<ax_tree\b[^>]*>\s*(.*?)\s*</ax_tree>", re.DOTALL)


@dataclass(frozen=True)
class Line:
    index: int
    text: str
    depth: int
    chars: int


@dataclass(frozen=True)
class Selection:
    name: str
    text: str
    kept_indexes: list[int]
    chars: int


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare AX-tree truncation strategies against a saved tree.",
    )
    parser.add_argument("--input", required=True, help="Request JSON or raw AX tree text.")
    parser.add_argument("--out", required=True, help="Directory for report artifacts.")
    parser.add_argument(
        "--budget",
        type=int,
        default=40_000,
        help="Character budget to keep, matching server AX_TREE_MAX_CHARS by default.",
    )
    parser.add_argument(
        "--anchor-index",
        type=int,
        default=None,
        help="0-based AX tree line index to anchor around.",
    )
    parser.add_argument(
        "--anchor-ratio",
        type=float,
        default=None,
        help="Fallback anchor as a 0..1 position through emitted lines.",
    )
    parser.add_argument(
        "--anchor-text",
        default=None,
        help="Substring to locate the anchor line, useful for saved flat trees.",
    )
    parser.add_argument(
        "--anchor-occurrence",
        choices=("first", "last"),
        default="last",
        help="Which anchor-text match to use.",
    )
    parser.add_argument(
        "--after-ratio",
        type=float,
        default=0.65,
        help="Share of expandable anchored budget biased after the anchor.",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    ax_tree = extract_ax_tree(input_path.read_text(encoding="utf-8"))
    node_texts = rejoined_node_texts(ax_tree)
    collapsed_texts, collapse_stats = collapse_tandem_runs(node_texts)
    (out_dir / "collapsed.txt").write_text("\n".join(collapsed_texts), encoding="utf-8")

    # Strategies run on the collapsed tree, mirroring the shipped order (fold
    # duplication first, then window the remainder under budget).
    lines = [
        Line(
            index=i,
            text=t,
            depth=(len(t) - len(t.lstrip(" "))) // 2,
            chars=len(t) + 1,
        )
        for i, t in enumerate(collapsed_texts)
    ]
    if not lines:
        raise SystemExit("No AX tree lines found.")
    if args.budget <= 0:
        raise SystemExit("--budget must be positive.")
    if not 0 <= args.after_ratio <= 1:
        raise SystemExit("--after-ratio must be between 0 and 1.")

    anchor_index = resolve_anchor(
        lines,
        anchor_index=args.anchor_index,
        anchor_ratio=args.anchor_ratio,
        anchor_text=args.anchor_text,
        anchor_occurrence=args.anchor_occurrence,
    )

    selections = [
        select_head(lines, args.budget),
        select_tail(lines, args.budget),
        select_anchor(lines, args.budget, anchor_index, args.after_ratio),
    ]

    for selection in selections:
        (out_dir / f"{selection.name}.txt").write_text(selection.text, encoding="utf-8")

    report = build_report(
        input_path=input_path,
        budget=args.budget,
        after_ratio=args.after_ratio,
        anchor_index=anchor_index,
        lines=lines,
        selections=selections,
    )
    report["collapse"] = collapse_stats
    (out_dir / "report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    (out_dir / "summary.md").write_text(render_summary(report), encoding="utf-8")
    print(f"[ax-tree-truncation] wrote {out_dir}")
    print(render_console_summary(report))


def extract_ax_tree(raw: str) -> str:
    parsed = parse_json(raw)
    if isinstance(parsed, dict):
        envelope_tree = parsed.get("ax_tree")
        if isinstance(envelope_tree, str) and envelope_tree.strip():
            return envelope_tree.strip()
        extracted = find_ax_tree_text(parsed)
        if extracted:
            return strip_ax_header(extracted)
    match = AX_TREE_RE.search(raw)
    if match:
        return strip_ax_header(match.group(1))
    return raw.strip()


def parse_json(raw: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def find_ax_tree_text(value: Any) -> Optional[str]:
    if isinstance(value, dict):
        text = value.get("text")
        if isinstance(text, str):
            match = AX_TREE_RE.search(text)
            if match:
                return match.group(1)
        for child in value.values():
            found = find_ax_tree_text(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_ax_tree_text(child)
            if found:
                return found
    return None


def strip_ax_header(text: str) -> str:
    lines = [line.rstrip() for line in text.strip().splitlines()]
    if len(lines) >= 3 and lines[0].startswith("Accessibility tree of the active window"):
        return "\n".join(lines[2:]).strip()
    return "\n".join(lines).strip()


def parse_lines(ax_tree: str) -> list[Line]:
    lines: list[Line] = []
    for text in rejoined_node_texts(ax_tree):
        leading = len(text) - len(text.lstrip(" "))
        depth = leading // 2
        index = len(lines)
        lines.append(Line(index=index, text=text, depth=depth, chars=len(text) + 1))
    return lines


def rejoined_node_texts(ax_tree: str) -> list[str]:
    """One string per emitted node, undoing the lossy `\\n`.join.

    A node name/value can contain an embedded newline (e.g. a `pop up button`
    titled "Honorlock\\nHas access to this site"), so splitting the serialized
    tree on newlines shatters it into a phantom unindented line. The Swift
    capture folds duplication on the node array *before* joining, where this
    never happens; to backtest faithfully we re-fold any unindented
    continuation line (leading space 0, and not the root) into its predecessor.
    """
    nodes: list[str] = []
    for raw_line in ax_tree.splitlines():
        text = raw_line.rstrip()
        if not text:
            continue
        leading = len(text) - len(text.lstrip(" "))
        if nodes and leading == 0 and not text.startswith("standard window"):
            nodes[-1] = nodes[-1] + " " + text  # flatten, matching name handling
        else:
            nodes.append(text)
    return nodes


def collapse_tandem_runs(
    texts: list[str],
    *,
    min_gain: int = 2,
    max_period: int = 256,
) -> tuple[list[str], dict[str, Any]]:
    """Port of `WindowAXTreeCapture.collapseTandemRuns` for backtesting.

    Folds adjacent indent-normalized tandem repeats (subtree dups, sibling-run
    dups, single-line dups) into one copy plus an `[↑ … ×N …]` marker, recursing
    into the kept copy so nested repeats fold in one pass.
    """
    n = len(texts)
    if n <= 1:
        return list(texts), {"events": 0}

    depth = [(len(t) - len(t.lstrip(" "))) // 2 for t in texts]
    body = [t.lstrip(" ") for t in texts]
    positions: dict[str, list[int]] = {}
    for index, key in enumerate(body):
        positions.setdefault(key, []).append(index)

    def blocks_equal(a: int, b: int, p: int) -> bool:
        min_a = min(depth[a : a + p])
        min_b = min(depth[b : b + p])
        for t in range(p):
            if body[a + t] != body[b + t]:
                return False
            if depth[a + t] - min_a != depth[b + t] - min_b:
                return False
        return True

    out: list[str] = []
    events = 0

    def emit(lo: int, hi: int) -> None:
        nonlocal events
        i = lo
        while i < hi:
            best_period = best_count = best_gain = 0
            for j in positions.get(body[i], ()):
                if j <= i:
                    continue
                p = j - i
                if p > max_period or i + 2 * p > hi:
                    break
                if not blocks_equal(i, i + p, p):
                    continue
                k = 2
                while i + (k + 1) * p <= hi and blocks_equal(i, i + k * p, p):
                    k += 1
                gain = (k - 1) * p
                if gain >= min_gain and gain > best_gain:
                    best_gain, best_period, best_count = gain, p, k
            if best_gain > 0:
                p, k = best_period, best_count
                emit(i, i + p)
                if p == 1:
                    if out:
                        out[-1] = out[-1] + f"  [×{k}]"
                else:
                    indent = "  " * depth[i]
                    out.append(f"{indent}[↑ {p}-line block, ×{k} identical, shown once]")
                events += 1
                i += k * p
            else:
                out.append(texts[i])
                i += 1

    emit(0, n)
    before_chars = sum(len(t) + 1 for t in texts)
    after_chars = sum(len(t) + 1 for t in out)
    stats = {
        "events": events,
        "lines_before": n,
        "lines_after": len(out),
        "chars_before": before_chars,
        "chars_after": after_chars,
        "chars_reclaimed": before_chars - after_chars,
        "pct_reclaimed": round(100 * (before_chars - after_chars) / before_chars, 1)
        if before_chars
        else 0.0,
    }
    return out, stats


def resolve_anchor(
    lines: list[Line],
    *,
    anchor_index: Optional[int],
    anchor_ratio: Optional[float],
    anchor_text: Optional[str],
    anchor_occurrence: str,
) -> int:
    if anchor_index is not None:
        if not 0 <= anchor_index < len(lines):
            raise SystemExit(f"--anchor-index must be between 0 and {len(lines) - 1}.")
        return anchor_index
    if anchor_text:
        matches = [line.index for line in lines if anchor_text in line.text]
        if not matches:
            raise SystemExit(f"--anchor-text did not match any AX tree line: {anchor_text!r}")
        return matches[0] if anchor_occurrence == "first" else matches[-1]
    if anchor_ratio is not None:
        if not 0 <= anchor_ratio <= 1:
            raise SystemExit("--anchor-ratio must be between 0 and 1.")
        return min(len(lines) - 1, round(anchor_ratio * (len(lines) - 1)))
    return len(lines) - 1


def select_head(lines: list[Line], budget: int) -> Selection:
    return selection_from_indexes("head", lines, prefix_within_budget(lines, budget))


def select_tail(lines: list[Line], budget: int) -> Selection:
    kept: list[int] = []
    used = 0
    for line in reversed(lines):
        if used + line.chars > budget and kept:
            break
        if used + line.chars > budget:
            break
        kept.append(line.index)
        used += line.chars
    return selection_from_indexes("tail", lines, sorted(kept))


def select_anchor(
    lines: list[Line],
    budget: int,
    anchor_index: int,
    after_ratio: float,
) -> Selection:
    kept: set[int] = set(ancestor_indexes(lines, anchor_index))
    kept.add(anchor_index)
    used = sum(lines[index].chars for index in kept)

    if used >= budget:
        return selection_from_indexes("anchor", lines, sorted(kept))

    remaining = budget - used
    after_budget = int(remaining * after_ratio)
    before_budget = remaining - after_budget

    before = anchor_index - 1
    after = anchor_index + 1
    before_open = True
    after_open = True

    while before_open or after_open:
        progressed = False
        if after_open:
            added, after, after_budget, used = try_add_line(
                lines, kept, after, 1, after_budget, used, budget
            )
            progressed = progressed or added
            after_open = after < len(lines) and after_budget > 0
        if before_open:
            added, before, before_budget, used = try_add_line(
                lines, kept, before, -1, before_budget, used, budget
            )
            progressed = progressed or added
            before_open = before >= 0 and before_budget > 0
        if not progressed:
            break

    # If one side had short lines and left unused budget, fill from the other
    # side without changing the original after/before preference.
    while used < budget and (after < len(lines) or before >= 0):
        progressed = False
        if after < len(lines):
            added, after, _, used = try_add_line(
                lines, kept, after, 1, budget, used, budget
            )
            progressed = progressed or added
        if used < budget and before >= 0:
            added, before, _, used = try_add_line(
                lines, kept, before, -1, budget, used, budget
            )
            progressed = progressed or added
        if not progressed:
            break

    return selection_from_indexes("anchor", lines, sorted(kept))


def try_add_line(
    lines: list[Line],
    kept: set[int],
    index: int,
    step: int,
    side_budget: int,
    used: int,
    total_budget: int,
) -> tuple[bool, int, int, int]:
    if index < 0 or index >= len(lines) or side_budget <= 0:
        return False, index, side_budget, used
    line = lines[index]
    next_index = index + step
    if line.index in kept:
        return True, next_index, side_budget, used
    if line.chars > side_budget or used + line.chars > total_budget:
        return False, index, side_budget, used
    kept.add(line.index)
    return True, next_index, side_budget - line.chars, used + line.chars


def prefix_within_budget(lines: Iterable[Line], budget: int) -> list[int]:
    kept: list[int] = []
    used = 0
    for line in lines:
        if used + line.chars > budget:
            break
        kept.append(line.index)
        used += line.chars
    return kept


def ancestor_indexes(lines: list[Line], anchor_index: int) -> list[int]:
    ancestors: list[int] = []
    min_depth = lines[anchor_index].depth
    for index in range(anchor_index - 1, -1, -1):
        if lines[index].depth < min_depth:
            ancestors.append(index)
            min_depth = lines[index].depth
            if min_depth == 0:
                break
    return list(reversed(ancestors))


def selection_from_indexes(name: str, lines: list[Line], indexes: list[int]) -> Selection:
    if not indexes:
        return Selection(name=name, text="", kept_indexes=[], chars=0)
    index_set = set(indexes)
    output: list[str] = []
    previous: Optional[int] = None
    for index in indexes:
        if previous is not None and index != previous + 1:
            omitted = lines[previous + 1 : index]
            output.append(elision_line(omitted))
        output.append(lines[index].text)
        previous = index
    if indexes[0] > 0:
        output.insert(0, elision_line(lines[: indexes[0]]))
    if indexes[-1] < len(lines) - 1:
        output.append(elision_line(lines[indexes[-1] + 1 :]))
    text = "\n".join(output)
    chars = sum(lines[index].chars for index in index_set)
    return Selection(name=name, text=text, kept_indexes=indexes, chars=chars)


def elision_line(omitted: list[Line]) -> str:
    chars = sum(line.chars for line in omitted)
    return f"[... {len(omitted)} lines / {chars} chars omitted ...]"


def build_report(
    *,
    input_path: Path,
    budget: int,
    after_ratio: float,
    anchor_index: int,
    lines: list[Line],
    selections: list[Selection],
) -> dict[str, Any]:
    total_chars = sum(line.chars for line in lines)
    strategy_reports = {}
    for selection in selections:
        kept = selection.kept_indexes
        contains_anchor = anchor_index in set(kept)
        first = kept[0] if kept else None
        last = kept[-1] if kept else None
        before_anchor = [index for index in kept if index < anchor_index]
        after_anchor = [index for index in kept if index > anchor_index]
        segments = contiguous_segments(kept)
        strategy_reports[selection.name] = {
            "kept_lines": len(kept),
            "kept_chars": selection.chars,
            "kept_char_ratio": round(selection.chars / total_chars, 4) if total_chars else 0,
            "first_line": first,
            "last_line": last,
            "segments": segments,
            "contains_anchor": contains_anchor,
            "lines_before_anchor": len(before_anchor),
            "lines_after_anchor": len(after_anchor),
            "omitted_lines": len(lines) - len(kept),
            "omitted_chars": total_chars - selection.chars,
        }
    return {
        "input": str(input_path),
        "budget": budget,
        "after_ratio": after_ratio,
        "total_lines": len(lines),
        "total_chars": total_chars,
        "anchor_index": anchor_index,
        "anchor_depth": lines[anchor_index].depth,
        "anchor_line": lines[anchor_index].text,
        "strategies": strategy_reports,
    }


def contiguous_segments(indexes: list[int]) -> list[str]:
    if not indexes:
        return []
    segments: list[str] = []
    start = indexes[0]
    previous = indexes[0]
    for index in indexes[1:]:
        if index == previous + 1:
            previous = index
            continue
        segments.append(format_segment(start, previous))
        start = previous = index
    segments.append(format_segment(start, previous))
    return segments


def format_segment(start: int, end: int) -> str:
    return str(start) if start == end else f"{start}..{end}"


def render_console_summary(report: dict[str, Any]) -> str:
    collapse = report.get("collapse", {})
    parts = []
    if collapse:
        parts.append(
            f"collapse: {collapse['lines_before']}->{collapse['lines_after']} lines, "
            f"{collapse['chars_before']}->{collapse['chars_after']} chars "
            f"(-{collapse['pct_reclaimed']}%, {collapse['events']} folds)"
        )
    parts += [
        f"post-collapse total: {report['total_lines']} lines, {report['total_chars']} chars",
        f"anchor: line {report['anchor_index']} depth {report['anchor_depth']}: {report['anchor_line']}",
    ]
    for name, metrics in report["strategies"].items():
        parts.append(
            f"{name}: {metrics['kept_lines']} lines, {metrics['kept_chars']} chars, "
            f"anchor={metrics['contains_anchor']}, segments={','.join(metrics['segments'])}"
        )
    return "\n".join(parts)


def render_summary(report: dict[str, Any]) -> str:
    collapse = report.get("collapse", {})
    lines = [
        "# AX Tree Truncation Probe",
        "",
        f"- Input: `{report['input']}`",
        f"- Budget: `{report['budget']}` chars",
    ]
    if collapse:
        lines.append(
            f"- Collapse: `{collapse['lines_before']}`→`{collapse['lines_after']}` lines, "
            f"`{collapse['chars_before']}`→`{collapse['chars_after']}` chars "
            f"(**-{collapse['pct_reclaimed']}%**, `{collapse['events']}` folds)"
        )
    lines += [
        f"- Total (post-collapse): `{report['total_lines']}` lines, `{report['total_chars']}` chars",
        f"- Anchor: line `{report['anchor_index']}` depth `{report['anchor_depth']}`",
        "",
        "```text",
        report["anchor_line"],
        "```",
        "",
        "| Strategy | Kept lines | Kept chars | Contains anchor | Segments | Lines before/after anchor |",
        "|---|---:|---:|---|---|---|",
    ]
    for name, metrics in report["strategies"].items():
        segment_text = ", ".join(metrics["segments"])
        lines.append(
            f"| {name} | {metrics['kept_lines']} | {metrics['kept_chars']} | "
            f"{metrics['contains_anchor']} | {segment_text} | "
            f"{metrics['lines_before_anchor']}/{metrics['lines_after_anchor']} |"
        )
    lines.extend(
        [
            "",
            "Artifacts:",
            "",
            "- `collapsed.txt` is the tree after tandem-duplication folding (the shipped pre-windowing step).",
            "- `head.txt` models the current server clamp.",
            "- `tail.txt` models a simple recency-biased fallback.",
            "- `anchor.txt` keeps ancestors plus a window around the anchor.",
            "",
            "Strategies run on the collapsed tree, mirroring the shipped order (fold first, then window).",
        ]
    )
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
