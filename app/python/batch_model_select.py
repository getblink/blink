#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


APP_PYTHON = Path(__file__).resolve().parent
if str(APP_PYTHON) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON))

from env_loader import load_runtime_env  # noqa: E402
from model_runner import generate_completion  # noqa: E402
from providers import resolve_runtime_settings  # noqa: E402
from target_context import build_target_ocr_packet  # noqa: E402


DEFAULT_SETTINGS: dict[str, Any] = {
    "provider": "gemini",
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.0,
    "max_output_tokens": 256,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "thinking_level": "MINIMAL",
    "timeout_seconds": 120,
    "stream_to_terminal": False,
    "copy_to_clipboard": False,
    "preprocess_request_images": True,
    "request_image_format": "jpeg",
    "request_image_max_dimension": 1600,
    "request_image_jpeg_quality": 80,
    "provider_options": {
        "api_key_env": "GEMINI_API_KEY",
        "api_style": "gemini",
    },
}


PROMPT = """You choose which clipboard history items are useful for the typed goal.

Return only JSON in this exact shape:
{"selected_handles":["item_2"]}

Rules:
- Use only handles from allowed_handles.
- Preserve the order that should be used by the runtime.
- If target_context or target_metadata contains a focused field label, use it to choose the item or items that fit the destination field.
- If the goal is "paste all" but a target field is known, treat that as "paste the matching clipboard item(s) into this field".
- If the goal is "paste all" and no target field is known, select every useful non-concealed handle in order.
- For Google Slides or a rich document canvas, prefer the full original rich HTML handle when the user is pasting a whole slide/layout selection.
- For an isolated image inside a rich document canvas, prefer a google_slides_image_object_fragment handle when available, otherwise a rich image-fragment handle; use the raw image handle for non-rich image-only destinations.
- Do not invent handles, glue text, explanations, markdown, or comments.
- Select zero items if none are relevant.
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Select clipboard-history handles for Blink batch paste.")
    parser.add_argument("--request", required=True, type=Path, help="batch-request.model.json")
    parser.add_argument("--settings", type=Path, help="Optional JSON settings override.")
    parser.add_argument("--model", help="Override model name.")
    parser.add_argument("--target", type=Path, help="Target screenshot used for target OCR context.")
    parser.add_argument("--model-target", type=Path, help="Optional target screenshot sent to the selector model when target pixels are needed.")
    parser.add_argument("--target-meta", type=Path, help="Target metadata JSON.")
    parser.add_argument("--geometry", type=Path, help="Target geometry JSON.")
    parser.add_argument("--target-packet-out", type=Path, help="Where to write target_ocr_packet.txt.")
    parser.add_argument("--target-build-out", type=Path, help="Where to write target_ocr_packet.build.json.")
    parser.add_argument("--request-out", type=Path, help="Where to write the final model request JSON.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def compact_target_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "status",
        "frontmost_app",
        "frontmost_window_title",
        "focused_app",
        "focused_app_bundle_id",
        "focused_role",
        "focused_subrole",
        "focused_title",
        "focused_description",
        "focused_value_preview",
        "focused_label",
        "warnings",
        "error",
    ]
    return {key: metadata.get(key) for key in keys if metadata.get(key) not in (None, "", [])}


def attach_target_context(request_payload: dict[str, Any], args: argparse.Namespace) -> dict[str, Any] | None:
    if args.target is None:
        return None
    if args.target_meta is None or args.geometry is None:
        raise ValueError("--target requires --target-meta and --geometry")

    target_metadata = load_json(args.target_meta)
    geometry = load_json(args.geometry)
    target_packet = build_target_ocr_packet(
        target_path=args.target,
        target_metadata=target_metadata,
        geometry=geometry,
    )

    if args.target_packet_out:
        args.target_packet_out.write_text(
            str(target_packet.get("packet_text") or "") + "\n",
            encoding="utf-8",
        )
    if args.target_build_out:
        args.target_build_out.write_text(
            json.dumps(target_packet.get("build_log") or {}, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    request_payload["target_context"] = {
        "mode": target_packet.get("target_mode") or "target_ocr_packet",
        "packet_text": target_packet.get("packet_text") or "",
        "completeness": target_packet.get("completeness"),
        "fallback_reasons": target_packet.get("fallback_reasons") or [],
        "focused_label_hint": target_packet.get("focused_label_hint"),
        "packet_chars": target_packet.get("packet_chars"),
        "target_copy_probe": (target_packet.get("build_log") or {}).get("target_copy_probe") or {},
        "annotation_metadata": (target_packet.get("build_log") or {}).get("annotation_metadata") or {},
    }
    request_payload["target_metadata"] = compact_target_metadata(target_metadata)
    return target_packet


def target_image_content_item(
    request_payload: dict[str, Any],
    target_packet: dict[str, Any] | None,
    args: argparse.Namespace,
) -> dict[str, Any] | None:
    if not target_packet or target_packet.get("completeness") != "needs_target_image":
        return None
    image_path = args.model_target or args.target
    if image_path is None:
        return None
    request_payload.setdefault("target_context", {})["model_target_image"] = {
        "artifact": image_path.name,
        "source": "annotated" if args.model_target else "raw_target",
    }
    return {
        "type": "image",
        "key": "target",
        "label": "TARGET_IMAGE",
        "path": image_path,
    }


def main() -> int:
    args = parse_args()
    load_runtime_env()
    request_payload = load_json(args.request)
    target_packet = attach_target_context(request_payload, args)
    content_items = [{"type": "text", "label": "BATCH_REQUEST", "text": ""}]
    target_image_item = target_image_content_item(request_payload, target_packet, args)
    if args.request_out:
        args.request_out.write_text(
            json.dumps(request_payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    settings = dict(DEFAULT_SETTINGS)
    if args.settings:
        settings.update(load_json(args.settings))
    if args.model:
        settings["model"] = args.model

    settings["copy_to_clipboard"] = False
    settings["stream_to_terminal"] = False

    runtime = resolve_runtime_settings(settings)
    content = json.dumps(request_payload, indent=2, sort_keys=True, ensure_ascii=False)
    content_items[0]["text"] = content
    if target_image_item:
        content_items.append(target_image_item)
    result = generate_completion(
        settings=settings,
        prompt_text=PROMPT,
        content_items=content_items,
        runtime=runtime,
        response_mime_type="application/json",
        request_context={
            "harness": "batch_clipboard_history",
            "allowed_handle_count": len(request_payload.get("allowed_handles") or []),
            "target_image_attached": target_image_item is not None,
            "target_mode": (request_payload.get("target_context") or {}).get("mode"),
        },
        stream_to_terminal=False,
    )
    output = str(result.get("output_text") or "").strip()
    if not output:
        raise RuntimeError("Model returned empty output.")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
