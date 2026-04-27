#!/usr/bin/env python3
"""Probe each (provider preset, suggested model) combo to discover which
parameters from `app/python/run_once.py:DEFAULT_SETTINGS` they accept.

Why: today's `DEFAULT_SETTINGS` blanket-applies `thinking_level: MINIMAL` and
`media_resolution: MEDIA_RESOLUTION_LOW` to every model. Some Gemini variants
(e.g. `gemini-2.5-flash-lite`) reject `thinking_level` with HTTP 400. Some
non-Gemini providers reject vision input on text-only models with their own
error string. This script catalogs which parameter combos work for each model
so we can build an informed denylist (or per-model parameter fixups).

Output: `scratchpad/sweeps/model-capability-probe-<ts>/results.json` plus a
short stdout summary table.

Cost: each probe is a tiny (a few tokens) request. Total is well under $0.05.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any

# Reuse the production code rather than re-implementing the SDK plumbing.
APP_PYTHON_DIR = Path(__file__).resolve().parent.parent / "app" / "python"
SCRATCHPAD_DIR = Path(__file__).resolve().parent
RESOURCES_DIR = Path(__file__).resolve().parent.parent / "app" / "Resources"
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from env_loader import load_runtime_env  # noqa: E402
from model_runner import generate_completion  # noqa: E402
from providers import MissingCredentialError, resolve_runtime_settings  # noqa: E402

PROVIDER_PRESETS_PATH = RESOURCES_DIR / "provider_presets.json"

BASE_SETTINGS: dict[str, Any] = {
    "temperature": 0.0,
    "max_output_tokens": 64,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "thinking_level": "MINIMAL",
    "timeout_seconds": 30,
    "preprocess_request_images": True,
    "request_image_format": "jpeg",
    "request_image_max_dimension": 256,
    "request_image_jpeg_quality": 60,
}

PROBE_PROMPT = "Reply with the single word OK and nothing else."
PROBE_TEXT_INSTRUCTION = "Say OK."
PROBE_IMAGE_INSTRUCTION = "Reply OK."


def _make_tiny_png(out_path: Path) -> None:
    """Write a 32x32 black PNG without external deps."""
    import struct
    import zlib

    width = height = 32
    raw = b"".join(b"\x00" + b"\x00" * (width * 3) for _ in range(height))
    compressed = zlib.compress(raw, 9)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    out_path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )


def _load_presets() -> list[dict[str, Any]]:
    return json.loads(PROVIDER_PRESETS_PATH.read_text())


def _settings_for(preset: dict[str, Any], model: str, *, drop_thinking: bool = False) -> dict[str, Any]:
    settings: dict[str, Any] = dict(BASE_SETTINGS)
    settings["model"] = model
    settings["provider"] = preset["provider"]
    settings["provider_options"] = {
        "api_key_env": preset["api_key_env"],
        "api_style": preset["api_style"],
        "base_url": preset.get("base_url"),
        "url_substitutions": list(preset.get("url_substitutions") or []),
        "default_headers": dict(preset.get("default_headers") or {}),
        "extra_headers": dict(preset.get("extra_headers") or {}),
    }
    if drop_thinking:
        settings["thinking_level"] = None
    return settings


def _probe(
    *,
    label: str,
    settings: dict[str, Any],
    content_items: list[dict[str, Any]],
) -> dict[str, Any]:
    started = time.perf_counter()
    record: dict[str, Any] = {
        "label": label,
        "model": settings["model"],
        "provider": settings["provider"],
        "thinking_level": settings.get("thinking_level"),
    }
    try:
        runtime = resolve_runtime_settings(settings)
    except MissingCredentialError as exc:
        record["status"] = "skipped_missing_credential"
        record["error"] = str(exc)
        record["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
        return record
    except Exception as exc:  # noqa: BLE001
        record["status"] = "skipped_resolve_error"
        record["error"] = f"{type(exc).__name__}: {exc}"
        record["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
        return record

    try:
        result = generate_completion(
            settings=settings,
            prompt_text=PROBE_PROMPT,
            content_items=content_items,
            runtime=runtime,
            request_context={"mode": f"probe_{label}"},
            stream_to_terminal=False,
        )
    except Exception as exc:  # noqa: BLE001
        record["status"] = "exception"
        record["error"] = f"{type(exc).__name__}: {exc}"
        record["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
        return record

    inner = result["run_log"]
    record["status"] = inner.get("status")
    record["output_text"] = result.get("output_text", "")[:120]
    record["errors"] = inner.get("errors") or []
    record["ttft_ms"] = inner.get("timings", {}).get("ttft_ms")
    record["model_latency_ms"] = inner.get("timings", {}).get("model_latency_ms")
    record["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 1)
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe model parameter compatibility")
    parser.add_argument(
        "--out-root",
        type=Path,
        default=SCRATCHPAD_DIR / "sweeps",
        help="Where to write the sweep folder",
    )
    parser.add_argument(
        "--only-preset",
        action="append",
        default=None,
        help="Restrict to a specific preset id (repeatable)",
    )
    args = parser.parse_args()

    load_runtime_env()
    presets = _load_presets()
    if args.only_preset:
        wanted = set(args.only_preset)
        presets = [p for p in presets if p["id"] in wanted]

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    sweep_dir = args.out_root / f"model-capability-probe-{ts}"
    sweep_dir.mkdir(parents=True, exist_ok=True)
    image_path = sweep_dir / "tiny.png"
    _make_tiny_png(image_path)

    text_items = [{"type": "text", "text": PROBE_TEXT_INSTRUCTION}]
    image_items = [
        {"type": "text", "text": PROBE_IMAGE_INSTRUCTION},
        {"type": "image", "key": "probe", "label": "PROBE_IMAGE", "path": image_path},
    ]

    results: list[dict[str, Any]] = []
    print(
        f"{'preset':<24} {'model':<48} {'probe':<24} {'status':<14} {'elapsed':<8} note",
        flush=True,
    )
    for preset in presets:
        models = preset.get("suggested_models") or [preset.get("default_model")]
        for model in models:
            if not model:
                continue
            for probe_label, items, drop_thinking in (
                ("text_default", text_items, False),
                ("image_default", image_items, False),
                ("text_no_thinking", text_items, True),
                ("image_no_thinking", image_items, True),
            ):
                settings = _settings_for(preset, model, drop_thinking=drop_thinking)
                record = _probe(label=probe_label, settings=settings, content_items=items)
                record["preset_id"] = preset["id"]
                record["preset_name"] = preset["name"]
                results.append(record)
                note_parts = []
                if record.get("errors"):
                    note_parts.append(str(record["errors"])[:140])
                elif record.get("error"):
                    note_parts.append(str(record["error"])[:140])
                elif record.get("output_text"):
                    note_parts.append(repr(record["output_text"])[:60])
                note = " | ".join(note_parts)
                print(
                    f"{preset['id']:<24} {model:<48} {probe_label:<24} {record['status']:<14} "
                    f"{int(record.get('elapsed_ms') or 0):>5}ms  {note}",
                    flush=True,
                )

    out_path = sweep_dir / "results.json"
    out_path.write_text(json.dumps(results, indent=2))
    print(f"\nwrote {out_path}")

    # Quick capability summary: per (preset, model), did each probe succeed?
    summary: dict[tuple[str, str], dict[str, str]] = {}
    for r in results:
        key = (r["preset_id"], r["model"])
        summary.setdefault(key, {})[r["label"]] = r["status"]
    summary_path = sweep_dir / "summary.md"
    lines = ["# Model capability summary", ""]
    lines.append("| preset | model | text_default | image_default | text_no_thinking | image_no_thinking |")
    lines.append("|---|---|---|---|---|---|")
    for (preset_id, model), probe_status in sorted(summary.items()):
        cells = [
            preset_id,
            model,
            probe_status.get("text_default", "-"),
            probe_status.get("image_default", "-"),
            probe_status.get("text_no_thinking", "-"),
            probe_status.get("image_no_thinking", "-"),
        ]
        lines.append("| " + " | ".join(cells) + " |")
    summary_path.write_text("\n".join(lines) + "\n")
    print(f"wrote {summary_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        raise SystemExit(1)
