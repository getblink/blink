#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import select
import sys
import time
from pathlib import Path
from typing import Any


APP_PYTHON = Path(__file__).resolve().parent
if str(APP_PYTHON) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON))

from env_loader import load_runtime_env  # noqa: E402
from gemini_runner import guess_mime_type, plain_data  # noqa: E402
from model_runner import generate_completion  # noqa: E402
from providers import resolve_runtime_settings  # noqa: E402
from target_context import build_target_ocr_packet  # noqa: E402


_WARM_WORKER_TIMEOUT_S = 30.0


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
{"paste_items":[{"type":"handle","handle":"item_2"}]}

Legacy outputs that use {"selected_handles":[...]} are still accepted for compatibility.

Selection format:
- Return an ordered list in paste_items.
- Each action is one object with type "handle" or "text".
- Handle action shape: {"type":"handle","handle":"item_1"}
- Text action shape: {"type":"text","text":"Generated text to paste"} (plain text only)

Rules:
- Prefer source_groups first, then variants within each selected group. "source_groups" describe root and derived options:
  - root_rich_parent handles preserve layout/structure; they are preferred for whole-object operations.
  - derived_* variants are specialized children and may drop context.
- Use only handles from allowed_handles.
- Preserve the order that should be used by the runtime.
- If target_context or target_metadata contains a focused field label, use it to choose the item or items that fit the destination field.
- If target_context includes TARGET_IMAGE lines, inspect the attached target screenshot for visible target text, selected objects, and layout.
- If TARGET_IMAGE_ANNOTATION lines mention colored rectangles, treat the red rectangle as the focused caret/selection line and the blue rectangle as the nearby document/canvas region. These markings are target context only, not clipboard content.
- If the goal is "paste all" but a target field is known, treat that as "paste the matching clipboard item(s) into this field".
- If the goal is "paste all" and no target field is known, select every useful non-concealed handle in order.
- For Google Slides or a rich document canvas, prefer the full original rich HTML handle when the user is pasting a whole slide/layout selection.
- For an isolated image inside a rich document canvas, prefer a google_slides_image_object_fragment handle when available, otherwise a rich image-fragment handle; use the raw image handle for non-rich image-only destinations.
- visual_tags are local Vision classifications attached to image-capable items. Use them as broad visual hints when target text asks for a picture, face, portrait, screenshot, object, or similar visual content; do not treat them as perfect captions.
- Do not invent handles or handle names.
- Do not return prose or markdown wrappers.
- Do not generate text for copy-through paste unless the goal clearly requires transformation (synthesis, paraphrase, cleanup, or glue text).
- For target copy-probe text, treat it as destination context only; do not mirror it in output.
- Select zero items if none are relevant.
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Select clipboard-history handles for Blink batch paste.")
    parser.add_argument("--request", type=Path, help="batch-request.model.json")
    parser.add_argument("--settings", type=Path, help="Optional JSON settings override.")
    parser.add_argument("--model", help="Override model name.")
    parser.add_argument("--target", type=Path, help="Target screenshot used for target OCR context.")
    parser.add_argument("--model-target", type=Path, help="Optional target screenshot sent to the selector model when target pixels are needed.")
    parser.add_argument("--target-meta", type=Path, help="Target metadata JSON.")
    parser.add_argument("--geometry", type=Path, help="Target geometry JSON.")
    parser.add_argument("--target-packet-out", type=Path, help="Where to write target_ocr_packet.txt.")
    parser.add_argument("--target-build-out", type=Path, help="Where to write target_ocr_packet.build.json.")
    parser.add_argument("--request-out", type=Path, help="Where to write the final model request JSON.")
    parser.add_argument("--run-log-out", type=Path, help="Where to write selector-run-log.json.")
    parser.add_argument(
        "--wait-on-stdin",
        action="store_true",
        help="Warm imports, print READY <pid>, then read one JSON request from stdin.",
    )
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


def _compact_probe_preview(target_metadata: dict[str, Any]) -> dict[str, Any]:
    probe = target_metadata.get("target_copy_probe")
    if not isinstance(probe, dict):
        return {}
    preview = probe.get("string_preview")
    if not isinstance(preview, str) or not preview.strip():
        return {}
    return {
        "status": probe.get("status"),
        "plain_text_bytes": probe.get("plain_text_bytes"),
        "string_preview": preview[:240],
    }


def _document_canvas_image_context_lines(annotation_metadata: dict[str, Any]) -> list[str]:
    status = str(annotation_metadata.get("status") or "")
    source = str(annotation_metadata.get("source") or "")
    annotated_target = annotation_metadata.get("annotated_target")
    if source == "swift_focus_line_canvas_region" or annotated_target:
        return [
            "TARGET_IMAGE: attached screenshot of the target window with visual annotations",
            "TARGET_IMAGE_ANNOTATION: red rectangle marks the focused caret/selection line",
            "TARGET_IMAGE_ANNOTATION: blue rectangle marks the nearby document/canvas region for coarse insertion context",
        ]
    if status == "degenerate_document_canvas_anchor":
        return [
            "TARGET_IMAGE: attached raw screenshot of the target window; no red/blue annotation was drawn because the focused bounds are degenerate",
        ]
    return [
        "TARGET_IMAGE: attached screenshot of the target window",
    ]


def build_document_canvas_fast_packet(
    *,
    target_path: Path,
    target_metadata: dict[str, Any],
    geometry: dict[str, Any] | None,
    model_target: Path,
) -> dict[str, Any]:
    started_perf = time.perf_counter()
    annotation_metadata = {}
    if isinstance(geometry, dict) and isinstance(geometry.get("annotation_metadata"), dict):
        annotation_metadata = geometry.get("annotation_metadata") or {}
    elif isinstance(target_metadata.get("annotation_metadata"), dict):
        annotation_metadata = target_metadata.get("annotation_metadata") or {}

    target_copy_probe = target_metadata.get("target_copy_probe")
    if not isinstance(target_copy_probe, dict):
        target_copy_probe = {}
    probe_preview = _compact_probe_preview(target_metadata)

    lines = ["TARGET_CONTEXT_KIND: document_canvas"]
    lines.extend(_document_canvas_image_context_lines(annotation_metadata))
    if probe_preview:
        lines.append(f"TARGET_COPY_PROBE_TEXT_PREVIEW: {probe_preview['string_preview']}")
    packet_text = "\n".join(lines).strip()
    return {
        "status": "ok",
        "packet_text": packet_text,
        "packet_chars": len(packet_text),
        "completeness": "needs_target_image",
        "fallback_reasons": [],
        "target_mode": "document_canvas",
        "build_log": {
            "status": "ok",
            "target_mode": "document_canvas",
            "ocr_ms": 0.0,
            "request_build_ms": round((time.perf_counter() - started_perf) * 1000, 2),
            "target_path": str(target_path),
            "model_target_path": str(model_target),
            "ocr_status": "skipped_document_canvas_fast_path",
            "ocr_block_count": 0,
            "completeness": "needs_target_image",
            "fallback_reasons": [],
            "target_copy_probe": target_copy_probe,
            "target_copy_probe_preview": probe_preview,
            "annotation_metadata": annotation_metadata,
            "errors": [],
        },
        "focused_label_hint": None,
    }


def attach_target_context(request_payload: dict[str, Any], args: argparse.Namespace) -> dict[str, Any] | None:
    if args.target is None:
        return None
    if args.target_meta is None or args.geometry is None:
        raise ValueError("--target requires --target-meta and --geometry")

    target_metadata = load_json(args.target_meta)
    geometry = load_json(args.geometry)
    if target_metadata.get("target_mode") == "document_canvas":
        target_packet = build_document_canvas_fast_packet(
            target_path=args.target,
            target_metadata=target_metadata,
            geometry=geometry,
            model_target=args.model_target or args.target,
        )
    else:
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
    preprocessed = is_preprocessed_model_target(image_path, args)
    return {
        "type": "image",
        "key": "target",
        "label": "TARGET_IMAGE",
        "path": image_path,
        "preprocessed": preprocessed,
        "mime_type": guess_mime_type(image_path) if preprocessed else None,
    }


def is_preprocessed_model_target(image_path: Path, args: argparse.Namespace) -> bool:
    if args.model_target is None:
        return False
    suffix = image_path.suffix.lower()
    return image_path.stem.endswith(".request") and suffix in {".jpg", ".jpeg"}


def _warm_caches() -> None:
    """Force-load provider SDKs before the worker advertises READY."""
    try:
        import google.genai  # noqa: F401
    except Exception:  # noqa: BLE001
        pass
    try:
        import openai  # noqa: F401
    except Exception:  # noqa: BLE001
        pass


def args_from_worker_request(payload: dict[str, Any]) -> argparse.Namespace:
    if not isinstance(payload, dict):
        raise ValueError("worker request must be a JSON object")
    if not payload.get("request"):
        raise ValueError("worker request missing required 'request' path")
    return argparse.Namespace(
        request=Path(str(payload["request"])),
        settings=Path(str(payload["settings"])) if payload.get("settings") else None,
        model=payload.get("model"),
        target=Path(str(payload["target"])) if payload.get("target") else None,
        model_target=Path(str(payload["model_target"])) if payload.get("model_target") else None,
        target_meta=Path(str(payload["target_meta"])) if payload.get("target_meta") else None,
        geometry=Path(str(payload["geometry"])) if payload.get("geometry") else None,
        target_packet_out=Path(str(payload["target_packet_out"])) if payload.get("target_packet_out") else None,
        target_build_out=Path(str(payload["target_build_out"])) if payload.get("target_build_out") else None,
        request_out=Path(str(payload["request_out"])) if payload.get("request_out") else None,
        run_log_out=Path(str(payload["run_log_out"])) if payload.get("run_log_out") else None,
        wait_on_stdin=False,
    )


def run_selector(args: argparse.Namespace) -> int:
    if args.request is None:
        raise ValueError("--request is required")
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
    if args.run_log_out:
        args.run_log_out.write_text(
            json.dumps(plain_data(result.get("run_log") or {}), indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    output = str(result.get("output_text") or "").strip()
    if not output:
        raise RuntimeError("Model returned empty output.")
    print(output)
    return 0


def _stdin_ready(timeout_seconds: float) -> bool:
    try:
        ready, _, _ = select.select([sys.stdin], [], [], timeout_seconds)
    except (AttributeError, OSError, ValueError):
        # Unit tests often use io.StringIO, which does not expose a real fd.
        return True
    return bool(ready)


def _run_warm_worker_loop() -> int:
    load_runtime_env()
    _warm_caches()
    print(f"READY {os.getpid()}", flush=True)
    if not _stdin_ready(_WARM_WORKER_TIMEOUT_S):
        return 0
    line = sys.stdin.readline()
    if not line:
        return 0
    try:
        worker_args = args_from_worker_request(json.loads(line))
    except json.JSONDecodeError as exc:
        print(f"[blink] batch selector worker: invalid JSON request: {exc}", file=sys.stderr)
        return 2
    except ValueError as exc:
        print(f"[blink] batch selector worker: {exc}", file=sys.stderr)
        return 2
    return run_selector(worker_args)


def main() -> int:
    args = parse_args()
    if args.wait_on_stdin:
        return _run_warm_worker_loop()
    return run_selector(args)


if __name__ == "__main__":
    raise SystemExit(main())
