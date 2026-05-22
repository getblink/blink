#!/usr/bin/env python3
"""Compare two replay CSVs and report per-phase deltas + quality sanity."""
from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
from pathlib import Path


PHASE_COLUMNS = [
    "image_prep_ms",
    "multipart_build_ms",
    "connect_ms",
    "request_sent_ms",
    "ttfb_ms",
    "first_partial_tldr_ms",
    "first_partial_suggestions_ms",
    "final_event_ms",
    "server_duration_ms",
    "total_wall_ms",
]


def percentile(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] + (ys[c] - ys[f]) * (k - f)


def load(path: Path) -> dict[str, dict[str, str]]:
    by_bundle: dict[str, dict[str, str]] = {}
    with path.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            by_bundle[row["bundle"]] = row
    return by_bundle


def num(row: dict[str, str], col: str) -> float | None:
    v = row.get(col)
    if v is None or v == "" or v == "None":
        return None
    try:
        return float(v)
    except ValueError:
        return None


def col_stats(rows: list[dict[str, str]], col: str) -> dict[str, float] | None:
    xs = [num(r, col) for r in rows]
    xs = [x for x in xs if x is not None and x >= 0]
    if not xs:
        return None
    return {
        "n": len(xs),
        "p50": percentile(xs, 0.5),
        "p90": percentile(xs, 0.9),
        "mean": statistics.fmean(xs),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--paired", action="store_true", help="Only compare bundles in both sets")
    args = parser.parse_args()

    base = load(Path(args.baseline))
    cand = load(Path(args.candidate))

    if args.paired:
        keys = sorted(set(base.keys()) & set(cand.keys()))
        base_rows = [base[k] for k in keys]
        cand_rows = [cand[k] for k in keys]
        print(f"# paired n={len(keys)}")
    else:
        base_rows = list(base.values())
        cand_rows = list(cand.values())
        print(f"# unpaired base_n={len(base_rows)} cand_n={len(cand_rows)}")

    # OK-only quality filter
    base_ok = [r for r in base_rows if r.get("status") == "ok"]
    cand_ok = [r for r in cand_rows if r.get("status") == "ok"]
    print(f"# ok base={len(base_ok)} cand={len(cand_ok)}")

    print()
    print(f"{'phase':<32} {'base_p50':>10} {'cand_p50':>10} {'Δp50':>10} {'base_p90':>10} {'cand_p90':>10} {'Δp90':>10}")
    for col in PHASE_COLUMNS:
        b = col_stats(base_ok, col)
        c = col_stats(cand_ok, col)
        if b is None or c is None:
            continue
        d50 = c["p50"] - b["p50"]
        d90 = c["p90"] - b["p90"]
        print(f"{col:<32} {b['p50']:>10.0f} {c['p50']:>10.0f} {d50:>+10.0f} {b['p90']:>10.0f} {c['p90']:>10.0f} {d90:>+10.0f}")

    # Quality eyeball: count cand failures
    cand_err = [r for r in cand_rows if r.get("status") != "ok"]
    if cand_err:
        print(f"\n# candidate errors ({len(cand_err)}):")
        for r in cand_err[:5]:
            print(f"  {r['bundle']} status={r.get('status')} err={r.get('error')}")

    # Spot-check tldr text length distribution (proxy for quality regression)
    b_lens = [len(r.get("final_tldr") or "") for r in base_ok]
    c_lens = [len(r.get("final_tldr") or "") for r in cand_ok]
    if b_lens and c_lens:
        print(f"\n# tldr text length: base p50={percentile(b_lens, 0.5):.0f} cand p50={percentile(c_lens, 0.5):.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
