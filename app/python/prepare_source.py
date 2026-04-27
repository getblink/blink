#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path
from typing import Any

from env_loader import load_runtime_env
from gemini_runner import plain_data
from providers import MissingCredentialError, resolve_runtime_settings
from run_once import (
    DEFAULT_SETTINGS,
    RUNTIME_ROLE_EXTRACTOR,
    _load_json_or_default,
    _load_runtime_selection,
    _resolve_runtime_section,
    _runtime_role_section,
)
from source_packet import build_source_packet
from source_ocr import (
    NATIVE_SOURCE_OCR_REQUEST_MODE,
    SOURCE_OCR_PARAMETERS,
    build_native_ocr_source_packet,
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare cached source packet for Blink.app")
    parser.add_argument("--source", required=True, type=Path, help="Path to source PNG")
    parser.add_argument("--runtime", required=True, type=Path, help="Path to runtime-selection JSON")
    parser.add_argument("--settings", type=Path, default=None, help="Path to settings override JSON")
    parser.add_argument("--silent-stderr", action="store_true", help="Suppress progress logs on stderr")
    return parser.parse_args(argv)


def _eprint(message: str, *, silent: bool) -> None:
    if not silent:
        print(message, file=sys.stderr, flush=True)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    load_runtime_env()

    source_path = args.source.expanduser().resolve()
    if not source_path.exists():
        print(f"source not found: {source_path}", file=sys.stderr)
        return 2

    settings = dict(DEFAULT_SETTINGS)
    if args.settings is not None:
        settings.update(_load_json_or_default(args.settings.expanduser(), DEFAULT_SETTINGS))
    runtime_selection = _load_runtime_selection(args.runtime.expanduser())
    request_mode = str(runtime_selection.get("request_mode") or "baseline_full_images")

    _eprint("[blink] preparing source packet...", silent=args.silent_stderr)
    if request_mode == NATIVE_SOURCE_OCR_REQUEST_MODE:
        result = build_native_ocr_source_packet(source_path=source_path)
        payload = {
            "status": result["status"],
            "source_packet_kind": result["source_packet_kind"],
            "packet_text": result["packet_text"],
            "build_log": result["build_log"],
            "runtime_signature": {
                "request_mode": request_mode,
                "source_packet_kind": result["source_packet_kind"],
                "ocr_parameters": dict(SOURCE_OCR_PARAMETERS),
            },
        }
    else:
        extractor_settings = _resolve_runtime_section(settings, runtime_selection, RUNTIME_ROLE_EXTRACTOR)
        runtime = resolve_runtime_settings(extractor_settings)
        prompt_path = Path(runtime_selection["paths"]["source_extract_prompt"])
        prompt_text = prompt_path.read_text(encoding="utf-8").strip()
        result = build_source_packet(
            settings=extractor_settings,
            prompt_text=prompt_text,
            source_path=source_path,
            runtime=runtime,
        )
        extractor_section = _runtime_role_section(runtime_selection, RUNTIME_ROLE_EXTRACTOR)
        payload = {
            "status": result["generation"]["run_log"].get("status"),
            "source_packet_kind": "model_extracted_text",
            "packet_text": result["packet_text"],
            "prompt_path": str(prompt_path),
            "prompt_text": prompt_text,
            "assembled_request_text": result["generation"]["assembled_request_text"],
            "build_log": result["generation"]["run_log"],
            "run_log": result["generation"]["run_log"],
            "runtime_signature": {
                "request_mode": request_mode,
                "provider_preset_id": extractor_section.get("provider_preset", {}).get("id"),
                "model": extractor_section.get("model"),
                "source_extract_prompt": str(prompt_path),
            },
        }
    json.dump(plain_data(payload), sys.stdout, indent=2, ensure_ascii=True)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0 if payload["status"] == "ok" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingCredentialError as exc:
        print(f"[blink] {exc}", file=sys.stderr)
        raise SystemExit(2)
    except Exception as exc:
        print(
            f"[blink] source packet prep failed: {exc.__class__.__name__}: {exc}",
            file=sys.stderr,
        )
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(1)
