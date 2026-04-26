from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from gemini_runner import duration_ms
from model_runner import generate_completion


def _trimmed_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def _nonempty_list(values: list[str]) -> list[str] | None:
    items = [value for value in values if value]
    return items or None


def compact_target_metadata(target_metadata: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(target_metadata, dict):
        return {}
    full = target_metadata.get("_full")
    full_dict = full if isinstance(full, dict) else {}
    status = _trimmed_text(target_metadata.get("status")) or "unknown"
    compact: dict[str, Any] = {"status": status}

    app_name = (
        _trimmed_text(target_metadata.get("focused_app"))
        or _trimmed_text(target_metadata.get("frontmost_app"))
        or _trimmed_text(target_metadata.get("workspace_frontmost_app"))
    )
    if app_name:
        compact["app"] = app_name

    focused_field: dict[str, Any] = {}
    for source_key, output_key in (
        ("focused_role", "role"),
        ("focused_subrole", "subrole"),
        ("focused_title", "title"),
        ("focused_label", "label"),
        ("focused_description", "description"),
    ):
        value = _trimmed_text(target_metadata.get(source_key))
        if value is not None:
            focused_field[output_key] = value

    focused_value = full_dict.get("focused_value", target_metadata.get("focused_value"))
    if isinstance(focused_value, str):
        focused_field["existing_text"] = focused_value
    else:
        preview = target_metadata.get("focused_value_preview")
        if isinstance(preview, str):
            focused_field["existing_text"] = preview

    if focused_field:
        compact["focused_field"] = focused_field

    notes = _nonempty_list(
        [
            "focused owner differs from workspace frontmost"
            if target_metadata.get("focused_app") != target_metadata.get("workspace_frontmost_app")
            and _trimmed_text(target_metadata.get("focused_app"))
            and _trimmed_text(target_metadata.get("workspace_frontmost_app"))
            else "",
            "frontmost app fell back to workspace frontmost"
            if "fell_back_to_workspace_frontmost" in (target_metadata.get("warnings") or [])
            else "",
        ]
    )
    if notes:
        compact["notes"] = notes

    if status != "ok":
        permission = target_metadata.get("permission")
        if permission is not None:
            compact["permission"] = permission
        warnings = target_metadata.get("warnings")
        if warnings:
            compact["warnings"] = warnings
        for key in ("error", "error_detail"):
            value = target_metadata.get(key)
            if value is not None:
                compact[key] = value
    return compact


def compact_target_metadata_json(target_metadata: dict[str, Any]) -> str:
    return json.dumps(compact_target_metadata(target_metadata), indent=2, ensure_ascii=True)


def build_source_packet(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    source_path: Path,
    runtime: dict[str, Any],
) -> dict[str, Any]:
    started = time.perf_counter()
    generation = generate_completion(
        settings=settings,
        prompt_text=prompt_text,
        content_items=[
            {
                "type": "image",
                "key": "source",
                "label": "SOURCE_IMAGE",
                "path": source_path,
            }
        ],
        runtime=runtime,
        request_context={
            "mode": "source_packet_extract",
            "source_packet_format": "text",
        },
        stream_to_terminal=False,
    )
    return {
        "generation": generation,
        "packet_text": generation["output_text"].strip(),
        "build_ms": duration_ms(started),
    }


def run_source_packet_target_full_image(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    target_path: Path,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
) -> dict[str, Any]:
    metadata_json = compact_target_metadata_json(target_metadata)
    instruction_text = (
        "SOURCE_PACKET_TEXT:\n"
        f"{source_packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n"
    )
    return generate_completion(
        settings=settings,
        prompt_text=prompt_text,
        content_items=[
            {"type": "text", "text": instruction_text},
            {
                "type": "image",
                "key": "target",
                "label": "TARGET_IMAGE",
                "path": target_path,
            },
        ],
        runtime=runtime,
        request_context={
            "mode": "source_packet_target_full_image",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(source_packet_text),
        },
        stream_to_terminal=False,
    )


def run_source_packet_target_ocr_packet(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    target_packet_text: str,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
) -> dict[str, Any]:
    metadata_json = compact_target_metadata_json(target_metadata)
    instruction_text = (
        "SOURCE_PACKET_TEXT:\n"
        f"{source_packet_text}\n\n"
        "TARGET_CONTEXT_PACKET:\n"
        f"{target_packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n"
    )
    return generate_completion(
        settings=settings,
        prompt_text=prompt_text,
        content_items=[{"type": "text", "text": instruction_text}],
        runtime=runtime,
        request_context={
            "mode": "source_packet_target_ocr_packet",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(source_packet_text),
            "target_context_packet_chars": len(target_packet_text),
        },
        stream_to_terminal=False,
    )


def run_source_packet_target_text_only(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    target_ocr_text: str,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
    focused_label_hint: str | None = None,
) -> dict[str, Any]:
    metadata_json = compact_target_metadata_json(target_metadata)
    hint_text = _trimmed_text(focused_label_hint)
    hint_section = (
        "TARGET_FIELD_HINT (the question this field belongs to, best deterministic OCR guess):\n"
        f"{hint_text}\n\n"
        if hint_text
        else ""
    )
    instruction_text = (
        "SOURCE_PACKET_TEXT:\n"
        f"{source_packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n\n"
        f"{hint_section}"
        "TARGET_OCR_TEXT:\n"
        f"{target_ocr_text}\n"
    )
    return generate_completion(
        settings=settings,
        prompt_text=prompt_text,
        content_items=[{"type": "text", "text": instruction_text}],
        runtime=runtime,
        request_context={
            "mode": "source_packet_target_text_only",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(source_packet_text),
            "target_ocr_chars": len(target_ocr_text),
            "focused_label_hint_chars": len(hint_text or ""),
        },
        stream_to_terminal=False,
    )
