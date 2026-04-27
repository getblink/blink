#!/usr/bin/env python3
"""Run native Vision OCR + deterministic postprocessing on the 9 gold-labeled
source fixtures, with per-fixture latency and packet variants laid out for
compare_source_packets.py.

Packet variants per fixture (each scored separately against gold):
  - raw_text     : OCR block text only, reading order, joined by newlines.
                   No bbox/confidence chrome between blocks. This is the
                   fidelity upper bound for what Vision OCR alone can see.
  - filtered     : dominant-content-band filter only, text only.
  - paragraphs   : raw_text after paragraph grouping (lines joined within paragraphs).
  - sections     : full pipeline matching scratchpad/benchmark_source_ocr.py
                   (sections + paragraphs + dominant-band metadata header).
"""

from __future__ import annotations

import json
import shutil
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRATCHPAD = ROOT / "scratchpad"
sys.path.insert(0, str(SCRATCHPAD))

from ocr import recognize_text  # noqa: E402
from benchmark_source_ocr import (  # noqa: E402
    build_sections,
    dominant_band,
    filter_to_band,
    group_blocks_into_lines,
    group_lines_into_paragraphs,
    normalize_blocks,
    section_packet_text,
)


def text_only(blocks):
    """Return blocks as one text-per-line, reading order, no metadata."""
    return "\n".join(b["text"] for b in blocks)


def paragraph_text_only(paragraphs):
    """Paragraphs joined by blank lines, no rank labels."""
    return "\n\n".join(p["text"] for p in paragraphs)


FIXTURES_DIR = SCRATCHPAD / "fixtures"
GOLD_PATH = SCRATCHPAD / "gold_source_packets.json"
MIN_CONFIDENCE = 0.25
USES_LANGUAGE_CORRECTION = True


def main() -> int:
    out_dir = Path(__file__).resolve().parent / "native_ocr_runs"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    variant_dirs = {
        "raw_text": out_dir / "raw_text",
        "filtered": out_dir / "filtered",
        "paragraphs": out_dir / "paragraphs",
        "sections": out_dir / "sections",
    }
    for directory in variant_dirs.values():
        directory.mkdir(parents=True)

    gold = json.loads(GOLD_PATH.read_text(encoding="utf-8"))
    fixture_ids = sorted(gold.keys())

    records = []
    for fixture_id in fixture_ids:
        source_path = FIXTURES_DIR / fixture_id / "source.png"
        if not source_path.exists():
            print(f"[skip] {fixture_id} missing source.png", file=sys.stderr)
            continue
        print(f"[native-ocr] {fixture_id}")

        ocr_start = time.perf_counter()
        ocr_payload = recognize_text(
            source_path, uses_language_correction=USES_LANGUAGE_CORRECTION
        )
        ocr_ms = round((time.perf_counter() - ocr_start) * 1000.0, 2)

        if ocr_payload.get("status") != "ok":
            print(f"  ocr error: {ocr_payload.get('error')}", file=sys.stderr)
            continue

        post_start = time.perf_counter()
        image_size = ocr_payload.get("image_size_pixels") or {}
        image_width = float(image_size.get("width") or 0)
        raw_blocks = normalize_blocks(ocr_payload, min_confidence=MIN_CONFIDENCE)
        band = dominant_band(raw_blocks, image_width=image_width)
        filtered_blocks = filter_to_band(raw_blocks, band)
        lines = group_blocks_into_lines(filtered_blocks)
        paragraphs = group_lines_into_paragraphs(lines)
        sections = build_sections(paragraphs)
        post_ms = round((time.perf_counter() - post_start) * 1000.0, 2)

        variants = {
            # raw OCR block text in reading order, no bbox/conf metadata
            "raw_text": text_only(raw_blocks),
            # dominant-band filter, text only
            "filtered": text_only(filtered_blocks),
            # paragraphs after grouping, blank-line separated
            "paragraphs": paragraph_text_only(paragraphs),
            # full pipeline, matches benchmark_source_ocr ocr.packet.txt
            "sections": section_packet_text(
                raw_blocks=raw_blocks,
                filtered_blocks=filtered_blocks,
                paragraphs=paragraphs,
                sections=sections,
                band=band,
            ),
        }

        for label, body in variants.items():
            fixture_out = variant_dirs[label] / fixture_id
            fixture_out.mkdir(parents=True, exist_ok=True)
            (fixture_out / "source_packet.txt").write_text(
                body + ("\n" if body else ""), encoding="utf-8"
            )

        records.append(
            {
                "fixture_id": fixture_id,
                "ocr_ms": ocr_ms,
                "postprocess_ms": post_ms,
                "total_ms": round(ocr_ms + post_ms, 2),
                "raw_block_count": len(raw_blocks),
                "filtered_block_count": len(filtered_blocks),
                "raw_text_chars": len(variants["raw_text"]),
                "filtered_chars": len(variants["filtered"]),
                "paragraphs_chars": len(variants["paragraphs"]),
                "sections_chars": len(variants["sections"]),
            }
        )

    def avg(values):
        return round(statistics.mean(values), 2) if values else None

    summary = {
        "fixture_count": len(records),
        "min_confidence": MIN_CONFIDENCE,
        "uses_language_correction": USES_LANGUAGE_CORRECTION,
        "ocr_ms_avg": avg([r["ocr_ms"] for r in records]),
        "ocr_ms_median": round(
            statistics.median([r["ocr_ms"] for r in records]), 2
        )
        if records
        else None,
        "ocr_ms_min": min((r["ocr_ms"] for r in records), default=None),
        "ocr_ms_max": max((r["ocr_ms"] for r in records), default=None),
        "postprocess_ms_avg": avg([r["postprocess_ms"] for r in records]),
        "total_ms_avg": avg([r["total_ms"] for r in records]),
        "raw_block_count_avg": avg([r["raw_block_count"] for r in records]),
        "filtered_block_count_avg": avg([r["filtered_block_count"] for r in records]),
        "raw_text_chars_avg": avg([r["raw_text_chars"] for r in records]),
        "filtered_chars_avg": avg([r["filtered_chars"] for r in records]),
        "paragraphs_chars_avg": avg([r["paragraphs_chars"] for r in records]),
        "sections_chars_avg": avg([r["sections_chars"] for r in records]),
    }
    payload = {"summary": summary, "results": records}
    (out_dir / "latency.json").write_text(
        json.dumps(payload, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
