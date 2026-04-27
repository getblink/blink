from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path
from typing import Any

from gemini_runner import duration_ms, plain_data
from ocr import recognize_text

ZERO_WIDTH_CHARS = "\u200b\u200c\u200d\ufeff"
GOOGLE_DOCS_CARET_LINE_HEIGHT_PIXELS = 40
GOOGLE_DOCS_CARET_LINE_MAX_POINT_HEIGHT = 2
FIELD_LABEL_PREFIX_RE = re.compile(r"^(.{2,80}?[:?*])(?:\s|$|[\|¦▏▎▍▌▋▊▉█])")
CARETISH_SUFFIX_RE = re.compile(r"[\s\|¦▏▎▍▌▋▊▉█_]+$")


def normalize_focused_role(value: Any) -> str | None:
    role = compact_value(value)
    if role is None:
        return None
    return role[2:] if role.startswith("AX") else role


def image_size_pixels(image_path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    width = None
    height = None
    for raw_line in (result.stdout or "").splitlines():
        line = raw_line.strip()
        if line.startswith("pixelWidth:"):
            width = int(line.split(":", 1)[1].strip())
        elif line.startswith("pixelHeight:"):
            height = int(line.split(":", 1)[1].strip())
    if not width or not height:
        raise ValueError(f"Failed to read image size for {image_path}.")
    return width, height


def compact_value(value: Any, limit: int = 220) -> str | None:
    if value is None:
        return None
    text = str(value).strip().strip(ZERO_WIDTH_CHARS).strip()
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def is_google_docs_document_surface(target_metadata: dict[str, Any]) -> bool:
    label = normalize_text(str(target_metadata.get("focused_label") or ""))
    description = normalize_text(str(target_metadata.get("focused_description") or ""))
    app_bundle = str(target_metadata.get("focused_app_bundle_id") or "")
    return (
        "google" in app_bundle.lower()
        and (label == "document content" or description == "document content")
    )


def is_chromium_browser(target_metadata: dict[str, Any]) -> bool:
    app_bundle = str(target_metadata.get("focused_app_bundle_id") or "").lower()
    return app_bundle in {
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.canary",
        "com.microsoft.edgemac",
    }


def is_google_docs_thin_line_surface(target_metadata: dict[str, Any]) -> bool:
    return is_chromium_browser(target_metadata) and normalize_focused_role(
        target_metadata.get("focused_role")
    ) == "Group"


def clamp_rect(
    *,
    x: float,
    y: float,
    width: float,
    height: float,
    image_width: int,
    image_height: int,
) -> dict[str, int] | None:
    left = max(0, min(int(round(x)), image_width - 1))
    top = max(0, min(int(round(y)), image_height - 1))
    right = max(left + 1, min(int(round(x + width)), image_width))
    bottom = max(top + 1, min(int(round(y + height)), image_height))
    crop_width = right - left
    crop_height = bottom - top
    if crop_width <= 1 or crop_height <= 1:
        return None
    return {"x": left, "y": top, "width": crop_width, "height": crop_height}


def inflate_rect_vertically(
    rect: dict[str, int],
    *,
    image_height: int,
    target_height: int = GOOGLE_DOCS_CARET_LINE_HEIGHT_PIXELS,
) -> dict[str, int] | None:
    if target_height <= 1:
        return rect
    top = int(round(max(0.0, min(float(image_height - target_height), float(rect["y"])))))
    return {
        "x": rect["x"],
        "y": top,
        "width": rect["width"],
        "height": target_height,
    }


def focused_rect_local_pixels(
    target_metadata: dict[str, Any],
    geometry: dict[str, Any] | None,
    *,
    image_width: int,
    image_height: int,
) -> tuple[dict[str, int] | None, list[str], dict[str, Any]]:
    debug: dict[str, Any] = {"image_width": image_width, "image_height": image_height}
    if not isinstance(target_metadata, dict):
        return None, ["missing_target_metadata"], debug
    focused_bounds = target_metadata.get("focused_bounds")
    if not isinstance(focused_bounds, dict):
        return None, ["missing_focused_bounds"], debug
    debug["focused_bounds"] = plain_data(focused_bounds)

    if not isinstance(geometry, dict) or geometry.get("status") != "ok":
        return None, ["geometry_unavailable"], debug
    window_bounds = geometry.get("window_bounds_points")
    focused_bounds_points = geometry.get("focused_bounds_points") or focused_bounds
    if not isinstance(window_bounds, dict):
        return None, ["missing_window_bounds"], debug
    if not isinstance(focused_bounds_points, dict):
        return None, ["missing_geometry_focused_bounds"], debug

    try:
        wx = float(window_bounds["x"])
        wy = float(window_bounds["y"])
        ww = float(window_bounds["width"])
        wh = float(window_bounds["height"])
        fx = float(focused_bounds_points["x"])
        fy = float(focused_bounds_points["y"])
        fw = float(focused_bounds_points["width"])
        fh = float(focused_bounds_points["height"])
    except (KeyError, TypeError, ValueError):
        return None, ["invalid_geometry_values"], debug

    thin_line_surface = (
        is_google_docs_thin_line_surface(target_metadata)
        and 0 <= fh <= GOOGLE_DOCS_CARET_LINE_MAX_POINT_HEIGHT
        and fw > 0
    )
    if ww <= 0 or wh <= 0 or fw <= 0 or (fh <= 0 and not thin_line_surface):
        return None, ["nonpositive_geometry"], debug
    if is_google_docs_document_surface(target_metadata) and fh <= 2:
        debug["focus_rect_rejected"] = "google_docs_degenerate_focus_rect"
        return None, ["google_docs_degenerate_focus_rect"], debug

    geometry_height = max(fh, 1.0) if thin_line_surface else fh
    rel_x = (fx - wx) / ww
    rel_y = (fy - wy) / wh
    rel_w = fw / ww
    rel_h = geometry_height / wh
    debug["relative_focus"] = {
        "x": rel_x,
        "y": rel_y,
        "width": rel_w,
        "height": rel_h,
    }
    if rel_w <= 0 or rel_h <= 0:
        return None, ["invalid_relative_focus"], debug
    if rel_x < -0.3 or rel_y < -0.3 or rel_x > 1.3 or rel_y > 1.3:
        return None, ["focus_outside_window"], debug

    rect = clamp_rect(
        x=rel_x * image_width,
        y=rel_y * image_height,
        width=rel_w * image_width,
        height=rel_h * image_height,
        image_width=image_width,
        image_height=image_height,
    )
    if rect is None:
        return None, ["focus_rect_collapsed"], debug
    if thin_line_surface:
        debug["focus_rect_source"] = "google_docs_thin_caret_line"
        debug["local_line_rect"] = rect
        inflated = inflate_rect_vertically(rect, image_height=image_height)
        if inflated is None:
            return None, ["focus_rect_collapsed"], debug
        rect = inflated
    debug["local_focus_rect"] = rect
    return rect, [], debug


def rect_center(rect: dict[str, float]) -> tuple[float, float]:
    return rect["x"] + rect["width"] / 2.0, rect["y"] + rect["height"] / 2.0


def rects_intersect(a: dict[str, float], b: dict[str, float]) -> bool:
    return not (
        a["x"] + a["width"] <= b["x"]
        or b["x"] + b["width"] <= a["x"]
        or a["y"] + a["height"] <= b["y"]
        or b["y"] + b["height"] <= a["y"]
    )


def horizontal_overlap_ratio(a: dict[str, float], b: dict[str, float]) -> float:
    left = max(a["x"], b["x"])
    right = min(a["x"] + a["width"], b["x"] + b["width"])
    overlap = max(0.0, right - left)
    denom = min(a["width"], b["width"])
    if denom <= 0:
        return 0.0
    return overlap / denom


def vertical_overlap_ratio(a: dict[str, float], b: dict[str, float]) -> float:
    top = max(a["y"], b["y"])
    bottom = min(a["y"] + a["height"], b["y"] + b["height"])
    overlap = max(0.0, bottom - top)
    denom = min(a["height"], b["height"])
    if denom <= 0:
        return 0.0
    return overlap / denom


def dedupe_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        text = value.strip()
        key = text.lower()
        if not text or key in seen:
            continue
        seen.add(key)
        ordered.append(text)
    return ordered


def normalize_text(text: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", text.lower())
    return " ".join(tokens)


def normalize_label_key(text: str | None) -> str:
    return normalize_text(str(text or "").rstrip(":?*"))


def field_label_from_text(text: str) -> str | None:
    cleaned = CARETISH_SUFFIX_RE.sub("", text.strip().strip(ZERO_WIDTH_CHARS).strip())
    if not cleaned:
        return None
    match = FIELD_LABEL_PREFIX_RE.match(cleaned)
    if not match:
        return None
    label = match.group(1).strip()
    if not any(char.isalpha() for char in label):
        return None
    return label if len(label) >= 4 else None


def metadata_text_candidates(target_metadata: dict[str, Any]) -> list[str]:
    candidates: list[str] = []
    for key in ("focused_label", "focused_description", "focused_title", "focused_value_preview"):
        value = compact_value(target_metadata.get(key), limit=220)
        if value:
            candidates.append(value)
    focused_value = target_metadata.get("focused_value")
    if isinstance(focused_value, str) and focused_value.strip():
        for line in focused_value.splitlines():
            compact = compact_value(line, limit=220)
            if compact and len(normalize_text(compact)) >= 8:
                candidates.append(compact)
    return dedupe_preserve_order(candidates)


def parse_ocr_blocks(ocr_payload: dict[str, Any]) -> list[dict[str, Any]]:
    blocks = []
    for block in ocr_payload.get("blocks") or []:
        bbox = block.get("bbox_pixels")
        text = compact_value(block.get("text"), limit=160)
        if not isinstance(bbox, dict) or not text:
            continue
        confidence = float(block.get("confidence") or 0.0)
        if confidence < 0.25:
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
        cx, cy = rect_center(rect)
        blocks.append({"text": text, "bbox": rect, "cx": cx, "cy": cy})

    blocks.sort(key=lambda item: (item["bbox"]["y"], item["bbox"]["x"]))
    return blocks


def ocr_anchor_focus_rect(
    ocr_payload: dict[str, Any],
    target_metadata: dict[str, Any],
    *,
    image_width: int,
    image_height: int,
) -> tuple[dict[str, int] | None, list[str], dict[str, Any]]:
    candidates = metadata_text_candidates(target_metadata)
    blocks = parse_ocr_blocks(ocr_payload)
    debug: dict[str, Any] = {
        "candidate_count": len(candidates),
        "candidate_examples": candidates[:8],
    }
    matches: list[tuple[int, dict[str, Any], str]] = []
    for block in blocks:
        block_norm = normalize_text(block["text"])
        if len(block_norm) < 4:
            continue
        best_score = 0
        best_candidate = ""
        block_tokens = set(block_norm.split())
        for candidate in candidates:
            cand_norm = normalize_text(candidate)
            if len(cand_norm) < 4:
                continue
            score = 0
            if block_norm in cand_norm or cand_norm in block_norm:
                score = min(len(block_norm), len(cand_norm))
            else:
                overlap = block_tokens & set(cand_norm.split())
                if len(overlap) >= 2:
                    score = 10 + len(overlap)
            if score > best_score:
                best_score = score
                best_candidate = candidate
        if best_score > 0:
            matches.append((best_score, block, best_candidate))

    if not matches:
        debug["match_examples"] = []
        return None, ["no_ocr_anchor_match"], debug

    matches.sort(key=lambda item: (-item[0], item[1]["bbox"]["y"], item[1]["bbox"]["x"]))
    max_score = matches[0][0]
    selected = [item for item in matches if item[0] >= max(10, max_score // 2)][:6]
    debug["match_examples"] = [
        {
            "score": score,
            "block_text": block["text"],
            "candidate": candidate,
        }
        for score, block, candidate in selected[:6]
    ]

    min_x = min(item[1]["bbox"]["x"] for item in selected)
    min_y = min(item[1]["bbox"]["y"] for item in selected)
    max_x = max(item[1]["bbox"]["x"] + item[1]["bbox"]["width"] for item in selected)
    max_y = max(item[1]["bbox"]["y"] + item[1]["bbox"]["height"] for item in selected)
    rect = clamp_rect(
        x=min_x - max(140.0, (max_x - min_x) * 0.8),
        y=min_y - max(100.0, (max_y - min_y) * 1.2),
        width=(max_x - min_x) + 2 * max(140.0, (max_x - min_x) * 0.8),
        height=(max_y - min_y) + 2 * max(100.0, (max_y - min_y) * 1.2),
        image_width=image_width,
        image_height=image_height,
    )
    if rect is None:
        return None, ["ocr_anchor_rect_invalid"], debug
    debug["anchor_rect"] = rect
    return rect, [], debug


def select_target_ocr_context(
    ocr_payload: dict[str, Any],
    focus_rect: dict[str, int] | None,
) -> dict[str, list[str]]:
    blocks = parse_ocr_blocks(ocr_payload)
    if focus_rect is None:
        return {
            "inside": [],
            "above": [],
            "left": [],
            "below": [],
            "nearby": [item["text"] for item in blocks[:12]],
        }

    focus = {k: float(v) for k, v in focus_rect.items()}
    expanded = {
        "x": max(0.0, focus["x"] - max(focus["width"] * 0.8, 180.0)),
        "y": max(0.0, focus["y"] - max(focus["height"] * 1.0, 140.0)),
        "width": focus["width"] + 2 * max(focus["width"] * 0.8, 180.0),
        "height": focus["height"] + 2 * max(focus["height"] * 1.0, 140.0),
    }

    inside: list[str] = []
    above: list[str] = []
    left: list[str] = []
    below: list[str] = []
    nearby: list[str] = []

    for item in blocks:
        rect = item["bbox"]
        if rects_intersect(rect, focus):
            inside.append(item["text"])
            continue

        if item["cy"] < focus["y"]:
            gap = focus["y"] - (rect["y"] + rect["height"])
            if gap <= max(160.0, focus["height"] * 1.5) and horizontal_overlap_ratio(rect, focus) >= 0.2:
                above.append(item["text"])
                continue

        if item["cx"] < focus["x"]:
            gap = focus["x"] - (rect["x"] + rect["width"])
            if gap <= max(220.0, focus["width"] * 0.6) and vertical_overlap_ratio(rect, focus) >= 0.2:
                left.append(item["text"])
                continue

        if item["cy"] > focus["y"] + focus["height"]:
            gap = rect["y"] - (focus["y"] + focus["height"])
            if gap <= max(180.0, focus["height"] * 1.5) and horizontal_overlap_ratio(rect, focus) >= 0.2:
                below.append(item["text"])
                continue

        if rects_intersect(rect, expanded):
            nearby.append(item["text"])

    return {
        "inside": dedupe_preserve_order(inside)[:6],
        "above": dedupe_preserve_order(above)[:6],
        "left": dedupe_preserve_order(left)[:6],
        "below": dedupe_preserve_order(below)[:6],
        "nearby": dedupe_preserve_order(nearby)[:10],
    }


def looks_like_field_label(text: str) -> bool:
    return field_label_from_text(text) is not None


def looks_like_same_row_field_label(text: str) -> bool:
    stripped = field_label_from_text(text) or ""
    return (
        stripped.endswith(":")
        and any(char.isalpha() for char in stripped)
        and len(stripped) >= 4
    )


def focused_label_hint_from_ocr(
    ocr_payload: dict[str, Any],
    focus_rect: dict[str, int] | None,
) -> tuple[str | None, list[str], dict[str, Any]]:
    debug: dict[str, Any] = {}
    if focus_rect is None:
        return None, ["missing_focus_rect"], debug

    focus = {key: float(value) for key, value in focus_rect.items()}
    focus_cx, focus_cy = rect_center(focus)
    candidates: list[tuple[float, str, dict[str, Any], dict[str, float]]] = []
    for item in parse_ocr_blocks(ocr_payload):
        raw_text = item["text"]
        label_text = field_label_from_text(raw_text)
        if label_text is None:
            continue
        rect = item["bbox"]
        item = {**item, "text": label_text, "raw_text": raw_text}

        if looks_like_same_row_field_label(label_text):
            if rects_intersect(rect, focus):
                candidates.append(
                    (
                        -100.0,
                        "inside",
                        item,
                        {
                            "overlap": vertical_overlap_ratio(rect, focus),
                        },
                    )
                )

            vertical_distance = abs(item["cy"] - focus_cy)
            left_gap = focus["x"] - (rect["x"] + rect["width"])
            slight_overlap = rect["x"] <= focus["x"] <= rect["x"] + rect["width"] + 80.0
            plausible_left = -100.0 <= left_gap <= max(320.0, focus["width"] * 0.25)
            if vertical_distance <= max(70.0, focus["height"] * 1.75) and (
                plausible_left or slight_overlap
            ):
                candidates.append(
                    (
                        vertical_distance + abs(left_gap) * 0.08,
                        "same_row",
                        item,
                        {
                            "vertical_distance": vertical_distance,
                            "left_gap": left_gap,
                        },
                    )
                )

        above_gap = focus["y"] - (rect["y"] + rect["height"])
        if above_gap >= 0:
            overlap = horizontal_overlap_ratio(rect, focus)
            center_distance = abs(item["cx"] - focus_cx)
            if (
                above_gap <= max(220.0, focus["height"] * 2.5)
                and (overlap >= 0.15 or center_distance <= max(220.0, focus["width"] * 0.75))
            ):
                candidates.append(
                    (
                        above_gap + center_distance * 0.05,
                        "above",
                        item,
                        {"gap": above_gap, "overlap": overlap, "center_distance": center_distance},
                    )
                )

        left_gap = focus["x"] - (rect["x"] + rect["width"])
        if left_gap >= 0:
            overlap = vertical_overlap_ratio(rect, focus)
            center_distance = abs(item["cy"] - focus_cy)
            if (
                left_gap <= max(260.0, focus["width"] * 0.8)
                and (overlap >= 0.2 or center_distance <= max(80.0, focus["height"] * 0.75))
            ):
                candidates.append(
                    (
                        left_gap + center_distance * 0.1 + 25.0,
                        "left",
                        item,
                        {"gap": left_gap, "overlap": overlap, "center_distance": center_distance},
                    )
                )

    debug["candidate_count"] = len(candidates)
    debug["candidate_examples"] = [
        {
            "text": item["text"],
            "relation": relation,
            **metrics,
        }
        for _, relation, item, metrics in sorted(candidates, key=lambda candidate: candidate[0])[:6]
    ]
    if not candidates:
        return None, ["no_label_like_ocr_block_near_focus"], debug

    _, relation, selected, metrics = sorted(candidates, key=lambda candidate: candidate[0])[0]
    debug["selected"] = {
        "text": selected["text"],
        "relation": relation,
        **metrics,
    }
    return selected["text"], [], debug


def focused_row_labels(sections: dict[str, list[str]]) -> list[str]:
    return dedupe_preserve_order(
        [
            label
            for text in sections.get("inside") or []
            for label in [field_label_from_text(text)]
            if label is not None
        ]
    )


def build_target_ocr_packet(
    *,
    target_path: Path,
    target_metadata: dict[str, Any],
    geometry: dict[str, Any] | None,
) -> dict[str, Any]:
    started_perf = time.perf_counter()
    ocr_started_perf = time.perf_counter()
    ocr_payload = recognize_text(target_path, uses_language_correction=True)
    ocr_ms = duration_ms(ocr_started_perf)
    image_width, image_height = image_size_pixels(target_path)
    focus_rect, focus_reasons, focus_debug = focused_rect_local_pixels(
        target_metadata,
        geometry,
        image_width=image_width,
        image_height=image_height,
    )
    if focus_rect is None and ocr_payload.get("status") == "ok":
        anchor_rect, anchor_reasons, anchor_debug = ocr_anchor_focus_rect(
            ocr_payload,
            target_metadata,
            image_width=image_width,
            image_height=image_height,
        )
        focus_debug["ocr_anchor_fallback"] = anchor_debug
        if anchor_rect is not None:
            focus_rect = anchor_rect
            focus_reasons = []
        else:
            focus_debug["ocr_anchor_reasons"] = anchor_reasons

    label_hint = None
    label_hint_reasons: list[str] = []
    label_hint_debug: dict[str, Any] = {}
    if focus_rect is not None and ocr_payload.get("status") == "ok":
        label_hint, label_hint_reasons, label_hint_debug = focused_label_hint_from_ocr(
            ocr_payload,
            focus_rect,
        )

    metadata_lines = []
    for key in ("focused_label", "focused_description", "focused_title", "focused_role"):
        value = compact_value(target_metadata.get(key))
        if value:
            metadata_lines.append(f"- {key}: {value}")
    existing_value = compact_value(
        target_metadata.get("focused_value") or target_metadata.get("focused_value_preview"),
        limit=280,
    )
    if existing_value:
        metadata_lines.append(f"- focused_value: {existing_value}")

    sections = select_target_ocr_context(ocr_payload, focus_rect)
    inside_labels = focused_row_labels(sections)
    completeness_reasons = list(focus_reasons)
    if ocr_payload.get("status") != "ok":
        completeness_reasons.append("ocr_failed")
    if (
        label_hint
        and inside_labels
        and all(normalize_label_key(label_hint) != normalize_label_key(label) for label in inside_labels)
    ):
        completeness_reasons.append("focused_label_conflicts_inside_row")
    if (
        not label_hint
        and is_google_docs_thin_line_surface(target_metadata)
        and focus_debug.get("focus_rect_source") == "google_docs_thin_caret_line"
    ):
        completeness_reasons.append("google_docs_missing_focused_label")
    useful_text = bool(label_hint) or any(sections[name] for name in ("inside", "above", "left", "below"))
    if not useful_text and not existing_value and len(metadata_lines) <= 1:
        completeness_reasons.append("no_local_target_text")

    completeness = "needs_target_image" if completeness_reasons else "sufficient"
    lines = []
    if label_hint:
        lines.append(f"FOCUSED_FIELD_LABEL: {label_hint}")

    packet_text = "\n".join(lines).strip()
    status = "ok" if ocr_payload.get("status") == "ok" else "error"
    return {
        "status": status,
        "packet_text": packet_text,
        "packet_chars": len(packet_text),
        "completeness": completeness,
        "fallback_reasons": completeness_reasons,
        "build_log": {
            "status": status,
            "ocr_ms": ocr_ms,
            "request_build_ms": duration_ms(started_perf),
            "image_size_pixels": {"width": image_width, "height": image_height},
            "focus_rect_local_pixels": focus_rect,
            "focus_debug": focus_debug,
            "ocr_status": ocr_payload.get("status"),
            "ocr_block_count": len(ocr_payload.get("blocks") or []),
            "ocr_blocks": plain_data(parse_ocr_blocks(ocr_payload)),
            "selected_text": sections,
            "focused_row_labels": inside_labels,
            "focused_label_hint": label_hint,
            "focus_hint_debug": label_hint_debug,
            "focus_hint_reasons": label_hint_reasons,
            "completeness": completeness,
            "fallback_reasons": completeness_reasons,
            "errors": [ocr_payload.get("error")] if ocr_payload.get("error") else [],
        },
        "focused_label_hint": label_hint,
    }
