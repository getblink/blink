from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from gemini_runner import duration_ms
from model_runner import generate_completion

CARET_CONTEXT_BEFORE_CHARS = 600
CARET_CONTEXT_AFTER_CHARS = 300
ZERO_WIDTH_CHARS = "\u200b\u200c\u200d\ufeff"


def _trimmed_text(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip().strip(ZERO_WIDTH_CHARS).strip()
    return text if text else None


def _remove_zero_width(value: str) -> str:
    return value.translate({ord(char): None for char in ZERO_WIDTH_CHARS})


def _nonempty_list(values: list[str]) -> list[str] | None:
    items = [value for value in values if value]
    return items or None


def _focused_value_from_metadata(target_metadata: dict[str, Any]) -> str | None:
    full = target_metadata.get("_full")
    full_dict = full if isinstance(full, dict) else {}
    focused_value = full_dict.get("focused_value", target_metadata.get("focused_value"))
    return focused_value if isinstance(focused_value, str) else None


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _window_text_before(text: str, limit: int = CARET_CONTEXT_BEFORE_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[-limit:]


def _window_text_after(text: str, limit: int = CARET_CONTEXT_AFTER_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[:limit]


def _line_context(focused_value: str, raw_line_number: Any) -> dict[str, Any] | None:
    line_number = _int_or_none(raw_line_number)
    if line_number is None:
        return None

    lines = focused_value.splitlines(keepends=True)
    if not lines:
        return {
            "kind": "line",
            "line_number": 0,
            "before": "",
            "after": "",
        }

    clamped_line_number = min(max(line_number, 0), len(lines))
    before = "".join(lines[:clamped_line_number])
    after = "".join(lines[clamped_line_number:])
    return {
        "kind": "line",
        "line_number": clamped_line_number,
        "before": _window_text_before(before),
        "after": _window_text_after(after),
    }


def _extract_caret_context(target_metadata: dict[str, Any], caret: dict[str, Any] | None) -> dict[str, Any] | None:
    if not isinstance(target_metadata, dict) or not isinstance(caret, dict):
        return None

    focused_value = _focused_value_from_metadata(target_metadata)
    if focused_value is None:
        return None
    if not _remove_zero_width(focused_value).strip():
        return None

    status = caret.get("status")
    if status == "line_only":
        return _line_context(focused_value, caret.get("line_number"))
    if status != "ok":
        return None

    rng = caret.get("range")
    if not isinstance(rng, dict):
        return None

    raw_offset = _int_or_none(rng.get("location"))
    if raw_offset is None:
        return None
    raw_selection_length = _int_or_none(rng.get("length")) or 0

    offset = min(max(raw_offset, 0), len(focused_value))
    selection_length = max(raw_selection_length, 0)
    selection_end = min(offset + selection_length, len(focused_value))
    before = focused_value[:offset]
    selected = focused_value[offset:selection_end]
    after = focused_value[selection_end:]
    return {
        "kind": "offset",
        "offset": offset,
        "selection_length": selection_length,
        "before": _window_text_before(before),
        "selected": selected,
        "after": _window_text_after(after),
    }


def _render_focused_field_with_caret(
    focused_field: dict[str, Any],
    context: dict[str, Any],
    *,
    fmt: str,
) -> dict[str, Any]:
    if fmt != "split":
        raise ValueError(f"Unsupported caret metadata format: {fmt}")

    if context.get("kind") == "line":
        focused_field["caret"] = {"line_number": context["line_number"]}
        focused_field["text_before_caret_line"] = context["before"]
        focused_field["text_after_caret_line"] = context["after"]
        return focused_field

    focused_field["caret"] = {
        "offset": context["offset"],
        "selection_length": context["selection_length"],
    }
    focused_field["text_before_caret"] = context["before"]
    if context["selection_length"] > 0:
        focused_field["text_selected"] = context["selected"]
    focused_field["text_after_caret"] = context["after"]
    return focused_field


def compact_target_metadata(
    target_metadata: dict[str, Any],
    caret: dict[str, Any] | None = None,
    caret_format: str = "split",
) -> dict[str, Any]:
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
        caret_context = _extract_caret_context(target_metadata, caret)
        if caret_context is not None:
            _render_focused_field_with_caret(
                focused_field,
                caret_context,
                fmt=caret_format,
            )
        else:
            focused_field["existing_text"] = _remove_zero_width(focused_value)
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


def compact_target_metadata_json(
    target_metadata: dict[str, Any],
    caret: dict[str, Any] | None = None,
    caret_format: str = "split",
) -> str:
    return json.dumps(
        compact_target_metadata(
            target_metadata,
            caret=caret,
            caret_format=caret_format,
        ),
        indent=2,
        ensure_ascii=True,
    )


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
    source_packet_kind: str | None = None,
    target_path: Path,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
    caret: dict[str, Any] | None = None,
) -> dict[str, Any]:
    metadata_json = compact_target_metadata_json(target_metadata, caret=caret)
    kind_text = _trimmed_text(source_packet_kind) or "unknown"
    instruction_text = (
        "SOURCE_PACKET_KIND:\n"
        f"{kind_text}\n\n"
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
            "source_packet_kind": kind_text,
        },
        stream_to_terminal=False,
    )


def run_source_packet_target_ocr_packet(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    source_packet_text: str,
    source_packet_kind: str | None = None,
    target_packet_text: str,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
    caret: dict[str, Any] | None = None,
) -> dict[str, Any]:
    metadata_json = compact_target_metadata_json(target_metadata, caret=caret)
    kind_text = _trimmed_text(source_packet_kind) or "unknown"
    instruction_text = (
        "SOURCE_PACKET_KIND:\n"
        f"{kind_text}\n\n"
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
            "source_packet_kind": kind_text,
            "target_context_packet_chars": len(target_packet_text),
        },
        stream_to_terminal=False,
    )
