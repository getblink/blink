from __future__ import annotations

import hashlib
import re
import statistics
import time
from pathlib import Path
from typing import Any

from gemini_runner import duration_ms
from ocr import recognize_text

NATIVE_SOURCE_OCR_REQUEST_MODE = "source_ocr_target_text_or_full_image"
NATIVE_SOURCE_PACKET_KIND = "native_ocr_paragraphs"
LOCAL_SOURCE_TEXT_PACKET_KIND = "local_source_text"
SOURCE_TEXT_MAX_CHARS = 8000
SOURCE_TEXT_PARAMETERS: dict[str, Any] = {
    "max_chars": SOURCE_TEXT_MAX_CHARS,
    "line_endings": "lf",
    "trim": "outer_blank_lines",
}
SOURCE_OCR_PARAMETERS: dict[str, Any] = {
    "uses_language_correction": True,
    "min_confidence": 0.25,
    "packet_variant": "dominant_content_band_sections_v2",
}

LIST_LINE_RE = re.compile(r"^(\d+[.)]|[-*•])\s+")
MENU_WORDS = {
    "file",
    "edit",
    "view",
    "insert",
    "format",
    "tools",
    "extensions",
    "help",
    "gemini",
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


def normalize_source_text(value: Any, *, max_chars: int = SOURCE_TEXT_MAX_CHARS) -> tuple[str, bool]:
    text = str(value or "").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    normalized = "\n".join(lines)
    truncated = False
    if len(normalized) > max_chars:
        normalized = normalized[:max_chars].rstrip()
        truncated = True
    return normalized, truncated


def build_local_source_text_packet(source_text_payload: dict[str, Any] | None) -> dict[str, Any]:
    started_perf = time.perf_counter()
    errors: list[str] = []
    warnings: list[str] = []
    source_text_status = None
    source_text_method = None
    source_text_chars = 0
    source_text_truncated = False

    if isinstance(source_text_payload, dict):
        source_text_status = source_text_payload.get("status")
        source_text_method = source_text_payload.get("method")
        warnings.extend(str(item) for item in source_text_payload.get("warnings") or [])
        raw_text = source_text_payload.get("text")
        try:
            source_text_chars = int(source_text_payload.get("text_chars") or 0)
        except (TypeError, ValueError):
            source_text_chars = 0
            errors.append("source_text_chars_invalid")
        source_text_truncated = bool(source_text_payload.get("truncated"))
    else:
        raw_text = None
        errors.append("source_text_payload_missing")

    if source_text_status != "ok":
        errors.append(f"source_text_status:{source_text_status or 'missing'}")

    packet_text, normalized_truncated = normalize_source_text(
        raw_text,
        max_chars=SOURCE_TEXT_MAX_CHARS,
    )
    source_text_truncated = source_text_truncated or normalized_truncated
    if not packet_text:
        errors.append("source_text_empty")

    status = "ok" if not errors else "error"
    if status != "ok":
        packet_text = ""

    build_ms = duration_ms(started_perf)
    return {
        "status": status,
        "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
        "packet_text": packet_text,
        "packet_chars": len(packet_text),
        "source_text_digest": (
            hashlib.sha256(packet_text.encode("utf-8")).hexdigest()
            if packet_text
            else None
        ),
        "build_ms": build_ms,
        "build_log": {
            "status": status,
            "request_build_ms": build_ms,
            "source_text_status": source_text_status,
            "source_text_method": source_text_method,
            "source_text_chars": source_text_chars,
            "source_text_truncated": source_text_truncated,
            "parameters": dict(SOURCE_TEXT_PARAMETERS),
            "warnings": warnings,
            "errors": errors,
        },
    }


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
                "block_ranks": [item["rank"] for item in group],
                "char_count": len(compact_text(text)),
            }
        )
    structured.sort(key=lambda item: (item["bbox"]["y"], item["bbox"]["x"]))
    for index, item in enumerate(structured, start=1):
        item["rank"] = index
    return structured


def _line_drop_reason(line: dict[str, Any], *, image_height: float) -> str | None:
    text = str(line.get("text") or "").strip()
    if not text:
        return "empty_text"

    top_limit = min(800.0, max(180.0, image_height * 0.16)) if image_height > 0 else 180.0
    if float(line["bbox"]["y"]) > top_limit:
        return None

    lower = text.lower()
    words = set(re.findall(r"[a-z]+", lower))
    if len(words & MENU_WORDS) >= 3:
        return "top_menu_bar"
    if re.search(r"\b(arial|helvetica|times|font|biu)\b", lower) and re.search(
        r"(\b\d{1,2}\b|[-+]|biu|bold|italic|underline)",
        lower,
    ):
        return "font_toolbar"
    if len(text) <= 24 and re.fullmatch(r"[0-9\s+\-:.,]+", text):
        return "top_numeric_control_row"
    return None


def filter_chrome_lines(
    lines: list[dict[str, Any]],
    *,
    image_height: float,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    kept: list[dict[str, Any]] = []
    dropped: list[dict[str, Any]] = []
    for line in lines:
        reason = _line_drop_reason(line, image_height=image_height)
        if reason:
            item = dict(line)
            item["drop_reason"] = reason
            dropped.append(item)
        else:
            kept.append(dict(line))
    for index, item in enumerate(kept, start=1):
        item["rank"] = index
    return kept, dropped


def _is_prompt_like_prefix(text: str) -> bool:
    stripped = text.strip()
    lower = stripped.lower()
    return (
        "?" in stripped
        or stripped.endswith(("*", ":"))
        or "please describe" in lower
    )


def _split_prompt_body_text(text: str) -> list[str]:
    stripped = text.strip()
    if len(stripped) < 120:
        return [text]
    candidates: list[tuple[str, str]] = []
    for match in re.finditer(r"(?<=[?.:])\s+", stripped):
        prefix = stripped[: match.start() + 1].strip()
        rest = stripped[match.end() :].strip()
        if not prefix or not rest:
            continue
        if len(prefix) > 240 or len(rest) < 60:
            continue
        if _is_prompt_like_prefix(prefix):
            candidates.append((prefix, rest))
    if not candidates:
        return [text]
    prefix, rest = candidates[-1]
    return [prefix, rest]


def split_prompt_body_lines(lines: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    structured: list[dict[str, Any]] = []
    split_logs: list[dict[str, Any]] = []
    for line in lines:
        pieces = _split_prompt_body_text(str(line.get("text") or ""))
        if len(pieces) == 1:
            structured.append(dict(line))
            continue
        split_logs.append(
            {
                "source_line_rank": line["rank"],
                "source_text": line["text"],
                "pieces": pieces,
            }
        )
        for index, piece in enumerate(pieces):
            item = dict(line)
            item["text"] = piece
            item["char_count"] = len(piece)
            item["split_from_rank"] = line["rank"]
            if index > 0:
                item["force_break_before"] = True
            if index < len(pieces) - 1:
                item["force_break_after"] = True
            structured.append(item)
    for index, item in enumerate(structured, start=1):
        item["rank"] = index
    return structured, split_logs


def _line_summary(line: dict[str, Any]) -> dict[str, Any]:
    summary = {
        "rank": line.get("rank"),
        "text": line.get("text"),
        "bbox": line.get("bbox"),
        "char_count": line.get("char_count"),
    }
    if line.get("drop_reason"):
        summary["drop_reason"] = line.get("drop_reason")
    if line.get("split_from_rank"):
        summary["split_from_rank"] = line.get("split_from_rank")
    return summary


def _is_list_line(text: str) -> bool:
    return bool(LIST_LINE_RE.match(text.strip()))


def _force_section_break(previous: dict[str, Any], line: dict[str, Any]) -> bool:
    if previous.get("force_break_after") or line.get("force_break_before"):
        return True
    previous_text = str(previous.get("text") or "").strip()
    line_text = str(line.get("text") or "").strip()
    if not previous_text or not line_text:
        return False
    if previous_text.endswith(("*", ":", "?")):
        return True
    if (
        len(previous_text) <= 140
        and len(line_text) >= max(60, len(previous_text) * 2)
        and _is_prompt_like_prefix(previous_text)
    ):
        return True
    return False


def _paragraph_text(group: list[dict[str, Any]]) -> str:
    if not group:
        return ""
    pieces = [str(group[0].get("text") or "").strip()]
    for line in group[1:]:
        text = str(line.get("text") or "").strip()
        previous_text = pieces[-1]
        separator = "\n" if _is_list_line(previous_text) or _is_list_line(text) else " "
        pieces.append(separator + text)
    return "".join(pieces).strip()


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
            not _force_section_break(previous, line)
            and gap <= max(22.0, median_height * 0.9)
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
        text = _paragraph_text(group)
        structured.append(
            {
                "rank": index,
                "text": text.strip(),
                "bbox": rect,
                "line_count": len(group),
                "line_ranks": [item["rank"] for item in group],
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
    image_height = float(image_size.get("height") or 0.0)
    raw_blocks = normalize_blocks(
        ocr_payload,
        min_confidence=float(SOURCE_OCR_PARAMETERS["min_confidence"]),
    )
    band = dominant_band(raw_blocks, image_width=image_width) if image_width > 0 else None
    filtered_blocks = filter_to_band(raw_blocks, band)
    raw_lines = group_blocks_into_lines(filtered_blocks)
    chrome_filtered_lines, dropped_lines = filter_chrome_lines(
        raw_lines,
        image_height=image_height,
    )
    lines, split_lines = split_prompt_body_lines(chrome_filtered_lines)
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
            "raw_line_count": len(raw_lines),
            "dropped_line_count": len(dropped_lines),
            "line_count": len(lines),
            "paragraph_count": len(paragraphs),
            "dominant_band": band,
            "ocr_blocks": raw_blocks,
            "filtered_block_ranks": [block["rank"] for block in filtered_blocks],
            "kept_lines": [_line_summary(line) for line in lines],
            "dropped_lines": [_line_summary(line) for line in dropped_lines],
            "split_lines": split_lines,
            "parameters": dict(SOURCE_OCR_PARAMETERS),
            "errors": errors,
        },
    }


def build_source_packet_with_fallback(
    *,
    source_path: Path,
    source_text_payload: dict[str, Any] | None,
) -> dict[str, Any]:
    result = build_local_source_text_packet(source_text_payload)
    if result["status"] == "ok":
        return result

    source_text_attempt = result["build_log"]
    result = build_native_ocr_source_packet(source_path=source_path)
    result["build_log"]["source_text_attempt"] = source_text_attempt
    result["build_log"].setdefault("warnings", []).append("fell_back_to_native_ocr")
    return result
