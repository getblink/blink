#!/usr/bin/env python3

from __future__ import annotations

import argparse
import glob
import html
import json
import os
import shutil
import statistics
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from ocr import recognize_text


BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent


@dataclass
class SourceRecord:
    fixture_id: str
    source_path: Path


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run local Vision OCR over source images, then emit raw and "
            "deterministically postprocessed artifacts for inspection."
        )
    )
    parser.add_argument(
        "--inputs",
        action="append",
        required=True,
        help=(
            "Glob for source image files or directories containing source.png, "
            "for example 'scratchpad/fixtures/*' or "
            "'~/Library/Application Support/Blink/runs/20260424-*'. "
            "Repeat for multiple patterns."
        ),
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output directory for experiment artifacts.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional cap on the number of sources to inspect.",
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=0.25,
        help="Drop OCR blocks below this confidence when building processed views.",
    )
    parser.add_argument(
        "--disable-language-correction",
        action="store_true",
        help="Disable Vision language correction.",
    )
    return parser.parse_args()


def resolve_from_root(path_str: str) -> Path:
    path = Path(path_str).expanduser()
    if path.is_absolute():
        return path
    return (ROOT_DIR / path).resolve()


def expand_globs(patterns: list[str]) -> list[Path]:
    matches: list[Path] = []
    seen: set[Path] = set()
    for pattern in patterns:
        absolute_pattern = pattern if pattern.startswith("/") else str(ROOT_DIR / pattern)
        for match in sorted(Path(item).resolve() for item in glob.glob(os.path.expanduser(absolute_pattern))):
            if match not in seen:
                seen.add(match)
                matches.append(match)
    return matches


def save_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def source_record(path: Path) -> SourceRecord | None:
    if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg"}:
        return SourceRecord(fixture_id=path.stem, source_path=path)
    if not path.is_dir():
        return None
    source_path = path / "source.png"
    if source_path.exists():
        return SourceRecord(fixture_id=path.name, source_path=source_path)
    return None


def rect_right(rect: dict[str, float]) -> float:
    return rect["x"] + rect["width"]


def rect_bottom(rect: dict[str, float]) -> float:
    return rect["y"] + rect["height"]


def horizontal_overlap(a: dict[str, float], b: dict[str, float]) -> float:
    return max(0.0, min(rect_right(a), rect_right(b)) - max(a["x"], b["x"]))


def horizontal_overlap_ratio(a: dict[str, float], b: dict[str, float]) -> float:
    denom = min(a["width"], b["width"])
    if denom <= 0:
        return 0.0
    return horizontal_overlap(a, b) / denom


def vertical_overlap_ratio(a: dict[str, float], b: dict[str, float]) -> float:
    overlap = max(0.0, min(rect_bottom(a), rect_bottom(b)) - max(a["y"], b["y"]))
    denom = min(a["height"], b["height"])
    if denom <= 0:
        return 0.0
    return overlap / denom


def union_rect(rects: list[dict[str, float]]) -> dict[str, float]:
    left = min(rect["x"] for rect in rects)
    top = min(rect["y"] for rect in rects)
    right = max(rect_right(rect) for rect in rects)
    bottom = max(rect_bottom(rect) for rect in rects)
    return {
        "x": round(left, 2),
        "y": round(top, 2),
        "width": round(right - left, 2),
        "height": round(bottom - top, 2),
    }


def compact_text(value: Any) -> str:
    return " ".join(str(value or "").split()).strip()


def normalize_blocks(ocr_payload: dict[str, Any], *, min_confidence: float) -> list[dict[str, Any]]:
    blocks: list[dict[str, Any]] = []
    for raw in ocr_payload.get("blocks") or []:
        bbox = raw.get("bbox_pixels")
        text = compact_text(raw.get("text"))
        if not isinstance(bbox, dict) or not text:
            continue
        try:
            rect = {
                "x": float(bbox["x"]),
                "y": float(bbox["y"]),
                "width": float(bbox["width"]),
                "height": float(bbox["height"]),
            }
        except (KeyError, TypeError, ValueError):
            continue
        confidence = float(raw.get("confidence") or 0.0)
        block = {
            "text": text,
            "bbox": rect,
            "confidence": round(confidence, 4),
            "cx": round(rect["x"] + rect["width"] / 2.0, 2),
            "cy": round(rect["y"] + rect["height"] / 2.0, 2),
            "char_count": len(text),
            "area": round(rect["width"] * rect["height"], 2),
            "kept_for_processing": confidence >= min_confidence,
        }
        blocks.append(block)
    blocks.sort(key=lambda item: (item["bbox"]["y"], item["bbox"]["x"]))
    for index, block in enumerate(blocks, start=1):
        block["rank"] = index
    return blocks


def dominant_band(blocks: list[dict[str, Any]], *, image_width: float) -> dict[str, Any] | None:
    candidate_blocks = [block for block in blocks if block["kept_for_processing"]]
    if not candidate_blocks:
        return None
    clusters: list[dict[str, Any]] = []
    tolerance = max(image_width * 0.025, 42.0)
    for block in candidate_blocks:
        score = max(block["char_count"], 1) * max(block["bbox"]["height"], 1.0)
        left = block["bbox"]["x"]
        matched = None
        for cluster in clusters:
            if abs(left - cluster["center_x"]) <= tolerance:
                matched = cluster
                break
        if matched is None:
            clusters.append(
                {
                    "left_values": [left],
                    "center_x": left,
                    "score": score,
                    "blocks": [block],
                }
            )
        else:
            matched["left_values"].append(left)
            matched["center_x"] = statistics.mean(matched["left_values"])
            matched["score"] += score
            matched["blocks"].append(block)
    best = max(clusters, key=lambda item: (item["score"], len(item["blocks"])))
    left = min(block["bbox"]["x"] for block in best["blocks"])
    right = max(rect_right(block["bbox"]) for block in best["blocks"])
    top = min(block["bbox"]["y"] for block in best["blocks"])
    bottom = max(rect_bottom(block["bbox"]) for block in best["blocks"])
    padding = max(image_width * 0.04, 28.0)
    return {
        "left": round(max(0.0, left - padding), 2),
        "right": round(right + padding, 2),
        "width": round((right - left) + 2 * padding, 2),
        "top": round(max(0.0, top - 80.0), 2),
        "bottom": round(bottom + 40.0, 2),
        "score": round(best["score"], 2),
        "block_count": len(best["blocks"]),
        "center_x": round(best["center_x"], 2),
        "seed_ranks": [block["rank"] for block in best["blocks"]],
    }


def filter_to_band(blocks: list[dict[str, Any]], band: dict[str, Any] | None) -> list[dict[str, Any]]:
    if band is None:
        return [block for block in blocks if block["kept_for_processing"]]
    filtered: list[dict[str, Any]] = []
    seed_ranks = set(band.get("seed_ranks") or [])
    band_rect = {
        "x": float(band["left"]),
        "y": 0.0,
        "width": float(band["width"]),
        "height": 1_000_000.0,
    }
    for block in blocks:
        if not block["kept_for_processing"]:
            continue
        if block["rank"] in seed_ranks:
            filtered.append(block)
            continue
        block_rect = block["bbox"]
        overlap = horizontal_overlap(block_rect, band_rect)
        overlap_ratio = overlap / max(block_rect["width"], 1.0)
        center_inside = band["left"] <= block["cx"] <= band["right"]
        vertically_aligned = band["top"] <= block["cy"] <= band["bottom"]
        left_aligned = block_rect["x"] >= band["left"] - max(80.0, band["width"] * 0.08)
        if vertically_aligned and (center_inside or (overlap_ratio >= 0.6 and left_aligned)):
            filtered.append(block)
    return filtered


def group_blocks_into_lines(blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not blocks:
        return []
    lines: list[list[dict[str, Any]]] = []
    for block in blocks:
        placed = False
        for current in lines:
            anchor = union_rect([item["bbox"] for item in current])
            vertical_overlap = vertical_overlap_ratio(block["bbox"], anchor)
            center_gap = abs(block["cy"] - (anchor["y"] + anchor["height"] / 2.0))
            tolerance = max(anchor["height"], block["bbox"]["height"]) * 0.7
            if vertical_overlap >= 0.45 or center_gap <= tolerance:
                current.append(block)
                current.sort(key=lambda item: item["bbox"]["x"])
                placed = True
                break
        if not placed:
            lines.append([block])
    structured: list[dict[str, Any]] = []
    for index, group in enumerate(lines, start=1):
        rect = union_rect([item["bbox"] for item in group])
        text = " ".join(item["text"] for item in sorted(group, key=lambda item: item["bbox"]["x"]))
        structured.append(
            {
                "rank": index,
                "text": compact_text(text),
                "bbox": rect,
                "block_ranks": [item["rank"] for item in group],
                "char_count": len(compact_text(text)),
            }
        )
    structured.sort(key=lambda item: (item["bbox"]["y"], item["bbox"]["x"]))
    for index, item in enumerate(structured, start=1):
        item["rank"] = index
    return structured


def group_lines_into_paragraphs(lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not lines:
        return []
    median_height = statistics.median(line["bbox"]["height"] for line in lines)
    paragraphs: list[list[dict[str, Any]]] = [[lines[0]]]
    for line in lines[1:]:
        current = paragraphs[-1]
        previous = current[-1]
        previous_rect = previous["bbox"]
        rect = line["bbox"]
        gap = rect["y"] - rect_bottom(previous_rect)
        x_offset = abs(rect["x"] - previous_rect["x"])
        overlap = horizontal_overlap_ratio(rect, previous_rect)
        same_paragraph = (
            gap <= max(22.0, median_height * 0.9)
            and x_offset <= max(36.0, min(previous_rect["width"], rect["width"]) * 0.25)
            and overlap >= 0.35
        )
        if same_paragraph:
            current.append(line)
        else:
            paragraphs.append([line])
    structured: list[dict[str, Any]] = []
    for index, group in enumerate(paragraphs, start=1):
        rect = union_rect([item["bbox"] for item in group])
        text = " ".join(item["text"] for item in group)
        structured.append(
            {
                "rank": index,
                "text": compact_text(text),
                "bbox": rect,
                "line_ranks": [item["rank"] for item in group],
                "line_count": len(group),
                "char_count": len(compact_text(text)),
            }
        )
    return structured


def build_sections(paragraphs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not paragraphs:
        return []
    sections: list[dict[str, Any]] = []
    index = 0
    while index < len(paragraphs):
        paragraph = paragraphs[index]
        next_paragraph = paragraphs[index + 1] if index + 1 < len(paragraphs) else None
        if next_paragraph is not None:
            gap = next_paragraph["bbox"]["y"] - rect_bottom(paragraph["bbox"])
            overlap = horizontal_overlap_ratio(paragraph["bbox"], next_paragraph["bbox"])
            short_header_like = paragraph["line_count"] == 1 and paragraph["char_count"] <= 48
            if short_header_like and gap <= max(20.0, paragraph["bbox"]["height"] * 1.1) and overlap >= 0.45:
                sections.append(
                    {
                        "rank": len(sections) + 1,
                        "header_candidate": paragraph["text"],
                        "body": next_paragraph["text"],
                        "header_paragraph_rank": paragraph["rank"],
                        "body_paragraph_rank": next_paragraph["rank"],
                    }
                )
                index += 2
                continue
        sections.append(
            {
                "rank": len(sections) + 1,
                "header_candidate": None,
                "body": paragraph["text"],
                "body_paragraph_rank": paragraph["rank"],
            }
        )
        index += 1
    return sections


def raw_block_text(blocks: list[dict[str, Any]]) -> str:
    lines = [
        describe_block(block)
        for block in blocks
    ]
    return "\n".join(lines).strip()


def paragraph_text(paragraphs: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    for paragraph in paragraphs:
        lines.append(f"[P{paragraph['rank']:02d}] {paragraph['text']}")
    return "\n".join(lines).strip()


def describe_block(block: dict[str, Any]) -> str:
    return (
        f"[{block['rank']:03d}] conf={block['confidence']:.3f} "
        f"x={block['bbox']['x']:.1f} y={block['bbox']['y']:.1f} "
        f"w={block['bbox']['width']:.1f} h={block['bbox']['height']:.1f} :: {block['text']}"
    )


def section_packet_text(
    *,
    raw_blocks: list[dict[str, Any]],
    filtered_blocks: list[dict[str, Any]],
    paragraphs: list[dict[str, Any]],
    sections: list[dict[str, Any]],
    band: dict[str, Any] | None,
) -> str:
    lines = [
        "SOURCE_VISION_OCR_PACKET",
        f"RAW_BLOCK_COUNT: {len(raw_blocks)}",
        f"FILTERED_BLOCK_COUNT: {len(filtered_blocks)}",
        f"PARAGRAPH_COUNT: {len(paragraphs)}",
    ]
    if band is None:
        lines.append("DOMINANT_CONTENT_BAND: none")
    else:
        lines.append(
            "DOMINANT_CONTENT_BAND: "
            f"x={band['left']:.1f}..{band['right']:.1f} "
            f"(width={band['width']:.1f}, supporting_blocks={band['block_count']})"
        )
    lines.extend(["", "SECTIONS:"])
    if not sections:
        lines.append("- none")
        return "\n".join(lines).strip()
    for section in sections:
        if section["header_candidate"]:
            lines.append(f"- header_candidate: {section['header_candidate']}")
            lines.append(f"  body: {section['body']}")
        else:
            lines.append(f"- body: {section['body']}")
    return "\n".join(lines).strip()


def render_case_html(
    *,
    fixture_id: str,
    image_name: str,
    image_width: int,
    image_height: int,
    raw_blocks: list[dict[str, Any]],
    filtered_blocks: list[dict[str, Any]],
    paragraphs: list[dict[str, Any]],
    sections: list[dict[str, Any]],
    band: dict[str, Any] | None,
) -> str:
    def block_boxes(blocks: list[dict[str, Any]], class_name: str) -> str:
        pieces = []
        for block in blocks:
            bbox = block["bbox"]
            label = html.escape(f"{block['rank']}: {block['text']}")
            pieces.append(
                (
                    f'<div class="box {class_name}" '
                    f'style="left:{bbox["x"]}px;top:{bbox["y"]}px;'
                    f'width:{bbox["width"]}px;height:{bbox["height"]}px;" '
                    f'title="{label}"></div>'
                )
            )
        return "\n".join(pieces)

    band_markup = ""
    if band is not None:
        band_markup = (
            f'<div class="band" style="left:{band["left"]}px;top:0px;'
            f'width:{band["width"]}px;height:{image_height}px;"></div>'
        )
    section_lines = []
    for section in sections:
        if section["header_candidate"]:
            section_lines.append(
                f"<li><strong>{html.escape(section['header_candidate'])}</strong>: "
                f"{html.escape(section['body'])}</li>"
            )
        else:
            section_lines.append(f"<li>{html.escape(section['body'])}</li>")
    paragraph_lines = [
        f"<li>P{item['rank']:02d}: {html.escape(item['text'])}</li>" for item in paragraphs
    ]
    raw_lines = [
        f"<li>{html.escape(describe_block(block))}</li>"
        for block in raw_blocks
    ]
    filtered_lines = [
        f"<li>{html.escape(describe_block(block))}</li>"
        for block in filtered_blocks
    ]
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{html.escape(fixture_id)} · Source OCR Review</title>
  <style>
    body {{
      font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
      margin: 24px;
      color: #111827;
      background: #f8fafc;
    }}
    h1, h2 {{
      margin: 0 0 12px 0;
    }}
    .layout {{
      display: grid;
      grid-template-columns: minmax(420px, {image_width}px) minmax(320px, 1fr);
      gap: 24px;
      align-items: start;
    }}
    .image-wrap {{
      position: relative;
      width: {image_width}px;
      height: {image_height}px;
      border: 1px solid #d1d5db;
      background: white;
      overflow: hidden;
      box-shadow: 0 8px 24px rgba(15, 23, 42, 0.08);
    }}
    .image-wrap img {{
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
    }}
    .box {{
      position: absolute;
      box-sizing: border-box;
      pointer-events: auto;
    }}
    .raw {{
      border: 1px solid rgba(239, 68, 68, 0.65);
      background: rgba(239, 68, 68, 0.08);
    }}
    .filtered {{
      border: 2px solid rgba(34, 197, 94, 0.8);
      background: rgba(34, 197, 94, 0.08);
    }}
    .band {{
      position: absolute;
      border-left: 2px solid rgba(59, 130, 246, 0.7);
      border-right: 2px solid rgba(59, 130, 246, 0.7);
      background: rgba(59, 130, 246, 0.06);
      pointer-events: none;
    }}
    .card {{
      background: white;
      border: 1px solid #e5e7eb;
      border-radius: 12px;
      padding: 16px;
      margin-bottom: 16px;
      box-shadow: 0 6px 18px rgba(15, 23, 42, 0.05);
    }}
    ul {{
      margin: 8px 0 0 20px;
      padding: 0;
    }}
    li {{
      margin: 4px 0;
      line-height: 1.35;
      word-break: break-word;
    }}
    .legend {{
      display: flex;
      gap: 12px;
      margin: 12px 0 0 0;
      font-size: 14px;
    }}
    .legend span::before {{
      content: "";
      display: inline-block;
      width: 12px;
      height: 12px;
      margin-right: 6px;
      vertical-align: middle;
      border-radius: 2px;
    }}
    .legend .raw-key::before {{
      background: rgba(239, 68, 68, 0.25);
      border: 1px solid rgba(239, 68, 68, 0.65);
    }}
    .legend .filtered-key::before {{
      background: rgba(34, 197, 94, 0.2);
      border: 2px solid rgba(34, 197, 94, 0.8);
    }}
    .legend .band-key::before {{
      background: rgba(59, 130, 246, 0.12);
      border: 1px solid rgba(59, 130, 246, 0.7);
    }}
  </style>
</head>
<body>
  <h1>{html.escape(fixture_id)}</h1>
  <div class="layout">
    <div>
      <div class="image-wrap">
        <img src="{html.escape(image_name)}" alt="{html.escape(fixture_id)} source screenshot">
        {band_markup}
        {block_boxes(raw_blocks, "raw")}
        {block_boxes(filtered_blocks, "filtered")}
      </div>
      <div class="legend">
        <span class="raw-key">raw OCR blocks</span>
        <span class="filtered-key">main-content blocks</span>
        <span class="band-key">dominant content band</span>
      </div>
    </div>
    <div>
      <div class="card">
        <h2>Sections</h2>
        <ul>
          {''.join(section_lines) if section_lines else '<li>none</li>'}
        </ul>
      </div>
      <div class="card">
        <h2>Paragraphs</h2>
        <ul>
          {''.join(paragraph_lines) if paragraph_lines else '<li>none</li>'}
        </ul>
      </div>
      <div class="card">
        <h2>Filtered Blocks</h2>
        <ul>
          {''.join(filtered_lines) if filtered_lines else '<li>none</li>'}
        </ul>
      </div>
      <div class="card">
        <h2>Raw Blocks</h2>
        <ul>
          {''.join(raw_lines) if raw_lines else '<li>none</li>'}
        </ul>
      </div>
    </div>
  </div>
</body>
</html>
"""


def render_index_html(rows: list[dict[str, Any]]) -> str:
    items = []
    for row in rows:
        items.append(
            "<tr>"
            f"<td><a href=\"{html.escape(row['fixture_id'])}/preview.html\">{html.escape(row['fixture_id'])}</a></td>"
            f"<td>{row['raw_block_count']}</td>"
            f"<td>{row['filtered_block_count']}</td>"
            f"<td>{row['paragraph_count']}</td>"
            f"<td>{row['dropped_block_count']}</td>"
            f"<td>{row['raw_char_count']}</td>"
            f"<td>{row['filtered_char_count']}</td>"
            "</tr>"
        )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Source OCR Experiment</title>
  <style>
    body {{
      font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
      margin: 24px;
      color: #111827;
      background: #f8fafc;
    }}
    table {{
      border-collapse: collapse;
      width: 100%;
      background: white;
      border: 1px solid #e5e7eb;
    }}
    th, td {{
      padding: 10px 12px;
      border-bottom: 1px solid #e5e7eb;
      text-align: left;
    }}
    th {{
      background: #f1f5f9;
    }}
    a {{
      color: #2563eb;
      text-decoration: none;
    }}
  </style>
</head>
<body>
  <h1>Source OCR Experiment</h1>
  <table>
    <thead>
      <tr>
        <th>Fixture</th>
        <th>Raw blocks</th>
        <th>Filtered blocks</th>
        <th>Paragraphs</th>
        <th>Dropped blocks</th>
        <th>Raw chars</th>
        <th>Filtered chars</th>
      </tr>
    </thead>
    <tbody>
      {''.join(items)}
    </tbody>
  </table>
</body>
</html>
"""


def summarize_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    def average(key: str) -> float | None:
        values = [float(item[key]) for item in results]
        if not values:
            return None
        return round(statistics.mean(values), 2)

    return {
        "fixture_count": len(results),
        "raw_block_count_avg": average("raw_block_count"),
        "filtered_block_count_avg": average("filtered_block_count"),
        "paragraph_count_avg": average("paragraph_count"),
        "dropped_block_count_avg": average("dropped_block_count"),
        "raw_char_count_avg": average("raw_char_count"),
        "filtered_char_count_avg": average("filtered_char_count"),
    }


def summary_markdown(
    *,
    out_dir: Path,
    inputs: list[str],
    results: list[dict[str, Any]],
    summary: dict[str, Any],
    min_confidence: float,
    uses_language_correction: bool,
) -> str:
    lines = [
        "# Source OCR Experiment",
        "",
        f"- Generated at: `{now_iso()}`",
        f"- Input patterns: `{', '.join(inputs)}`",
        f"- Fixture count: `{summary['fixture_count']}`",
        f"- Min confidence for processed views: `{min_confidence}`",
        f"- Uses language correction: `{uses_language_correction}`",
        f"- Raw block count avg: `{summary['raw_block_count_avg']}`",
        f"- Filtered block count avg: `{summary['filtered_block_count_avg']}`",
        f"- Paragraph count avg: `{summary['paragraph_count_avg']}`",
        f"- Dropped block count avg: `{summary['dropped_block_count_avg']}`",
        f"- Raw char count avg: `{summary['raw_char_count_avg']}`",
        f"- Filtered char count avg: `{summary['filtered_char_count_avg']}`",
        "",
        "## Per Fixture",
        "",
        "| Fixture | Raw blocks | Filtered blocks | Paragraphs | Dropped blocks | Raw chars | Filtered chars | Review |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for item in results:
        lines.append(
            f"| `{item['fixture_id']}` | `{item['raw_block_count']}` | "
            f"`{item['filtered_block_count']}` | `{item['paragraph_count']}` | "
            f"`{item['dropped_block_count']}` | `{item['raw_char_count']}` | "
            f"`{item['filtered_char_count']}` | "
            f"[preview]({item['fixture_id']}/preview.html) |"
        )
    lines.extend(
        [
            "",
            "## Artifacts",
            "",
            "- `benchmark.json` — run manifest plus per-fixture stats",
            "- `index.html` — review index with per-fixture links",
            "- `<fixture>/ocr.raw.json` — raw Vision OCR payload",
            "- `<fixture>/ocr.blocks.json` — normalized raw blocks",
            "- `<fixture>/ocr.filtered.json` — dominant-band filtered blocks",
            "- `<fixture>/ocr.paragraphs.json` — grouped paragraphs",
            "- `<fixture>/ocr.sections.json` — header-plus-body candidate sections",
            "- `<fixture>/ocr.raw.txt` — raw block list in reading order",
            "- `<fixture>/ocr.filtered.txt` — filtered block list",
            "- `<fixture>/ocr.packet.txt` — deterministic AI-friendly packet candidate",
            "- `<fixture>/preview.html` — screenshot with OCR overlays",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    out_dir = resolve_from_root(args.out)
    out_dir.mkdir(parents=True, exist_ok=False)
    uses_language_correction = not args.disable_language_correction

    records = [source_record(path) for path in expand_globs(args.inputs)]
    sources = [record for record in records if record is not None]
    if args.limit is not None:
        sources = sources[: args.limit]
    if not sources:
        raise ValueError("No source images found for the provided input patterns.")

    manifest = {
        "generated_at": now_iso(),
        "inputs": args.inputs,
        "uses_language_correction": uses_language_correction,
        "min_confidence": args.min_confidence,
        "fixtures": [],
    }
    rows: list[dict[str, Any]] = []

    for record in sources:
        print(f"[source-ocr] {record.fixture_id}")
        fixture_out = out_dir / record.fixture_id
        fixture_out.mkdir(parents=True, exist_ok=True)
        copied_source = fixture_out / record.source_path.name
        shutil.copy2(record.source_path, copied_source)

        ocr_payload = recognize_text(
            record.source_path,
            uses_language_correction=uses_language_correction,
        )
        save_json(fixture_out / "ocr.raw.json", ocr_payload)
        if ocr_payload.get("status") != "ok":
            row = {
                "fixture_id": record.fixture_id,
                "source_path": str(record.source_path),
                "status": ocr_payload.get("status"),
                "error": ocr_payload.get("error"),
                "raw_block_count": 0,
                "filtered_block_count": 0,
                "paragraph_count": 0,
                "dropped_block_count": 0,
                "raw_char_count": 0,
                "filtered_char_count": 0,
            }
            rows.append(row)
            manifest["fixtures"].append(row)
            continue

        image_size = ocr_payload.get("image_size_pixels") or {}
        image_width = int(image_size.get("width") or 0)
        image_height = int(image_size.get("height") or 0)
        raw_blocks = normalize_blocks(ocr_payload, min_confidence=args.min_confidence)
        band = dominant_band(raw_blocks, image_width=float(image_width))
        filtered_blocks = filter_to_band(raw_blocks, band)
        lines = group_blocks_into_lines(filtered_blocks)
        paragraphs = group_lines_into_paragraphs(lines)
        sections = build_sections(paragraphs)

        save_json(fixture_out / "ocr.blocks.json", raw_blocks)
        save_json(fixture_out / "ocr.filtered.json", filtered_blocks)
        save_json(fixture_out / "ocr.lines.json", lines)
        save_json(fixture_out / "ocr.paragraphs.json", paragraphs)
        save_json(fixture_out / "ocr.sections.json", sections)
        save_json(fixture_out / "ocr.analysis.json", {"dominant_band": band})

        (fixture_out / "ocr.raw.txt").write_text(raw_block_text(raw_blocks) + "\n", encoding="utf-8")
        (fixture_out / "ocr.filtered.txt").write_text(
            raw_block_text(filtered_blocks) + ("\n" if filtered_blocks else ""),
            encoding="utf-8",
        )
        (fixture_out / "ocr.paragraphs.txt").write_text(
            paragraph_text(paragraphs) + ("\n" if paragraphs else ""),
            encoding="utf-8",
        )
        packet_text = section_packet_text(
            raw_blocks=raw_blocks,
            filtered_blocks=filtered_blocks,
            paragraphs=paragraphs,
            sections=sections,
            band=band,
        )
        (fixture_out / "ocr.packet.txt").write_text(packet_text + "\n", encoding="utf-8")
        (fixture_out / "preview.html").write_text(
            render_case_html(
                fixture_id=record.fixture_id,
                image_name=copied_source.name,
                image_width=image_width,
                image_height=image_height,
                raw_blocks=raw_blocks,
                filtered_blocks=filtered_blocks,
                paragraphs=paragraphs,
                sections=sections,
                band=band,
            ),
            encoding="utf-8",
        )

        raw_char_count = sum(block["char_count"] for block in raw_blocks)
        filtered_char_count = sum(block["char_count"] for block in filtered_blocks)
        row = {
            "fixture_id": record.fixture_id,
            "source_path": str(record.source_path),
            "status": "ok",
            "raw_block_count": len(raw_blocks),
            "filtered_block_count": len(filtered_blocks),
            "paragraph_count": len(paragraphs),
            "dropped_block_count": max(0, len(raw_blocks) - len(filtered_blocks)),
            "raw_char_count": raw_char_count,
            "filtered_char_count": filtered_char_count,
            "dominant_band": band,
        }
        rows.append(row)
        manifest["fixtures"].append(row)

    summary = summarize_results(rows)
    manifest["summary"] = summary
    save_json(out_dir / "benchmark.json", manifest)
    (out_dir / "summary.md").write_text(
        summary_markdown(
            out_dir=out_dir,
            inputs=args.inputs,
            results=rows,
            summary=summary,
            min_confidence=args.min_confidence,
            uses_language_correction=uses_language_correction,
        ),
        encoding="utf-8",
    )
    (out_dir / "index.html").write_text(render_index_html(rows), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
