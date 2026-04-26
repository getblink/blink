#!/usr/bin/env python3
"""Blink tester-loop per-trial runner.

Invoked by Blink.app (or manually from Terminal) once per copy-paste trial.
Emits a v1 bundle under `<out-dir>/<ts>/` that `./sweep` can replay.

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
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

from env_loader import load_runtime_env
from gemini_runner import duration_ms, now_iso, plain_data
from model_runner import generate_completion
from providers import MissingCredentialError, resolve_runtime_settings
from source_packet import (
    build_source_packet,
    compact_target_metadata,
    compact_target_metadata_json,
    run_source_packet_target_full_image,
    run_source_packet_target_ocr_packet,
    run_source_packet_target_text_only,
)
from source_ocr import (
    LOCAL_SOURCE_TEXT_PACKET_KIND,
    NATIVE_SOURCE_OCR_REQUEST_MODE,
    NATIVE_SOURCE_PACKET_KIND,
    SOURCE_OCR_PARAMETERS,
    SOURCE_TEXT_PARAMETERS,
    build_local_source_text_packet,
    build_source_packet_with_fallback,
)
from target_context import (
    build_target_ocr_packet,
    build_target_ocr_text,
    choose_text_only_target_path,
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
    "Use SOURCE_IMAGE as the truth for content and surface form. Preserve the "
    "source wording, capitalization, punctuation, and line breaks by default. "
    "Do not clean up, rewrite, or 'fix' the source unless the target clearly "
    "requires a format transformation.\n\n"
    "Default: carry the source over as-is, formatted to fit the target field.\n\n"
    "When the target's purpose is clear from the image or metadata, adapt:\n"
    "- Title fields (calendar event, email subject)  -> terse, <=8 words\n"
    "- Messaging apps (iMessage, Slack, Discord)     -> casual, conversational\n"
    "- Structured notes (Notes, Bear, Obsidian)      -> preserve structure, light cleanup\n"
    "- Typed form fields (phone, date, name)         -> match the field's apparent format\n"
    "If unclear, fall back to carry-over.\n\n"
    "Output only the text to be inserted at the caret. If the field is empty,\n"
    "that's the full content. If text is already in the field (visible in\n"
    "TARGET_IMAGE or in TARGET_METADATA_JSON), output only the continuation - do\n"
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
STUB_GEOMETRY: dict[str, Any] = {"status": "not_found"}


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


def _load_runtime_selection(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
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


def _save_text(path: Path, text: str) -> None:
    path.write_text(text + ("\n" if text else ""), encoding="utf-8")


def normalize_for_paste(
    model_text: str,
    existing_text: str | None,
    caret_pos: int | None,
) -> str:
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


RUNTIME_ROLE_EXTRACTOR = "extractor"
RUNTIME_ROLE_PASTE = "paste"


def _runtime_role_section(
    runtime_selection: dict[str, Any],
    role: str,
) -> dict[str, Any]:
    """Return the {model, provider_preset} dict for ``role`` from a runtime selection.

    Falls back to the legacy top-level ``model``/``provider_preset`` when the
    selection does not declare ``version >= 2`` (i.e. v1 fixtures captured
    before the extractor/paste split). Returns an empty dict when neither
    shape is present.
    """
    if not runtime_selection:
        return {}
    version = runtime_selection.get("version")
    if isinstance(version, int) and version >= 2:
        section = runtime_selection.get(role)
        return section if isinstance(section, dict) else {}
    # Legacy v1: same model + preset for both roles.
    legacy_preset = runtime_selection.get("provider_preset")
    legacy_model = runtime_selection.get("model")
    if isinstance(legacy_preset, dict) and isinstance(legacy_model, str):
        return {"provider_preset": legacy_preset, "model": legacy_model}
    return {}


def _resolve_runtime_section(
    base_settings: dict[str, Any],
    runtime_selection: dict[str, Any],
    role: str,
) -> dict[str, Any]:
    """Return a settings dict resolved for ``role`` (extractor or paste)."""
    settings = dict(base_settings)
    section = _runtime_role_section(runtime_selection, role)
    if not section:
        return settings
    preset = section.get("provider_preset")
    if not isinstance(preset, dict):
        raise ValueError(
            f"runtime_selection.{role}.provider_preset must be present"
        )
    preset_id = preset.get("id")
    if not isinstance(preset_id, str) or not preset_id.strip():
        raise ValueError(
            f"runtime_selection.{role}.provider_preset.id must be a non-empty string"
        )
    model = section.get("model")
    if not isinstance(model, str) or not model.strip():
        raise ValueError(
            f"runtime_selection.{role}.model must be a non-empty string"
        )

    settings["model"] = model.strip()
    settings["provider"] = str(preset.get("provider") or "gemini")
    provider_options = {
        "api_key_env": str(preset.get("api_key_env") or ""),
        "api_style": str(preset.get("api_style") or "chat_completions"),
        "base_url": preset.get("base_url"),
        "url_substitutions": list(preset.get("url_substitutions") or []),
        "default_headers": dict(preset.get("default_headers") or {}),
        "extra_headers": dict(preset.get("extra_headers") or {}),
    }
    if preset.get("extra_body") is not None:
        provider_options["extra_body"] = preset.get("extra_body")
    settings["provider_options"] = provider_options
    return settings


def _resolve_settings(
    base_settings: dict[str, Any],
    runtime_selection: dict[str, Any],
) -> dict[str, Any]:
    """Backward-compatible single-role resolver — uses the extractor section."""
    return _resolve_runtime_section(base_settings, runtime_selection, RUNTIME_ROLE_EXTRACTOR)


def _runtime_mode(runtime_selection: dict[str, Any]) -> str:
    return str(runtime_selection.get("request_mode") or "baseline_full_images")


def _runtime_prompt_path(runtime_selection: dict[str, Any], key: str) -> Path | None:
    paths = runtime_selection.get("paths")
    if not isinstance(paths, dict):
        return None
    raw = paths.get(key)
    if not isinstance(raw, str) or not raw.strip():
        return None
    return Path(raw)


def _role_summary(
    role_settings: dict[str, Any],
    runtime_selection: dict[str, Any],
    role: str,
) -> dict[str, Any]:
    provider_options = role_settings.get("provider_options")
    provider_options = provider_options if isinstance(provider_options, dict) else {}
    section = _runtime_role_section(runtime_selection, role)
    preset = section.get("provider_preset") if isinstance(section, dict) else None
    preset_id = preset.get("id") if isinstance(preset, dict) else None
    return {
        "provider": str(role_settings.get("provider") or "gemini"),
        "provider_preset_id": preset_id,
        "model": role_settings.get("model"),
        "base_url": provider_options.get("base_url"),
    }


def _runtime_summary_from_settings(
    extractor_settings: dict[str, Any],
    paste_settings: dict[str, Any],
    loaded_env_paths: list[str],
    request_mode: str,
    runtime_selection: dict[str, Any],
) -> dict[str, Any]:
    return {
        "request_mode": request_mode,
        "extractor": _role_summary(extractor_settings, runtime_selection, RUNTIME_ROLE_EXTRACTOR),
        "paste": _role_summary(paste_settings, runtime_selection, RUNTIME_ROLE_PASTE),
        "env_paths_loaded": loaded_env_paths,
    }


def _load_prepared_source(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def _load_source_text(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def _prepared_source_matches(
    prepared_source: dict[str, Any] | None,
    runtime_selection: dict[str, Any],
    source_extract_prompt_path: Path | None,
    source_text_payload: dict[str, Any] | None = None,
) -> bool:
    if not isinstance(prepared_source, dict):
        return False
    signature = prepared_source.get("runtime_signature")
    if not isinstance(signature, dict):
        return False
    request_mode = _runtime_mode(runtime_selection)
    if signature.get("request_mode") not in {None, request_mode}:
        return False
    if request_mode == NATIVE_SOURCE_OCR_REQUEST_MODE:
        kind = prepared_source.get("source_packet_kind")
        if kind == LOCAL_SOURCE_TEXT_PACKET_KIND:
            if source_text_payload is None:
                return False
            current_source_text = build_local_source_text_packet(source_text_payload)
            if current_source_text.get("status") != "ok":
                return False
            return (
                prepared_source.get("status") == "ok"
                and signature.get("source_packet_kind") == LOCAL_SOURCE_TEXT_PACKET_KIND
                and signature.get("source_text_parameters") == SOURCE_TEXT_PARAMETERS
                and signature.get("source_text_digest") == current_source_text.get("source_text_digest")
            )
        if kind == NATIVE_SOURCE_PACKET_KIND:
            return (
                prepared_source.get("status") == "ok"
                and signature.get("source_packet_kind") == NATIVE_SOURCE_PACKET_KIND
                and signature.get("ocr_parameters") == SOURCE_OCR_PARAMETERS
            )
        return False
    extractor_section = _runtime_role_section(runtime_selection, RUNTIME_ROLE_EXTRACTOR)
    preset = extractor_section.get("provider_preset")
    if not isinstance(preset, dict):
        return False
    if signature.get("provider_preset_id") != preset.get("id"):
        return False
    if signature.get("model") != extractor_section.get("model"):
        return False
    if source_extract_prompt_path is not None and signature.get("source_extract_prompt") != str(source_extract_prompt_path):
        return False
    return prepared_source.get("status") == "ok"


def _native_source_payload(result: dict[str, Any], request_mode: str) -> dict[str, Any]:
    kind = result["source_packet_kind"]
    signature: dict[str, Any] = {
        "request_mode": request_mode,
        "source_packet_kind": kind,
    }
    if kind == LOCAL_SOURCE_TEXT_PACKET_KIND:
        signature["source_text_parameters"] = dict(SOURCE_TEXT_PARAMETERS)
        signature["source_text_digest"] = result.get("source_text_digest")
    else:
        signature["ocr_parameters"] = dict(SOURCE_OCR_PARAMETERS)
    return {
        "status": result["status"],
        "source_packet_kind": kind,
        "packet_text": result["packet_text"],
        "build_log": result["build_log"],
        "runtime_signature": signature,
    }


def _build_baseline_instruction(target_metadata: dict[str, Any]) -> str:
    metadata_json = compact_target_metadata_json(target_metadata)
    return (
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n\n"
        "Use the source image as the source context and the target image as the destination context."
    )


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
            "request_image_path": _request_rel(source_request_log),
            "bytes": source_bytes,
            "request_bytes": source_request_log.get("request_bytes"),
        },
        "target": {
            "captured_at": target_captured_at,
            "image_path": target_path_rel,
            "request_image_path": _request_rel(target_request_log),
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
    parser.add_argument("--source", type=Path, default=None, help="Path to source PNG")
    parser.add_argument("--target", type=Path, default=None, help="Path to target PNG")
    parser.add_argument("--target-meta", type=Path, default=None, help="Path to JSON target metadata")
    parser.add_argument("--caret", type=Path, default=None, help="Path to JSON caret metadata")
    parser.add_argument("--geometry", type=Path, default=None, help="Path to JSON capture geometry")
    parser.add_argument("--runtime", type=Path, default=None, help="Path to runtime selection JSON")
    parser.add_argument("--prepared-source", type=Path, default=None, help="Path to prepared source-packet JSON")
    parser.add_argument("--source-text", type=Path, default=None, help="Path to source-text capture JSON")
    parser.add_argument("--settings", type=Path, default=None, help="Path to JSON settings override")
    parser.add_argument("--prompt", type=Path, default=None, help="Path to baseline prompt text file")
    parser.add_argument("--out-dir", type=Path, default=None, help="Parent dir; bundle lands at <out-dir>/<ts>/")
    parser.add_argument(
        "--skip-gemini",
        action="store_true",
        help="Emit bundle without calling the model (useful for bundle-shape verification).",
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
    parser.add_argument(
        "--wait-on-stdin",
        action="store_true",
        help=(
            "Stay resident, print READY <pid>, then read one JSON line from stdin "
            "(args dict) and execute it. Used by Blink.app's warm-worker pre-warm "
            "path."
        ),
    )
    ns = parser.parse_args(argv)
    if not ns.wait_on_stdin:
        for name, flag in (("source", "--source"), ("target", "--target"), ("out_dir", "--out-dir")):
            if getattr(ns, name) is None:
                parser.error(f"the following argument is required: {flag}")
    return ns


_WARM_WORKER_TIMEOUT_S = 30.0


def _warm_caches() -> None:
    """Force-load the SDKs that paste-time generation may need.

    The runtime config can route Stage A and Stage B to *different* providers
    (extractor vs paste split). To make sure the warm worker doesn't pay a
    first-import cost on either path, eagerly import both Gemini's
    ``google.genai`` and ``openai`` here. Failures are swallowed — if a SDK is
    not installed, that's a config error the cold path will surface later.
    """
    try:
        import google.genai  # noqa: F401
    except Exception:  # noqa: BLE001
        pass
    try:
        import openai  # noqa: F401
    except Exception:  # noqa: BLE001
        pass


def _argv_from_request(payload: dict[str, Any]) -> list[str]:
    """Translate a JSON request dict into the argv form ``main()`` expects."""
    flag_map = {
        "source": "--source",
        "target": "--target",
        "target_meta": "--target-meta",
        "caret": "--caret",
        "geometry": "--geometry",
        "runtime": "--runtime",
        "prepared_source": "--prepared-source",
        "source_text": "--source-text",
        "settings": "--settings",
        "prompt": "--prompt",
        "out_dir": "--out-dir",
        "bundle_id": "--bundle-id",
    }
    argv: list[str] = []
    for key, flag in flag_map.items():
        value = payload.get(key)
        if value is None:
            continue
        argv.extend([flag, str(value)])
    if payload.get("skip_gemini"):
        argv.append("--skip-gemini")
    if payload.get("silent_stderr"):
        argv.append("--silent-stderr")
    return argv


def _run_warm_worker_loop() -> int:
    """Wait for one JSON request on stdin, then dispatch ``main()``."""
    import select

    _warm_caches()
    print(f"READY {os.getpid()}", flush=True)
    ready, _, _ = select.select([sys.stdin], [], [], _WARM_WORKER_TIMEOUT_S)
    if not ready:
        return 0
    line = sys.stdin.readline()
    if not line:
        return 0
    try:
        payload = json.loads(line)
    except json.JSONDecodeError as exc:
        print(f"[blink] warm worker: invalid JSON request: {exc}", file=sys.stderr)
        return 2
    if not isinstance(payload, dict):
        print("[blink] warm worker: request must be a JSON object", file=sys.stderr)
        return 2
    # Apply caller-provided env (e.g. BLINK_TARGET_CAPTURE_MS that the host
    # measured at paste-time, after the worker had already been spawned).
    request_env = payload.get("env")
    if isinstance(request_env, dict):
        for key, value in request_env.items():
            if isinstance(key, str) and isinstance(value, (str, int, float)):
                os.environ[str(key)] = str(value)
    # Mark this invocation as via the warm worker so timings reflect it.
    os.environ["BLINK_VIA_WARM_WORKER"] = "1"
    os.environ.pop("BLINK_SPAWN_NS", None)
    argv = _argv_from_request(payload)
    return main(argv)


def _python_startup_ms() -> float | None:
    """Compute time from BLINK_SPAWN_NS (mach uptime ns) to now, in ms.

    Swift sets ``BLINK_SPAWN_NS`` to ``DispatchTime.now().uptimeNanoseconds``
    just before spawning Python. ``time.monotonic_ns()`` is mach-uptime on
    macOS, so the difference captures interpreter cold-start latency.
    Returns ``None`` if the env var is missing or unparseable.
    """
    raw = os.environ.get("BLINK_SPAWN_NS")
    if not raw:
        return None
    try:
        spawn_ns = int(raw)
    except (TypeError, ValueError):
        return None
    delta_ns = time.monotonic_ns() - spawn_ns
    if delta_ns < 0:
        return 0.0
    return delta_ns / 1_000_000.0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.wait_on_stdin:
        return _run_warm_worker_loop()
    python_startup_ms = _python_startup_ms()
    via_warm_worker = os.environ.get("BLINK_VIA_WARM_WORKER") == "1"
    loaded_env_paths = [str(path) for path in load_runtime_env()]

    source_src = args.source.expanduser().resolve()
    target_src = args.target.expanduser().resolve()
    if not source_src.exists():
        print(f"source not found: {source_src}", file=sys.stderr)
        return 2
    if not target_src.exists():
        print(f"target not found: {target_src}", file=sys.stderr)
        return 2

    base_settings = dict(DEFAULT_SETTINGS)
    if args.settings is not None:
        base_settings.update(_load_json_or_default(args.settings.expanduser(), DEFAULT_SETTINGS))
    base_settings["stream_to_terminal"] = False
    base_settings["copy_to_clipboard"] = False

    runtime_selection = _load_runtime_selection(args.runtime.expanduser() if args.runtime else None)
    request_mode = _runtime_mode(runtime_selection)
    extractor_settings = _resolve_runtime_section(base_settings, runtime_selection, RUNTIME_ROLE_EXTRACTOR)
    paste_settings = _resolve_runtime_section(base_settings, runtime_selection, RUNTIME_ROLE_PASTE)
    resolved_runtimes: dict[str, dict[str, Any]] = {}

    def get_runtime(role: str = RUNTIME_ROLE_EXTRACTOR) -> dict[str, Any]:
        if role not in resolved_runtimes:
            settings = extractor_settings if role == RUNTIME_ROLE_EXTRACTOR else paste_settings
            resolved_runtimes[role] = resolve_runtime_settings(settings)
        return resolved_runtimes[role]

    baseline_prompt_path = _runtime_prompt_path(runtime_selection, "baseline_prompt")
    source_extract_prompt_path = _runtime_prompt_path(runtime_selection, "source_extract_prompt")
    source_packet_target_prompt_path = _runtime_prompt_path(runtime_selection, "source_packet_target_prompt")
    target_ocr_prompt_path = _runtime_prompt_path(runtime_selection, "target_ocr_prompt")
    target_text_only_prompt_path = _runtime_prompt_path(runtime_selection, "target_text_only_prompt")

    prompt_text = _load_prompt_or_default(
        baseline_prompt_path or (args.prompt.expanduser() if args.prompt else None)
    )
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
    geometry = (
        _load_json_or_default(args.geometry.expanduser(), STUB_GEOMETRY)
        if args.geometry
        else dict(STUB_GEOMETRY)
    )
    prepared_source = _load_prepared_source(
        args.prepared_source.expanduser() if args.prepared_source else None
    )
    source_text = _load_source_text(args.source_text.expanduser() if args.source_text else None)

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
    _save_json(bundle_dir / "target_metadata.prompt.json", compact_target_metadata(target_metadata))
    if caret is not None:
        _save_json(bundle_dir / "caret.json", caret)
    _save_json(bundle_dir / "geometry.json", geometry)
    _save_json(
        bundle_dir / "settings.json",
        {"extractor": extractor_settings, "paste": paste_settings},
    )
    if runtime_selection:
        _save_json(bundle_dir / "runtime_selection.json", runtime_selection)
    if source_text is not None:
        _save_json(bundle_dir / "source_text.json", source_text)

    run_log: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": bundle_id,
        "status": "skipped" if args.skip_gemini else "started",
        "bundle_source": BUNDLE_SOURCE,
        "runtime": _runtime_summary_from_settings(
            extractor_settings,
            paste_settings,
            loaded_env_paths,
            request_mode,
            runtime_selection,
        ),
        "prompt_path": str(baseline_prompt_path) if baseline_prompt_path else (str(args.prompt.expanduser().resolve()) if args.prompt else None),
        "settings": {
            "extractor": plain_data(extractor_settings),
            "paste": plain_data(paste_settings),
        },
        "target_metadata": plain_data(target_metadata),
        "request": {},
        "response": {},
        "timings": {},
        "errors": [],
        "warnings": list(target_metadata.get("warnings") or []),
    }
    stage_timings: dict[str, Any] = {"via_warm_worker": via_warm_worker}
    if python_startup_ms is not None:
        stage_timings["python_startup_ms"] = python_startup_ms
    elif via_warm_worker:
        # Warm-worker invocations skip the spawn-time stamp (the original
        # spawn was at ⌃⇧C, not paste-time). Surface 0 ms so consumers
        # can distinguish "no measurement" from "instant".
        stage_timings["python_startup_ms"] = 0.0

    # Swift records target screenshot capture wall time host-side and exposes
    # it through BLINK_TARGET_CAPTURE_MS so we can surface it in run.json
    # alongside python-side stages. Missing env var is fine — the host_profile
    # still has the canonical record.
    target_capture_raw = os.environ.get("BLINK_TARGET_CAPTURE_MS")
    if target_capture_raw:
        try:
            stage_timings["target_capture_ms"] = float(target_capture_raw)
        except ValueError:
            pass

    output_text = ""
    trial_start_perf = time.perf_counter()
    generation_result: dict[str, Any] | None = None
    source_packet_payload: dict[str, Any] | None = None
    target_packet_payload: dict[str, Any] | None = None
    generation_prompt_text = prompt_text
    generation_prompt_path = str(baseline_prompt_path) if baseline_prompt_path else (
        str(args.prompt.expanduser().resolve()) if args.prompt else None
    )

    if args.skip_gemini:
        _eprint("[blink] --skip-gemini set; writing bundle without calling the model", silent=args.silent_stderr)
    else:
        try:
            if request_mode == "baseline_full_images":
                instruction_text = _build_baseline_instruction(target_metadata)
                _save_text(bundle_dir / "generation.prompt.txt", generation_prompt_text)
                generation_result = generate_completion(
                    settings=extractor_settings,
                    prompt_text=generation_prompt_text,
                    content_items=[
                        {"type": "text", "text": instruction_text},
                        {"type": "image", "key": "source", "label": "SOURCE_IMAGE", "path": source_dst},
                        {"type": "image", "key": "target", "label": "TARGET_IMAGE", "path": target_dst},
                    ],
                    runtime=get_runtime(RUNTIME_ROLE_EXTRACTOR),
                    request_context={
                        "mode": "baseline_full_images",
                        "instruction_chars": len(instruction_text),
                    },
                    stream_to_terminal=False,
                )
            else:
                if _prepared_source_matches(
                    prepared_source,
                    runtime_selection,
                    source_extract_prompt_path,
                    source_text,
                ):
                    source_packet_payload = dict(prepared_source)
                    run_log.setdefault("warnings", []).append("used_prepared_source_packet")
                    stage_timings["source_packet_reused"] = True
                    stage_timings["source_packet_build_ms"] = 0.0
                else:
                    if prepared_source is not None:
                        run_log.setdefault("warnings", []).append("ignored_stale_prepared_source_packet")
                    stage_timings["source_packet_reused"] = False
                    if request_mode == NATIVE_SOURCE_OCR_REQUEST_MODE:
                        source_packet_result = build_source_packet_with_fallback(
                            source_path=source_dst,
                            source_text_payload=source_text,
                        )
                        source_packet_payload = _native_source_payload(source_packet_result, request_mode)
                        stage_timings["source_packet_build_ms"] = source_packet_result.get("build_ms", 0.0)
                    else:
                        if source_extract_prompt_path is None:
                            raise ValueError("runtime selection is missing source_extract_prompt")
                        source_extract_prompt = _load_prompt_or_default(source_extract_prompt_path)
                        source_packet_result = build_source_packet(
                            settings=extractor_settings,
                            prompt_text=source_extract_prompt,
                            source_path=source_dst,
                            runtime=get_runtime(RUNTIME_ROLE_EXTRACTOR),
                        )
                        extractor_section = _runtime_role_section(runtime_selection, RUNTIME_ROLE_EXTRACTOR)
                        source_packet_payload = {
                            "status": source_packet_result["generation"]["run_log"].get("status"),
                            "source_packet_kind": "model_extracted_text",
                            "packet_text": source_packet_result["packet_text"],
                            "prompt_path": str(source_extract_prompt_path),
                            "prompt_text": source_extract_prompt,
                            "assembled_request_text": source_packet_result["generation"]["assembled_request_text"],
                            "build_log": source_packet_result["generation"]["run_log"],
                            "run_log": source_packet_result["generation"]["run_log"],
                            "runtime_signature": {
                                "request_mode": request_mode,
                                "provider_preset_id": extractor_section.get("provider_preset", {}).get("id"),
                                "model": extractor_section.get("model"),
                                "source_extract_prompt": str(source_extract_prompt_path),
                            },
                        }
                        stage_timings["source_packet_build_ms"] = source_packet_result.get("build_ms", 0.0)

                _save_json(bundle_dir / "prepared_source.json", source_packet_payload)
                _save_text(bundle_dir / "source_packet.txt", str(source_packet_payload.get("packet_text") or ""))
                _save_json(
                    bundle_dir / "source_packet.build.json",
                    source_packet_payload.get("build_log") or {},
                )
                if source_packet_payload.get("prompt_text"):
                    _save_text(
                        bundle_dir / "source_packet.extract.prompt.txt",
                        str(source_packet_payload.get("prompt_text") or ""),
                    )
                if source_packet_payload.get("assembled_request_text"):
                    _save_text(
                        bundle_dir / "source_packet.extract.request.txt",
                        str(source_packet_payload.get("assembled_request_text") or ""),
                    )
                if source_packet_payload.get("build_log") is not None:
                    _save_json(
                        bundle_dir / "source_packet.extract.run.json",
                        source_packet_payload.get("build_log") or {},
                    )

                source_packet_text = str(source_packet_payload.get("packet_text") or "").strip()
                if not source_packet_text:
                    raise RuntimeError("source packet is empty")

                if request_mode == "source_packet_full_target_image":
                    if source_packet_target_prompt_path is None:
                        raise ValueError("runtime selection is missing source_packet_target_prompt")
                    generation_prompt_text = _load_prompt_or_default(source_packet_target_prompt_path)
                    generation_prompt_path = str(source_packet_target_prompt_path)
                    generation_result = run_source_packet_target_full_image(
                        settings=paste_settings,
                        prompt_text=generation_prompt_text,
                        source_packet_text=source_packet_text,
                        target_path=target_dst,
                        target_metadata=target_metadata,
                        runtime=get_runtime(RUNTIME_ROLE_PASTE),
                    )
                elif request_mode == NATIVE_SOURCE_OCR_REQUEST_MODE:
                    if source_packet_target_prompt_path is None:
                        raise ValueError("runtime selection is missing source_packet_target_prompt")
                    if target_text_only_prompt_path is None:
                        raise ValueError("runtime selection is missing target_text_only_prompt")
                    target_text_payload = build_target_ocr_text(
                        target_path=target_dst,
                        target_metadata=target_metadata,
                        geometry=geometry,
                    )
                    _save_text(bundle_dir / "target_ocr_text.txt", target_text_payload["text"])
                    _save_json(bundle_dir / "target_ocr_text.build.json", target_text_payload["build_log"])
                    if isinstance(target_text_payload.get("build_log"), dict):
                        ocr_ms = target_text_payload["build_log"].get("ocr_ms")
                        if ocr_ms is not None:
                            stage_timings["target_ocr_ms"] = ocr_ms
                        for reason in target_text_payload["build_log"].get("focus_hint_reasons") or []:
                            run_log.setdefault("warnings", []).append(
                                f"target_text_focus_hint:{reason}"
                            )
                    target_route = choose_text_only_target_path(
                        target_metadata=target_metadata,
                        target_ocr_text_payload=target_text_payload,
                    )
                    run_log["target_context"] = {
                        "mode": target_route["mode"],
                        "fallback_reason": target_route.get("fallback_reason"),
                        "focused_role": target_metadata.get("focused_role"),
                        "ocr_status": target_text_payload.get("status"),
                        "ocr_text_chars": target_text_payload.get("text_chars"),
                        "focused_label_hint": target_text_payload.get("focused_label_hint"),
                    }
                    if target_route["mode"] == "text_only":
                        generation_prompt_text = _load_prompt_or_default(target_text_only_prompt_path)
                        generation_prompt_path = str(target_text_only_prompt_path)
                        generation_result = run_source_packet_target_text_only(
                            settings=extractor_settings,
                            prompt_text=generation_prompt_text,
                            source_packet_text=source_packet_text,
                            target_ocr_text=str(target_text_payload.get("text") or ""),
                            target_metadata=target_metadata,
                            runtime=get_runtime(RUNTIME_ROLE_EXTRACTOR),
                            focused_label_hint=target_text_payload.get("focused_label_hint"),
                        )
                    else:
                        generation_prompt_text = _load_prompt_or_default(source_packet_target_prompt_path)
                        generation_prompt_path = str(source_packet_target_prompt_path)
                        generation_result = run_source_packet_target_full_image(
                            settings=extractor_settings,
                            prompt_text=generation_prompt_text,
                            source_packet_text=source_packet_text,
                            target_path=target_dst,
                            target_metadata=target_metadata,
                            runtime=get_runtime(RUNTIME_ROLE_EXTRACTOR),
                        )
                        fallback_reason = target_route.get("fallback_reason")
                        if fallback_reason:
                            run_log.setdefault("warnings", []).append(
                                f"target_text_only_fallback:{fallback_reason}"
                            )
                else:
                    if target_ocr_prompt_path is None:
                        raise ValueError("runtime selection is missing target_ocr_prompt")
                    target_packet_payload = build_target_ocr_packet(
                        target_path=target_dst,
                        target_metadata=target_metadata,
                        geometry=geometry,
                    )
                    _save_text(bundle_dir / "target_ocr_packet.txt", target_packet_payload["packet_text"])
                    _save_json(bundle_dir / "target_ocr_packet.build.json", target_packet_payload["build_log"])
                    if isinstance(target_packet_payload.get("build_log"), dict):
                        ocr_ms = target_packet_payload["build_log"].get("ocr_ms")
                        if ocr_ms is not None:
                            stage_timings["target_ocr_ms"] = ocr_ms
                    run_log["target_context"] = {
                        "completeness": target_packet_payload.get("completeness"),
                        "fallback_reasons": target_packet_payload.get("fallback_reasons"),
                    }

                    use_full_target_image = (
                        request_mode == "source_packet_target_ocr_or_full_image"
                        and bool(target_packet_payload.get("fallback_reasons"))
                    )
                    if use_full_target_image:
                        if source_packet_target_prompt_path is None:
                            raise ValueError("runtime selection is missing source_packet_target_prompt")
                        generation_prompt_text = _load_prompt_or_default(source_packet_target_prompt_path)
                        generation_prompt_path = str(source_packet_target_prompt_path)
                        generation_result = run_source_packet_target_full_image(
                            settings=paste_settings,
                            prompt_text=generation_prompt_text,
                            source_packet_text=source_packet_text,
                            target_path=target_dst,
                            target_metadata=target_metadata,
                            runtime=get_runtime(RUNTIME_ROLE_PASTE),
                        )
                        run_log.setdefault("warnings", []).append("fell_back_to_full_target_image")
                    else:
                        generation_prompt_text = _load_prompt_or_default(target_ocr_prompt_path)
                        generation_prompt_path = str(target_ocr_prompt_path)
                        generation_result = run_source_packet_target_ocr_packet(
                            settings=paste_settings,
                            prompt_text=generation_prompt_text,
                            source_packet_text=source_packet_text,
                            target_packet_text=target_packet_payload["packet_text"],
                            target_metadata=target_metadata,
                            runtime=get_runtime(RUNTIME_ROLE_PASTE),
                        )

                run_log["source_packet"] = {
                    "status": source_packet_payload.get("status"),
                    "prepared": _prepared_source_matches(
                        prepared_source,
                        runtime_selection,
                        source_extract_prompt_path,
                        source_text,
                    ),
                    "packet_chars": len(source_packet_text),
                    "kind": source_packet_payload.get("source_packet_kind"),
                }

            if generation_result is None:
                raise RuntimeError("no generation result produced")

            _save_text(bundle_dir / "generation.prompt.txt", generation_prompt_text)
            _save_text(bundle_dir / "generation.request.txt", generation_result["assembled_request_text"])

            inner = generation_result["run_log"]
            output_text = generation_result["output_text"]
            run_log["status"] = inner.get("status", "ok")
            run_log["prompt_path"] = generation_prompt_path
            run_log["request"] = inner.get("request", {})
            run_log["response"] = inner.get("response", {})
            run_log["timings"] = {**inner.get("timings", {}), **stage_timings}
            inner_errors = inner.get("errors") or []
            if inner_errors:
                run_log["errors"] = list(inner_errors)
        except Exception as exc:
            run_log["status"] = "error"
            run_log["errors"].append(str(exc))
            _eprint(f"[blink] model error: {exc}", silent=args.silent_stderr)
            # Even on failure, surface what stage timings we collected.
            run_log["timings"] = {**run_log.get("timings", {}), **stage_timings}

    existing_text = target_metadata.get("focused_value") if isinstance(target_metadata, dict) else None
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
        "existing_text_length": len(existing_text) if isinstance(existing_text, str) else None,
    }
    timings = run_log.setdefault("timings", {})
    for key, value in stage_timings.items():
        timings.setdefault(key, value)
    timings["end_to_end_ms"] = duration_ms(trial_start_perf)

    fixture_manifest = _fixture_manifest(
        bundle_dir=bundle_dir,
        settings=extractor_settings,
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
    _save_text(bundle_dir / "output.txt", output_text)

    _eprint(f"[blink] status={run_log['status']} chars={len(pasted_text)}", silent=args.silent_stderr)
    sys.stdout.write(pasted_text)
    sys.stdout.flush()
    return 0 if run_log["status"] in {"ok", "skipped"} else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingCredentialError as exc:
        print(f"[blink] {exc}", file=sys.stderr)
        raise SystemExit(2)
    except Exception as exc:
        print(
            f"[blink] fatal runner error: {exc.__class__.__name__}: {exc}",
            file=sys.stderr,
        )
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(1)
