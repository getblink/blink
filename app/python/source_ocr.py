from __future__ import annotations

import statistics
import time
from pathlib import Path
from typing import Any

from gemini_runner import duration_ms
from ocr import recognize_text

NATIVE_SOURCE_OCR_REQUEST_MODE = "source_ocr_target_text_or_full_image"
NATIVE_SOURCE_PACKET_KIND = "native_ocr_paragraphs"
SOURCE_OCR_PARAMETERS: dict[str, Any] = {
    "uses_language_correction": True,
    "min_confidence": 0.25,
    "packet_variant": "dominant_content_band_paragraphs",
}


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


def normalize_blocks(
    ocr_payload: dict[str, Any],
    *,
    min_confidence: float,
) -> list[dict[str, Any]]:
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
                "line_count": len(group),
            }
        )
    return structured


def paragraph_text_only(paragraphs: list[dict[str, Any]]) -> str:
    return "\n\n".join(paragraph["text"] for paragraph in paragraphs if paragraph["text"])


def build_native_ocr_source_packet(*, source_path: Path) -> dict[str, Any]:
    started_perf = time.perf_counter()
    ocr_payload = recognize_text(
        source_path,
        uses_language_correction=bool(SOURCE_OCR_PARAMETERS["uses_language_correction"]),
    )
    ocr_ms = duration_ms(started_perf)

    if ocr_payload.get("status") != "ok":
        error = str(ocr_payload.get("error") or "native OCR failed")
        return {
            "status": "error",
            "source_packet_kind": NATIVE_SOURCE_PACKET_KIND,
            "packet_text": "",
            "packet_chars": 0,
            "build_ms": duration_ms(started_perf),
            "build_log": {
                "status": "error",
                "ocr_ms": ocr_ms,
                "request_build_ms": duration_ms(started_perf),
                "ocr_status": ocr_payload.get("status"),
                "parameters": dict(SOURCE_OCR_PARAMETERS),
                "errors": [error],
            },
        }

    image_size = ocr_payload.get("image_size_pixels") or {}
    image_width = float(image_size.get("width") or 0.0)
    raw_blocks = normalize_blocks(
        ocr_payload,
        min_confidence=float(SOURCE_OCR_PARAMETERS["min_confidence"]),
    )
    band = dominant_band(raw_blocks, image_width=image_width) if image_width > 0 else None
    filtered_blocks = filter_to_band(raw_blocks, band)
    lines = group_blocks_into_lines(filtered_blocks)
    paragraphs = group_lines_into_paragraphs(lines)
    packet_text = paragraph_text_only(paragraphs).strip()

    errors: list[str] = []
    status = "ok"
    if not packet_text:
        status = "error"
        errors.append("native OCR paragraphs empty")

    return {
        "status": status,
        "source_packet_kind": NATIVE_SOURCE_PACKET_KIND,
        "packet_text": packet_text,
        "packet_chars": len(packet_text),
        "build_ms": duration_ms(started_perf),
        "build_log": {
            "status": status,
            "ocr_ms": ocr_ms,
            "request_build_ms": duration_ms(started_perf),
            "ocr_status": ocr_payload.get("status"),
            "image_size_pixels": image_size,
            "raw_block_count": len(raw_blocks),
            "filtered_block_count": len(filtered_blocks),
            "line_count": len(lines),
            "paragraph_count": len(paragraphs),
            "dominant_band": band,
            "ocr_blocks": raw_blocks,
            "filtered_block_ranks": [block["rank"] for block in filtered_blocks],
            "parameters": dict(SOURCE_OCR_PARAMETERS),
            "errors": errors,
        },
    }
