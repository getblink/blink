#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from google.genai import types

from benchmark_source_packet import (
    BASELINE_PROMPT_PATH,
    DEFAULT_CONFIG_PATH,
    ROOT_DIR,
    baseline_generate_completion,
    build_client,
    build_source_packet,
    exact_match,
    expand_glob,
    format_ms,
    load_json_file,
    load_settings,
    now_iso,
    plain_data,
    resolve_from_root,
    run_source_packet_target,
    run_stream_request,
    save_json_file,
    total_request_path_ms,
)
from env_loader import load_workspace_env
from gemini_runner import duration_ms, prepare_request_image
from ocr import recognize_text
from providers import MissingCredentialError


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_SOURCE_PACKET_EXTRACT_PROMPT_PATH = (
    BASE_DIR / "source_packet_extract_prompt_v3_ocr.txt"
)
DEFAULT_FULL_IMAGE_TARGET_PROMPT_PATH = (
    BASE_DIR / "source_packet_target_prompt_v3_ocr.txt"
)
DEFAULT_TARGET_OCR_PROMPT_PATH = BASE_DIR / "target_context_prompt_ocr.txt"
DEFAULT_TARGET_CROP_PROMPT_PATH = BASE_DIR / "target_context_prompt_crop.txt"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark target-context variants on top of cached source packets.",
    )
    parser.add_argument(
        "--fixtures",
        required=True,
        help="Glob for fixture directories, e.g. 'scratchpad/fixtures/*'.",
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG_PATH),
        help="Config JSON to use for all model calls.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output directory for benchmark artifacts.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional cap on number of fixtures.",
    )
    parser.add_argument(
        "--reuse-counts",
        default="1,3,5",
        help="Comma-separated reuse counts for amortized source-packet estimates.",
    )
    parser.add_argument(
        "--source-extract-prompt-path",
        default=str(DEFAULT_SOURCE_PACKET_EXTRACT_PROMPT_PATH),
        help="Path to the source-packet extraction prompt.",
    )
    parser.add_argument(
        "--full-image-target-prompt-path",
        default=str(DEFAULT_FULL_IMAGE_TARGET_PROMPT_PATH),
        help="Prompt for source-packet + full target image playback.",
    )
    parser.add_argument(
        "--target-ocr-prompt-path",
        default=str(DEFAULT_TARGET_OCR_PROMPT_PATH),
        help="Prompt for source-packet + target OCR packet playback.",
    )
    parser.add_argument(
        "--target-crop-prompt-path",
        default=str(DEFAULT_TARGET_CROP_PROMPT_PATH),
        help="Prompt for source-packet + focused target crop playback.",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=int,
        default=None,
        help="Optional override for settings.max_output_tokens during the benchmark.",
    )
    return parser.parse_args()


def fixture_record(fixture_dir: Path) -> dict[str, Any]:
    manifest = load_json_file(fixture_dir / "fixture.json")
    geometry_path = None
    geometry_payload = None
    geometry_meta = manifest.get("geometry")
    if isinstance(geometry_meta, dict) and geometry_meta.get("path"):
        geometry_path = fixture_dir / geometry_meta["path"]
        if geometry_path.exists():
            geometry_payload = load_json_file(geometry_path)
    return {
        "fixture_id": manifest["fixture_id"],
        "fixture_dir": fixture_dir,
        "manifest": manifest,
        "source_path": fixture_dir / manifest["source"]["image_path"],
        "target_path": fixture_dir / manifest["target"]["image_path"],
        "target_metadata": manifest["target_metadata"],
        "geometry_path": geometry_path,
        "geometry": geometry_payload,
    }


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
    text = str(value).strip()
    if not text:
        return None
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


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


def focused_rect_local_pixels(
    target_metadata: dict[str, Any],
    geometry: dict[str, Any] | None,
    *,
    image_width: int,
    image_height: int,
) -> tuple[dict[str, int] | None, list[str], dict[str, Any]]:
    reasons: list[str] = []
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

    if ww <= 0 or wh <= 0 or fw <= 0 or fh <= 0:
        return None, ["nonpositive_geometry"], debug

    rel_x = (fx - wx) / ww
    rel_y = (fy - wy) / wh
    rel_w = fw / ww
    rel_h = fh / wh
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
    debug["local_focus_rect"] = rect
    return rect, reasons, debug


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


def metadata_text_candidates(target_metadata: dict[str, Any]) -> list[str]:
    candidates: list[str] = []
    for key in ("focused_label", "focused_description", "focused_title", "focused_value_preview"):
        value = compact_value(target_metadata.get(key), limit=220)
        if value:
            candidates.append(value)
    focused_value = target_metadata.get("focused_value")
    if isinstance(focused_value, str) and focused_value.strip():
        for line in focused_value.splitlines():
            line = compact_value(line, limit=220)
            if line and len(normalize_text(line)) >= 8:
                candidates.append(line)
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
        blocks.append(
            {
                "text": text,
                "bbox": rect,
                "cx": cx,
                "cy": cy,
            }
        )

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
    completeness_reasons = list(focus_reasons)
    if ocr_payload.get("status") != "ok":
        completeness_reasons.append("ocr_failed")
    useful_text = any(sections[name] for name in ("inside", "above", "left", "below"))
    if not useful_text and not existing_value and len(metadata_lines) <= 1:
        completeness_reasons.append("no_local_target_text")

    completeness = "needs_target_image" if completeness_reasons else "sufficient"
    lines = [
        "TARGET_CONTEXT_KIND: ocr_focus_packet",
        f"FOCUSED_ROLE: {compact_value(target_metadata.get('focused_role')) or 'unknown'}",
        "FOCUS_METADATA:",
    ]
    if metadata_lines:
        lines.extend(metadata_lines)
    else:
        lines.append("- none")
    lines.append("TEXT_IN_OR_OVERLAPPING_FIELD:")
    lines.extend(f"- {text}" for text in sections["inside"]) if sections["inside"] else lines.append("- none")
    lines.append("TEXT_ABOVE_FIELD:")
    lines.extend(f"- {text}" for text in sections["above"]) if sections["above"] else lines.append("- none")
    lines.append("TEXT_LEFT_OF_FIELD:")
    lines.extend(f"- {text}" for text in sections["left"]) if sections["left"] else lines.append("- none")
    lines.append("TEXT_BELOW_FIELD:")
    lines.extend(f"- {text}" for text in sections["below"]) if sections["below"] else lines.append("- none")
    lines.append("OTHER_NEARBY_TEXT:")
    lines.extend(f"- {text}" for text in sections["nearby"]) if sections["nearby"] else lines.append("- none")
    lines.append("LIMITS:")
    if completeness_reasons:
        lines.extend(f"- {reason}" for reason in completeness_reasons)
    else:
        lines.append("- none visible")
    lines.append(f"COMPLETENESS: {completeness}")

    packet_text = "\n".join(lines).strip()
    return {
        "status": "ok" if ocr_payload.get("status") == "ok" else "error",
        "packet_text": packet_text,
        "packet_chars": len(packet_text),
        "completeness": completeness,
        "fallback_reasons": completeness_reasons,
        "build_log": {
            "status": "ok" if ocr_payload.get("status") == "ok" else "error",
            "ocr_ms": ocr_ms,
            "request_build_ms": duration_ms(started_perf),
            "image_size_pixels": {"width": image_width, "height": image_height},
            "focus_rect_local_pixels": focus_rect,
            "focus_debug": focus_debug,
            "ocr_status": ocr_payload.get("status"),
            "ocr_block_count": len(ocr_payload.get("blocks") or []),
            "selected_text": sections,
            "completeness": completeness,
            "fallback_reasons": completeness_reasons,
            "errors": [ocr_payload.get("error")] if ocr_payload.get("error") else [],
        },
    }


def expand_crop_rect(
    focus_rect: dict[str, int],
    *,
    image_width: int,
    image_height: int,
) -> dict[str, int] | None:
    margin_x = max(int(round(focus_rect["width"] * 0.85)), 220)
    margin_y = max(int(round(focus_rect["height"] * 1.35)), 180)
    return clamp_rect(
        x=focus_rect["x"] - margin_x,
        y=focus_rect["y"] - margin_y,
        width=focus_rect["width"] + 2 * margin_x,
        height=focus_rect["height"] + 2 * margin_y,
        image_width=image_width,
        image_height=image_height,
    )


def build_target_crop(
    *,
    target_path: Path,
    target_metadata: dict[str, Any],
    geometry: dict[str, Any] | None,
    out_path: Path,
) -> dict[str, Any]:
    started_perf = time.perf_counter()
    image_width, image_height = image_size_pixels(target_path)
    focus_rect, focus_reasons, focus_debug = focused_rect_local_pixels(
        target_metadata,
        geometry,
        image_width=image_width,
        image_height=image_height,
    )
    ocr_ms = None
    if focus_rect is None:
        ocr_started_perf = time.perf_counter()
        ocr_payload = recognize_text(target_path, uses_language_correction=True)
        ocr_ms = duration_ms(ocr_started_perf)
        if ocr_payload.get("status") == "ok":
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
    if focus_rect is None:
        return {
            "status": "error",
            "crop_path": None,
            "build_log": {
                "status": "error",
                "request_build_ms": duration_ms(started_perf),
                "focus_debug": focus_debug,
                "fallback_reasons": focus_reasons,
                "ocr_ms": ocr_ms,
                "errors": focus_reasons,
            },
            "fallback_reasons": focus_reasons,
        }

    crop_rect = expand_crop_rect(
        focus_rect,
        image_width=image_width,
        image_height=image_height,
    )
    if crop_rect is None:
        return {
            "status": "error",
            "crop_path": None,
            "build_log": {
                "status": "error",
                "request_build_ms": duration_ms(started_perf),
                "focus_debug": focus_debug,
                "fallback_reasons": ["crop_rect_invalid"],
                "errors": ["crop_rect_invalid"],
            },
            "fallback_reasons": ["crop_rect_invalid"],
        }

    result = subprocess.run(
        [
            "/usr/bin/sips",
            "--cropToHeightWidth",
            str(crop_rect["height"]),
            str(crop_rect["width"]),
            "--cropOffset",
            str(crop_rect["y"]),
            str(crop_rect["x"]),
            str(target_path),
            "--out",
            str(out_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    status = "ok" if result.returncode == 0 and out_path.exists() else "error"
    errors = []
    if status != "ok":
        errors.append((result.stderr or result.stdout or "crop_failed").strip())
    return {
        "status": status,
        "crop_path": out_path if status == "ok" else None,
        "build_log": {
            "status": status,
            "request_build_ms": duration_ms(started_perf),
            "image_size_pixels": {"width": image_width, "height": image_height},
            "focus_rect_local_pixels": focus_rect,
            "crop_rect_pixels": crop_rect,
            "focus_debug": focus_debug,
            "ocr_ms": ocr_ms,
            "fallback_reasons": focus_reasons if status != "ok" else [],
            "command": plain_data(result.args),
            "stdout": (result.stdout or "").strip(),
            "stderr": (result.stderr or "").strip(),
            "errors": errors,
        },
        "fallback_reasons": focus_reasons if status != "ok" else [],
    }


def run_target_ocr_variant(
    *,
    client,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    target_packet_text: str,
    target_metadata: dict[str, Any],
    build_log: dict[str, Any],
) -> dict[str, Any]:
    prepare_started_perf = time.perf_counter()
    metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
    instruction_text = (
        "SOURCE_PACKET_TEXT:\n"
        f"{source_packet_text}\n\n"
        "TARGET_CONTEXT_PACKET:\n"
        f"{target_packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n"
    )
    parts = [
        types.Content(
            role="user",
            parts=[types.Part.from_text(text=instruction_text)],
        ),
    ]
    request_build_ms = duration_ms(prepare_started_perf)
    generation = run_stream_request(
        client=client,
        settings=settings,
        prompt_text=prompt_text,
        contents=parts,
        response_mime_type="text/plain",
        request_payload={
            "mode": "target_context_ocr_packet",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(source_packet_text),
            "target_context_packet_chars": len(target_packet_text),
            "target_ocr_block_count": build_log.get("ocr_block_count"),
        },
    )
    generation["run_log"]["timings"]["request_build_ms"] = request_build_ms
    generation["run_log"]["timings"]["request_build_ms"] = round(
        float(build_log.get("request_build_ms") or 0)
        + float(generation["run_log"]["timings"]["request_build_ms"] or 0),
        2,
    )
    generation["run_log"]["timings"]["target_ocr_ms"] = build_log.get("ocr_ms")
    generation["run_log"]["timings"]["target_context_build_ms"] = build_log.get(
        "request_build_ms"
    )
    return generation


def run_target_crop_variant(
    *,
    client,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    target_metadata: dict[str, Any],
    crop_path: Path,
    build_log: dict[str, Any],
) -> dict[str, Any]:
    prepare_started_perf = time.perf_counter()
    crop_request_image = prepare_request_image(crop_path, settings)
    metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
    instruction_text = (
        "SOURCE_PACKET_TEXT:\n"
        f"{source_packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n"
    )
    parts = [
        types.Content(
            role="user",
            parts=[
                types.Part.from_text(text=instruction_text),
                types.Part.from_text(text="TARGET_CROP_IMAGE"),
                types.Part.from_bytes(
                    data=crop_request_image["bytes_data"],
                    mime_type=crop_request_image["mime_type"],
                ),
            ],
        ),
    ]
    request_build_ms = duration_ms(prepare_started_perf)
    generation = run_stream_request(
        client=client,
        settings=settings,
        prompt_text=prompt_text,
        contents=parts,
        response_mime_type="text/plain",
        request_payload={
            "mode": "target_context_crop_image",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(source_packet_text),
            "target_crop_bytes": crop_request_image["request_bytes"],
            "target_crop_original_bytes": crop_request_image["original_bytes"],
            "images": {"target_crop": crop_request_image["log"]},
        },
    )
    generation["run_log"]["timings"]["request_build_ms"] = round(
        float(build_log.get("request_build_ms") or 0) + request_build_ms,
        2,
    )
    generation["run_log"]["timings"]["target_crop_build_ms"] = build_log.get("request_build_ms")
    generation["run_log"]["timings"]["target_crop_prepare_ms"] = crop_request_image["duration_ms"]
    return generation


def summarize_variant(
    results: list[dict[str, Any]],
    variant_key: str,
    reuse_counts: list[int],
) -> dict[str, Any]:
    request_values = [
        item["variants"][variant_key]["request_path_ms"]
        for item in results
        if item["variants"][variant_key]["request_path_ms"] is not None
    ]
    exact_match_count = sum(
        1 for item in results if item["variants"][variant_key]["exact_match_baseline"]
    )
    fallback_count = sum(
        1 for item in results if item["variants"][variant_key].get("fallback_reasons")
    )
    summary = {
        "request_path_ms_avg": round(statistics.mean(request_values), 2)
        if request_values
        else None,
        "exact_match_count": exact_match_count,
        "fallback_count": fallback_count,
        "reuse_estimates": {},
    }
    for reuse in reuse_counts:
        amortized_values: list[float] = []
        deltas: list[float] = []
        for item in results:
            baseline_ms = item["baseline"]["request_path_ms"]
            extract_ms = item["source_packet"]["extract"]["request_path_ms"]
            variant_ms = item["variants"][variant_key]["request_path_ms"]
            if baseline_ms is None or extract_ms is None or variant_ms is None:
                continue
            amortized = round((extract_ms / reuse) + variant_ms, 2)
            amortized_values.append(amortized)
            deltas.append(round(baseline_ms - amortized, 2))
        summary["reuse_estimates"][str(reuse)] = {
            "amortized_request_path_ms_avg": round(statistics.mean(amortized_values), 2)
            if amortized_values
            else None,
            "vs_baseline_delta_ms_avg": round(statistics.mean(deltas), 2)
            if deltas
            else None,
        }
    return summary


def build_summary(results: list[dict[str, Any]], reuse_counts: list[int]) -> dict[str, Any]:
    baseline_values = [
        item["baseline"]["request_path_ms"]
        for item in results
        if item["baseline"]["request_path_ms"] is not None
    ]
    extract_values = [
        item["source_packet"]["extract"]["request_path_ms"]
        for item in results
        if item["source_packet"]["extract"]["request_path_ms"] is not None
    ]
    return {
        "fixture_count": len(results),
        "baseline_request_path_ms_avg": round(statistics.mean(baseline_values), 2)
        if baseline_values
        else None,
        "source_packet_extract_ms_avg": round(statistics.mean(extract_values), 2)
        if extract_values
        else None,
        "variants": {
            "full_target_image": summarize_variant(results, "full_target_image", reuse_counts),
            "target_ocr_packet": summarize_variant(results, "target_ocr_packet", reuse_counts),
            "target_crop_image": summarize_variant(results, "target_crop_image", reuse_counts),
            "target_ocr_or_full_image": summarize_variant(
                results, "target_ocr_or_full_image", reuse_counts
            ),
        },
    }


def write_summary(
    out_dir: Path,
    *,
    config_path: Path,
    source_extract_prompt_path: Path,
    full_image_target_prompt_path: Path,
    target_ocr_prompt_path: Path,
    target_crop_prompt_path: Path,
    results: list[dict[str, Any]],
    summary: dict[str, Any],
    reuse_counts: list[int],
) -> None:
    lines = [
        "# Target Context Benchmark",
        "",
        f"- Generated at: `{now_iso()}`",
        f"- Config: `{os.path.relpath(config_path, ROOT_DIR)}`",
        f"- Source extract prompt: `{os.path.relpath(source_extract_prompt_path, ROOT_DIR)}`",
        f"- Full-image prompt: `{os.path.relpath(full_image_target_prompt_path, ROOT_DIR)}`",
        f"- OCR target prompt: `{os.path.relpath(target_ocr_prompt_path, ROOT_DIR)}`",
        f"- Crop target prompt: `{os.path.relpath(target_crop_prompt_path, ROOT_DIR)}`",
        f"- Fixture count: `{summary['fixture_count']}`",
        f"- Baseline avg request path: `{format_ms(summary['baseline_request_path_ms_avg'])} ms`",
        f"- Source-packet extract avg: `{format_ms(summary['source_packet_extract_ms_avg'])} ms`",
        "",
        "## Variant Summary",
        "",
        "| Variant | Avg target-only req path (ms) | Exact match vs baseline | Fallback count |",
        "| --- | ---: | ---: | ---: |",
    ]
    for variant_key, label in (
        ("full_target_image", "Source packet + full target image"),
        ("target_ocr_packet", "Source packet + target OCR packet"),
        ("target_crop_image", "Source packet + target crop image"),
        ("target_ocr_or_full_image", "Source packet + OCR or full image fallback"),
    ):
        variant_summary = summary["variants"][variant_key]
        lines.append(
            f"| {label} | `{format_ms(variant_summary['request_path_ms_avg'])}` | "
            f"`{variant_summary['exact_match_count']}/{summary['fixture_count']}` | "
            f"`{variant_summary['fallback_count']}` |"
        )

    lines.extend(
        [
            "",
            "## Reuse Estimates",
            "",
            "| Variant | Reuse count | Amortized request path (ms) | Avg delta vs baseline (ms) |",
            "| --- | ---: | ---: | ---: |",
        ]
    )
    for variant_key, label in (
        ("full_target_image", "Full target image"),
        ("target_ocr_packet", "Target OCR packet"),
        ("target_crop_image", "Target crop image"),
        ("target_ocr_or_full_image", "OCR or full image fallback"),
    ):
        for reuse in reuse_counts:
            estimate = summary["variants"][variant_key]["reuse_estimates"][str(reuse)]
            lines.append(
                f"| {label} | `{reuse}` | "
                f"`{format_ms(estimate['amortized_request_path_ms_avg'])}` | "
                f"`{format_ms(estimate['vs_baseline_delta_ms_avg'])}` |"
            )

    lines.extend(
        [
            "",
            "## Per Fixture",
            "",
            "| Fixture | Baseline | Full image | OCR packet | Crop image | OCR or fallback |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for item in results:
        lines.append(
            f"| `{item['fixture_id']}` | "
            f"`{format_ms(item['baseline']['request_path_ms'])}` | "
            f"`{format_ms(item['variants']['full_target_image']['request_path_ms'])}` | "
            f"`{format_ms(item['variants']['target_ocr_packet']['request_path_ms'])}` | "
            f"`{format_ms(item['variants']['target_crop_image']['request_path_ms'])}` | "
            f"`{format_ms(item['variants']['target_ocr_or_full_image']['request_path_ms'])}` |"
        )

    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    load_workspace_env()
    config_path = resolve_from_root(args.config)
    out_dir = resolve_from_root(args.out)
    source_extract_prompt_path = resolve_from_root(args.source_extract_prompt_path)
    full_image_target_prompt_path = resolve_from_root(args.full_image_target_prompt_path)
    target_ocr_prompt_path = resolve_from_root(args.target_ocr_prompt_path)
    target_crop_prompt_path = resolve_from_root(args.target_crop_prompt_path)
    out_dir.mkdir(parents=True, exist_ok=False)
    reuse_counts = [int(item.strip()) for item in args.reuse_counts.split(",") if item.strip()]

    settings = load_settings(config_path)
    if args.max_output_tokens is not None:
        settings["max_output_tokens"] = args.max_output_tokens
    client, runtime = build_client(settings)
    baseline_prompt = BASELINE_PROMPT_PATH.read_text(encoding="utf-8").strip()
    source_extract_prompt = source_extract_prompt_path.read_text(encoding="utf-8").strip()
    full_image_target_prompt = full_image_target_prompt_path.read_text(encoding="utf-8").strip()
    target_ocr_prompt = target_ocr_prompt_path.read_text(encoding="utf-8").strip()
    target_crop_prompt = target_crop_prompt_path.read_text(encoding="utf-8").strip()

    fixture_dirs = [path for path in expand_glob(args.fixtures) if (path / "fixture.json").exists()]
    if args.limit is not None:
        fixture_dirs = fixture_dirs[: args.limit]
    fixtures = [fixture_record(path) for path in fixture_dirs]
    if not fixtures:
        raise ValueError(f"No fixtures found for pattern: {args.fixtures}")

    results: list[dict[str, Any]] = []
    benchmark_manifest = {
        "generated_at": now_iso(),
        "config_path": str(config_path),
        "settings": plain_data(settings),
        "runtime": {
            "provider": runtime["provider"],
            "api_key_env": runtime["api_key_env"],
            "base_url": runtime.get("base_url"),
        },
        "prompts": {
            "baseline_prompt_path": str(BASELINE_PROMPT_PATH),
            "source_extract_prompt_path": str(source_extract_prompt_path),
            "full_image_target_prompt_path": str(full_image_target_prompt_path),
            "target_ocr_prompt_path": str(target_ocr_prompt_path),
            "target_crop_prompt_path": str(target_crop_prompt_path),
        },
        "fixtures": [fixture["fixture_id"] for fixture in fixtures],
        "results": [],
    }

    for fixture in fixtures:
        print(f"[target-context] {fixture['fixture_id']}")
        fixture_out = out_dir / fixture["fixture_id"]
        fixture_out.mkdir(parents=True, exist_ok=True)

        baseline_generation = baseline_generate_completion(
            client,
            settings,
            baseline_prompt,
            fixture["source_path"],
            fixture["target_path"],
            fixture["target_metadata"],
            stream_to_terminal=False,
        )
        baseline_run_log = baseline_generation["run_log"]
        baseline_output = baseline_generation["output_text"]
        baseline_request_path_ms = total_request_path_ms(baseline_run_log)
        save_json_file(fixture_out / "baseline.run.json", baseline_run_log)
        (fixture_out / "baseline.output.txt").write_text(
            baseline_output + ("\n" if baseline_output else ""),
            encoding="utf-8",
        )

        source_packet_result = build_source_packet(
            client,
            settings,
            fixture["source_path"],
            source_extract_prompt,
            "text",
        )
        source_packet_generation = source_packet_result["generation"]
        source_packet_run_log = source_packet_generation["run_log"]
        source_packet_request_path_ms = total_request_path_ms(source_packet_run_log)
        source_packet_text = str(source_packet_result["packet"] or "").strip()
        save_json_file(fixture_out / "source_packet.extract.run.json", source_packet_run_log)
        (fixture_out / "source_packet.extract.output.txt").write_text(
            source_packet_generation["output_text"]
            + ("\n" if source_packet_generation["output_text"] else ""),
            encoding="utf-8",
        )
        (fixture_out / "source_packet.txt").write_text(
            source_packet_text + ("\n" if source_packet_text else ""),
            encoding="utf-8",
        )

        full_image_generation = run_source_packet_target(
            client,
            settings,
            full_image_target_prompt,
            source_packet_text,
            "text",
            fixture["target_path"],
            fixture["target_metadata"],
        )
        full_image_run_log = full_image_generation["run_log"]
        full_image_output = full_image_generation["output_text"]
        save_json_file(fixture_out / "full_target_image.run.json", full_image_run_log)
        (fixture_out / "full_target_image.output.txt").write_text(
            full_image_output + ("\n" if full_image_output else ""),
            encoding="utf-8",
        )

        target_ocr_packet = build_target_ocr_packet(
            target_path=fixture["target_path"],
            target_metadata=fixture["target_metadata"],
            geometry=fixture["geometry"],
        )
        save_json_file(fixture_out / "target_ocr_packet.build.json", target_ocr_packet["build_log"])
        (fixture_out / "target_ocr_packet.txt").write_text(
            target_ocr_packet["packet_text"] + ("\n" if target_ocr_packet["packet_text"] else ""),
            encoding="utf-8",
        )
        target_ocr_generation = run_target_ocr_variant(
            client=client,
            settings=settings,
            prompt_text=target_ocr_prompt,
            source_packet_text=source_packet_text,
            target_packet_text=target_ocr_packet["packet_text"],
            target_metadata=fixture["target_metadata"],
            build_log=target_ocr_packet["build_log"],
        )
        target_ocr_run_log = target_ocr_generation["run_log"]
        target_ocr_output = target_ocr_generation["output_text"]
        save_json_file(fixture_out / "target_ocr_packet.run.json", target_ocr_run_log)
        (fixture_out / "target_ocr_packet.output.txt").write_text(
            target_ocr_output + ("\n" if target_ocr_output else ""),
            encoding="utf-8",
        )

        crop_out_path = fixture_out / "target.focused_crop.png"
        target_crop = build_target_crop(
            target_path=fixture["target_path"],
            target_metadata=fixture["target_metadata"],
            geometry=fixture["geometry"],
            out_path=crop_out_path,
        )
        save_json_file(fixture_out / "target_crop.build.json", target_crop["build_log"])
        if target_crop["crop_path"] is not None:
            target_crop_generation = run_target_crop_variant(
                client=client,
                settings=settings,
                prompt_text=target_crop_prompt,
                source_packet_text=source_packet_text,
                target_metadata=fixture["target_metadata"],
                crop_path=target_crop["crop_path"],
                build_log=target_crop["build_log"],
            )
        else:
            target_crop_generation = {
                "run_log": {
                    "status": "error",
                    "errors": target_crop["build_log"].get("errors") or ["target crop unavailable"],
                    "request": {},
                    "response": {},
                    "timings": {},
                },
                "output_text": "",
            }
        target_crop_run_log = target_crop_generation["run_log"]
        target_crop_output = target_crop_generation["output_text"]
        save_json_file(fixture_out / "target_crop.run.json", target_crop_run_log)
        (fixture_out / "target_crop.output.txt").write_text(
            target_crop_output + ("\n" if target_crop_output else ""),
            encoding="utf-8",
        )

        ocr_or_full_reasons = list(target_ocr_packet["fallback_reasons"])
        if not ocr_or_full_reasons:
            routed_run_log = target_ocr_run_log
            routed_output = target_ocr_output
            routed_request_path_ms = total_request_path_ms(target_ocr_run_log)
            routed_mode = "target_ocr_packet"
        else:
            routed_run_log = full_image_run_log
            routed_output = full_image_output
            routed_request_path_ms = total_request_path_ms(full_image_run_log)
            routed_mode = "full_target_image"

        fixture_result = {
            "fixture_id": fixture["fixture_id"],
            "baseline": {
                "status": baseline_run_log.get("status"),
                "request_path_ms": baseline_request_path_ms,
                "run_log_path": os.path.relpath(fixture_out / "baseline.run.json", out_dir),
                "output_path": os.path.relpath(fixture_out / "baseline.output.txt", out_dir),
                "output_text": baseline_output,
            },
            "source_packet": {
                "extract": {
                    "status": source_packet_run_log.get("status"),
                    "request_path_ms": source_packet_request_path_ms,
                    "run_log_path": os.path.relpath(
                        fixture_out / "source_packet.extract.run.json", out_dir
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "source_packet.extract.output.txt", out_dir
                    ),
                },
                "packet_path": os.path.relpath(fixture_out / "source_packet.txt", out_dir),
                "packet_chars": len(source_packet_text),
            },
            "variants": {
                "full_target_image": {
                    "status": full_image_run_log.get("status"),
                    "request_path_ms": total_request_path_ms(full_image_run_log),
                    "run_log_path": os.path.relpath(
                        fixture_out / "full_target_image.run.json", out_dir
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "full_target_image.output.txt", out_dir
                    ),
                    "output_text": full_image_output,
                    "exact_match_baseline": exact_match(baseline_output, full_image_output),
                    "fallback_reasons": [],
                },
                "target_ocr_packet": {
                    "status": target_ocr_run_log.get("status"),
                    "request_path_ms": total_request_path_ms(target_ocr_run_log),
                    "run_log_path": os.path.relpath(
                        fixture_out / "target_ocr_packet.run.json", out_dir
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "target_ocr_packet.output.txt", out_dir
                    ),
                    "packet_path": os.path.relpath(
                        fixture_out / "target_ocr_packet.txt", out_dir
                    ),
                    "output_text": target_ocr_output,
                    "exact_match_baseline": exact_match(baseline_output, target_ocr_output),
                    "fallback_reasons": target_ocr_packet["fallback_reasons"],
                    "completeness": target_ocr_packet["completeness"],
                },
                "target_crop_image": {
                    "status": target_crop_run_log.get("status"),
                    "request_path_ms": total_request_path_ms(target_crop_run_log),
                    "run_log_path": os.path.relpath(
                        fixture_out / "target_crop.run.json", out_dir
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "target_crop.output.txt", out_dir
                    ),
                    "crop_path": (
                        os.path.relpath(target_crop["crop_path"], out_dir)
                        if target_crop["crop_path"] is not None
                        else None
                    ),
                    "output_text": target_crop_output,
                    "exact_match_baseline": exact_match(baseline_output, target_crop_output),
                    "fallback_reasons": target_crop["fallback_reasons"],
                },
                "target_ocr_or_full_image": {
                    "status": routed_run_log.get("status"),
                    "request_path_ms": routed_request_path_ms,
                    "routed_mode": routed_mode,
                    "output_text": routed_output,
                    "exact_match_baseline": exact_match(baseline_output, routed_output),
                    "fallback_reasons": ocr_or_full_reasons,
                },
            },
        }
        results.append(fixture_result)
        benchmark_manifest["results"].append(fixture_result)

    summary = build_summary(results, reuse_counts)
    benchmark_manifest["summary"] = summary
    save_json_file(out_dir / "benchmark.json", benchmark_manifest)
    write_summary(
        out_dir,
        config_path=config_path,
        source_extract_prompt_path=source_extract_prompt_path,
        full_image_target_prompt_path=full_image_target_prompt_path,
        target_ocr_prompt_path=target_ocr_prompt_path,
        target_crop_prompt_path=target_crop_prompt_path,
        results=results,
        summary=summary,
        reuse_counts=reuse_counts,
    )

    print(f"[target-context] wrote {out_dir}")
    print(
        "[target-context] baseline avg request path:",
        format_ms(summary["baseline_request_path_ms_avg"]),
        "ms",
    )
    for variant_key in (
        "full_target_image",
        "target_ocr_packet",
        "target_crop_image",
        "target_ocr_or_full_image",
    ):
        print(
            f"[target-context] {variant_key} avg request path:",
            format_ms(summary["variants"][variant_key]["request_path_ms_avg"]),
            "ms",
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingCredentialError as exc:
        print(f"[target-context] {exc}", file=sys.stderr)
        raise SystemExit(2)
