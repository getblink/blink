#!/usr/bin/env python3
"""Blink tester-loop per-trial runner.

Invoked by Blink.app (or manually from Terminal) once per copy-paste trial.
Emits a v1 bundle under `<out-dir>/<ts>/` that `./sweep` can replay.

Contract: see docs/ARTIFACT_SCHEMA.md for the bundle layout and field types.

stdout is the generated text (for the Swift caller to insert via clipboard+Cmd+V).
stderr carries progress and error messages. Use `--silent-stderr` to suppress.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from gemini_runner import (
    duration_ms,
    generate_completion,
    now_iso,
    plain_data,
)

SCHEMA_VERSION = 1
BUNDLE_SOURCE = "blink_app"

DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.0,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "thinking_level": "MINIMAL",
    "timeout_seconds": 120,
    "stream_to_terminal": False,
    "copy_to_clipboard": False,
    "preprocess_request_images": True,
    "request_image_format": "jpeg",
    "request_image_max_dimension": 1600,
    "request_image_jpeg_quality": 80,
}

DEFAULT_PROMPT = (
    "You are a precise clipboard assistant.\n\n"
    "Use TARGET_IMAGE as the primary signal for the destination field - its "
    "visible label, placeholder, surrounding text, formatting, and whether "
    "text is already present. TARGET_METADATA_JSON is a supporting hint but "
    "can be unreliable or sparse; treat the image as ground truth when they "
    "disagree.\n\n"
    "Use SOURCE_IMAGE as the truth for content.\n\n"
    "Default: carry the source over as-is, formatted to fit the target field.\n\n"
    "When the target's purpose is clear from the image or metadata, adapt:\n"
    "- Title fields (calendar event, email subject)  -> terse, <=8 words\n"
    "- Messaging apps (iMessage, Slack, Discord)     -> casual, conversational\n"
    "- Structured notes (Notes, Bear, Obsidian)      -> preserve structure, light cleanup\n"
    "- Typed form fields (phone, date, name)         -> match the field's apparent format\n"
    "If unclear, fall back to carry-over.\n\n"
    "Output only the text to be inserted at the caret. If the field is empty,\n"
    "that's the full content. If text is already in the field (visible in\n"
    "TARGET_IMAGE or in `focused_value`), output only the continuation - do\n"
    "not repeat existing text. Whitespace at insertion boundaries is\n"
    "normalized downstream, so don't worry about leading/trailing spaces.\n\n"
    "Examples:\n\n"
    "(1) Carry-over (default)\n"
    'SOURCE: resume showing "John Smith · john@example.com · Software Engineer"\n'
    'TARGET: job application "Full name" text field\n'
    "OUTPUT: John Smith\n\n"
    "(2) Title condensation\n"
    'SOURCE: flight email "United UA1234 SFO -> JFK confirmed Tue Jun 3, 3:45 PM. Confirmation ABC123"\n'
    "TARGET: Google Calendar event-title field\n"
    "OUTPUT: SFO -> JFK · UA1234\n\n"
    "(3) Casual tone shift (same source as #2)\n"
    "TARGET: iMessage compose to a friend\n"
    "OUTPUT: just booked UA1234 to JFK tue 3:45pm - confirmation ABC123\n\n"
    "(4) Format inference\n"
    'SOURCE: contact card "(415) 555-1234"\n'
    'TARGET: CRM phone field with placeholder "415-555-1234"\n'
    "OUTPUT: 415-555-1234\n\n"
    "Rules:\n"
    "- Return plain text only. No explanations.\n"
    "- Empty result -> [[BLANK]].\n"
    "- Uncertain -> [[NEEDS_REVIEW: <=12 word reason]]."
)

STUB_TARGET_METADATA: dict[str, Any] = {
    "status": "not_found",
    "frontmost_app": None,
    "frontmost_window_title": None,
    "frontmost_pid": None,
    "workspace_frontmost_app": None,
    "workspace_frontmost_window_title": None,
    "workspace_frontmost_pid": None,
    "focused_app": None,
    "focused_app_pid": None,
    "focused_app_bundle_id": None,
    "focused_role": None,
    "focused_subrole": None,
    "focused_title": None,
    "focused_description": None,
    "focused_value": None,
    "focused_value_preview": None,
    "focused_label": None,
    "focused_bounds": None,
    "permission": {"accessibility_trusted": False},
    "warnings": ["no_target_metadata_provided"],
    "error": "missing_target_metadata",
    "error_detail": None,
    "_full": {},
}
STUB_CARET: dict[str, Any] = {"status": "not_found"}


def _eprint(message: str, *, silent: bool) -> None:
    if silent:
        return
    print(message, file=sys.stderr, flush=True)


def _bundle_id() -> str:
    now = datetime.now()
    return now.strftime("%Y%m%d-%H%M%S-") + f"{now.microsecond // 1000:03d}"


def _slug_for(bundle_dir: Path) -> str:
    name = bundle_dir.name
    parts = name.split("-", 3)
    return parts[-1] if len(parts) > 3 else name


def _load_json_or_default(path: Path | None, fallback: dict[str, Any]) -> dict[str, Any]:
    if path is None:
        return dict(fallback)
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object, got {type(payload).__name__}")
    return payload


def _load_prompt_or_default(path: Path | None) -> str:
    if path is None:
        return DEFAULT_PROMPT
    return path.read_text(encoding="utf-8").strip()


def _save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def normalize_for_paste(
    model_text: str,
    existing_text: str | None,
    caret_pos: int | None,
) -> str:
    """Fix insertion-boundary artifacts before the pasted text leaves Python."""
    model_text = model_text.strip("\n")
    if not existing_text:
        return model_text
    before_caret = existing_text[:caret_pos] if caret_pos is not None else existing_text
    for k in range(min(len(before_caret), len(model_text)), 0, -1):
        if model_text.startswith(before_caret[-k:]):
            model_text = model_text[k:]
            break
    if before_caret.endswith((" ", "\n", "\t")):
        model_text = model_text.lstrip(" \t")
    elif (
        model_text
        and before_caret
        and before_caret[-1].isalnum()
        and not model_text[0].isspace()
    ):
        model_text = " " + model_text
    return model_text


def _caret_pos_from_capture(caret: dict[str, Any] | None) -> int | None:
    if not isinstance(caret, dict) or caret.get("status") != "ok":
        return None
    rng = caret.get("range")
    if not isinstance(rng, dict):
        return None
    location = rng.get("location")
    try:
        return int(location) if location is not None else None
    except (TypeError, ValueError):
        return None


def _build_genai_client() -> Any:
    """Construct a google-genai client, honoring proxy env vars when set.

    BLINK_PROXY_URL — if present, used as http_options.base_url.
    BLINK_PROXY_TOKEN — if present and BLINK_PROXY_URL is set, attached as
                         `Authorization: Bearer <token>` header.

    The Swift app sets both at invocation time (Phase 5). When neither is set
    we hit the public Gemini endpoint directly using GEMINI_API_KEY.
    """
    from google import genai
    from google.genai import types as genai_types

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise RuntimeError(
            "GEMINI_API_KEY is not set. Swift's PythonRunner must pass it through; "
            "for manual use export it in the shell."
        )

    proxy_url = os.environ.get("BLINK_PROXY_URL")
    proxy_token = os.environ.get("BLINK_PROXY_TOKEN")

    client_kwargs: dict[str, Any] = {"api_key": api_key}
    if proxy_url:
        http_kwargs: dict[str, Any] = {"base_url": proxy_url}
        if proxy_token:
            http_kwargs["headers"] = {"Authorization": f"Bearer {proxy_token}"}
        client_kwargs["http_options"] = genai_types.HttpOptions(**http_kwargs)

    return genai.Client(**client_kwargs)


def _fixture_manifest(
    *,
    bundle_dir: Path,
    settings: dict[str, Any],
    source_path_rel: str,
    target_path_rel: str,
    source_bytes: int,
    target_bytes: int,
    source_captured_at: str | None,
    target_captured_at: str | None,
    target_metadata: dict[str, Any],
    run_request: dict[str, Any] | None,
    has_caret: bool,
) -> dict[str, Any]:
    full = target_metadata.get("_full") if isinstance(target_metadata.get("_full"), dict) else {}
    if not full:
        full = {k: v for k, v in target_metadata.items() if not k.startswith("_")}

    request_images = (run_request or {}).get("images", {})
    source_request_log = (request_images.get("source") or {}) if isinstance(request_images, dict) else {}
    target_request_log = (request_images.get("target") or {}) if isinstance(request_images, dict) else {}

    def _request_rel(log: dict[str, Any]) -> str | None:
        raw = log.get("request_path") if isinstance(log, dict) else None
        if not raw:
            return None
        try:
            rel = os.path.relpath(raw, start=bundle_dir)
        except ValueError:
            return None
        return rel if not rel.startswith("..") else None

    source_request_rel = _request_rel(source_request_log)
    target_request_rel = _request_rel(target_request_log)

    manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "fixture_id": bundle_dir.name,
        "slug": _slug_for(bundle_dir),
        "created_at": now_iso(),
        "bundle_source": BUNDLE_SOURCE,
        "labels": [],
        "tags": [],
        "capture_settings": plain_data(settings),
        "source": {
            "captured_at": source_captured_at,
            "image_path": source_path_rel,
            "request_image_path": source_request_rel,
            "bytes": source_bytes,
            "request_bytes": source_request_log.get("request_bytes"),
        },
        "target": {
            "captured_at": target_captured_at,
            "image_path": target_path_rel,
            "request_image_path": target_request_rel,
            "bytes": target_bytes,
            "request_bytes": target_request_log.get("request_bytes"),
        },
        "app": {
            "frontmost_app": full.get("frontmost_app"),
            "frontmost_window_title": full.get("frontmost_window_title"),
            "frontmost_pid": full.get("frontmost_pid"),
            "workspace_frontmost_app": full.get("workspace_frontmost_app"),
            "workspace_frontmost_window_title": full.get("workspace_frontmost_window_title"),
            "workspace_frontmost_pid": full.get("workspace_frontmost_pid"),
            "focused_app": full.get("focused_app"),
            "focused_app_pid": full.get("focused_app_pid"),
            "focused_app_bundle_id": full.get("focused_app_bundle_id"),
        },
        "warnings": list(target_metadata.get("warnings") or []),
        "target_metadata": plain_data(target_metadata),
    }
    if has_caret:
        manifest["caret"] = {"path": "caret.json"}
    return manifest


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Blink tester-loop per-trial runner")
    parser.add_argument("--source", required=True, type=Path, help="Path to source PNG")
    parser.add_argument("--target", required=True, type=Path, help="Path to target PNG")
    parser.add_argument("--target-meta", type=Path, default=None, help="Path to JSON target metadata")
    parser.add_argument("--caret", type=Path, default=None, help="Path to JSON caret metadata")
    parser.add_argument("--settings", type=Path, default=None, help="Path to JSON settings override")
    parser.add_argument("--prompt", type=Path, default=None, help="Path to prompt text file")
    parser.add_argument("--out-dir", required=True, type=Path, help="Parent dir; bundle lands at <out-dir>/<ts>/")
    parser.add_argument(
        "--skip-gemini",
        action="store_true",
        help="Emit bundle without calling Gemini (useful for bundle-shape verification).",
    )
    parser.add_argument(
        "--silent-stderr",
        action="store_true",
        help="Suppress progress logs on stderr.",
    )
    parser.add_argument(
        "--bundle-id",
        default=None,
        help="Override the generated timestamp directory name.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    source_src = args.source.expanduser().resolve()
    target_src = args.target.expanduser().resolve()
    if not source_src.exists():
        print(f"source not found: {source_src}", file=sys.stderr)
        return 2
    if not target_src.exists():
        print(f"target not found: {target_src}", file=sys.stderr)
        return 2

    settings = dict(DEFAULT_SETTINGS)
    if args.settings is not None:
        settings.update(_load_json_or_default(args.settings.expanduser(), DEFAULT_SETTINGS))
    settings["stream_to_terminal"] = False
    settings["copy_to_clipboard"] = False

    prompt_text = _load_prompt_or_default(args.prompt.expanduser() if args.prompt else None)
    target_metadata = (
        _load_json_or_default(args.target_meta.expanduser(), STUB_TARGET_METADATA)
        if args.target_meta
        else dict(STUB_TARGET_METADATA)
    )
    caret = (
        _load_json_or_default(args.caret.expanduser(), STUB_CARET)
        if args.caret
        else None
    )

    out_root = args.out_dir.expanduser().resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    bundle_id = args.bundle_id or _bundle_id()
    bundle_dir = out_root / bundle_id
    bundle_dir.mkdir(parents=True, exist_ok=False)
    _eprint(f"[blink] bundle={bundle_dir}", silent=args.silent_stderr)

    source_captured_at = datetime.fromtimestamp(source_src.stat().st_mtime).astimezone().isoformat(timespec="milliseconds")
    target_captured_at = datetime.fromtimestamp(target_src.stat().st_mtime).astimezone().isoformat(timespec="milliseconds")

    source_dst = bundle_dir / "source.png"
    target_dst = bundle_dir / "target.png"
    shutil.copy2(source_src, source_dst)
    shutil.copy2(target_src, target_dst)
    _save_json(bundle_dir / "target_metadata.json", target_metadata)
    if caret is not None:
        _save_json(bundle_dir / "caret.json", caret)
    _save_json(bundle_dir / "settings.json", settings)

    run_log: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": bundle_id,
        "status": "skipped" if args.skip_gemini else "started",
        "bundle_source": BUNDLE_SOURCE,
        "prompt_path": str(args.prompt.expanduser().resolve()) if args.prompt else None,
        "settings": plain_data(settings),
        "target_metadata": plain_data(target_metadata),
        "request": {},
        "response": {},
        "timings": {},
        "errors": [],
        "warnings": list(target_metadata.get("warnings") or []),
    }

    output_text = ""
    pasted_text = ""
    trial_start_perf = time.perf_counter()

    if args.skip_gemini:
        _eprint("[blink] --skip-gemini set; writing bundle without calling Gemini", silent=args.silent_stderr)
    else:
        try:
            client = _build_genai_client()
            _eprint("[blink] calling Gemini...", silent=args.silent_stderr)
            generation = generate_completion(
                client,
                settings,
                prompt_text,
                source_dst,
                target_dst,
                target_metadata,
                stream_to_terminal=False,
            )
            inner = generation["run_log"]
            output_text = generation["output_text"]
            run_log["status"] = inner.get("status", "ok")
            run_log["request"] = inner.get("request", {})
            run_log["response"] = inner.get("response", {})
            run_log["timings"] = inner.get("timings", {})
            inner_errors = inner.get("errors") or []
            if inner_errors:
                run_log["errors"] = list(inner_errors)
        except Exception as exc:
            run_log["status"] = "error"
            run_log["errors"].append(str(exc))
            _eprint(f"[blink] gemini error: {exc}", silent=args.silent_stderr)

    existing_text = (
        target_metadata.get("focused_value")
        if isinstance(target_metadata, dict)
        else None
    )
    caret_pos = _caret_pos_from_capture(caret)
    pasted_text = normalize_for_paste(
        output_text,
        existing_text if isinstance(existing_text, str) else None,
        caret_pos,
    )
    run_log["paste"] = {
        "text": pasted_text,
        "model_text": output_text,
        "normalized": pasted_text != output_text,
        "caret_pos": caret_pos,
        "existing_text_length": (
            len(existing_text) if isinstance(existing_text, str) else None
        ),
    }
    run_log.setdefault("timings", {})["end_to_end_ms"] = duration_ms(trial_start_perf)

    fixture_manifest = _fixture_manifest(
        bundle_dir=bundle_dir,
        settings=settings,
        source_path_rel=source_dst.name,
        target_path_rel=target_dst.name,
        source_bytes=source_dst.stat().st_size,
        target_bytes=target_dst.stat().st_size,
        source_captured_at=source_captured_at,
        target_captured_at=target_captured_at,
        target_metadata=target_metadata,
        run_request=run_log.get("request"),
        has_caret=caret is not None,
    )

    _save_json(bundle_dir / "fixture.json", fixture_manifest)
    _save_json(bundle_dir / "run.json", run_log)
    (bundle_dir / "output.txt").write_text(
        output_text + ("\n" if output_text else ""),
        encoding="utf-8",
    )

    _eprint(f"[blink] status={run_log['status']} chars={len(pasted_text)}", silent=args.silent_stderr)
    sys.stdout.write(pasted_text)
    sys.stdout.flush()
    return 0 if run_log["status"] in {"ok", "skipped"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
