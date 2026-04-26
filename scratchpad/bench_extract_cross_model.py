#!/usr/bin/env python3
"""Cross-model bake-off for the source-packet extraction prompt.

Runs the v3.1 (or any) source-packet extraction prompt across every config
under scratchpad/eval_configs/ on a fixture corpus, scores each config via
compare_source_packets, and emits a top-level summary.md comparing salient
recall, source-kind accuracy, candidate-field loose recall, can_answer
accuracy, and extraction latency per config.

Source-image only — does NOT send the target image. This is what the v3.1
extraction prompt actually sees in production.

Usage:
    python scratchpad/bench_extract_cross_model.py \
        --fixtures 'scratchpad/fixtures/*' \
        --configs 'scratchpad/eval_configs/*.json' \
        --extract-prompt-path scratchpad/source_packet_extract_prompt_v3_1_ocr.txt \
        --out scratchpad/sweeps/v3-1-cross-model-<date>
"""

from __future__ import annotations

import argparse
import base64
import glob
import json
import os
import statistics
import sys
import time
from pathlib import Path
from typing import Any

from google import genai
from google.genai import types
from openai import OpenAI

import compare_source_packets as csp
from env_loader import load_workspace_env
from gemini_runner import (
    build_generation_config,
    duration_ms,
    now_iso,
    plain_data,
    prepare_request_image,
)
from providers import (
    MissingCredentialError,
    provider_name,
    resolve_runtime_settings,
)


BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent
SETTINGS_PATH = BASE_DIR / "settings.json"
DEFAULT_EXTRACT_PROMPT_PATH = BASE_DIR / "source_packet_extract_prompt_v3_1_ocr.txt"

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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Cross-model bake-off for the source-packet extraction prompt.",
    )
    parser.add_argument(
        "--fixtures",
        required=True,
        help="Glob for fixture directories, e.g. 'scratchpad/fixtures/*'.",
    )
    parser.add_argument(
        "--configs",
        required=True,
        help="Glob for config JSON files, e.g. 'scratchpad/eval_configs/*.json'.",
    )
    parser.add_argument(
        "--extract-prompt-path",
        default=str(DEFAULT_EXTRACT_PROMPT_PATH),
        help="Path to the source-packet extraction prompt under test.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output directory for sweep artifacts.",
    )
    parser.add_argument(
        "--limit-fixtures",
        type=int,
        default=None,
        help="Optional cap on number of fixtures (debug/smoke).",
    )
    parser.add_argument(
        "--gold",
        default=str(ROOT_DIR / "scratchpad" / "gold_source_packets.json"),
        help="Path to the gold packet corpus for scoring.",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=int,
        default=2048,
        help=(
            "Override max_output_tokens for every config so each model has enough "
            "headroom to fully transcribe the source. The default 512 from settings.json "
            "is too tight for log-heavy fixtures."
        ),
    )
    return parser.parse_args()


def resolve_from_root(path_str: str) -> Path:
    path = Path(path_str).expanduser()
    if path.is_absolute():
        return path
    return (ROOT_DIR / path).resolve()


def load_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json_file(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def expand_glob(pattern: str) -> list[Path]:
    absolute_pattern = pattern if pattern.startswith("/") else str(ROOT_DIR / pattern)
    return sorted(Path(match) for match in glob.glob(absolute_pattern))


def load_settings_for_config(config_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    settings = dict(DEFAULT_SETTINGS)
    if SETTINGS_PATH.exists():
        settings.update(load_json_file(SETTINGS_PATH))
    raw_config = load_json_file(config_path)
    for key, value in raw_config.items():
        if key not in {"name", "prompt_path"}:
            settings[key] = value
    settings["stream_to_terminal"] = False
    settings["copy_to_clipboard"] = False
    settings["provider"] = provider_name(settings)
    return settings, raw_config


def fixture_record(fixture_dir: Path) -> dict[str, Any]:
    manifest = load_json_file(fixture_dir / "fixture.json")
    return {
        "fixture_id": manifest["fixture_id"],
        "fixture_dir": fixture_dir,
        "source_path": fixture_dir / manifest["source"]["image_path"],
    }


def _gemini_client(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    runtime: dict[str, Any],
) -> genai.Client:
    timeout_ms = int(float(settings.get("timeout_seconds", 120)) * 1000)
    cache_key = ("gemini", runtime["api_key"], timeout_ms)
    client = client_cache.get(cache_key)
    if client is None:
        client = genai.Client(
            api_key=runtime["api_key"],
            http_options=types.HttpOptions(timeout=timeout_ms),
        )
        client_cache[cache_key] = client
    return client


def _openai_client(
    client_cache: dict[tuple[Any, ...], Any],
    runtime: dict[str, Any],
) -> OpenAI:
    headers = runtime.get("default_headers") or {}
    cache_key = (
        "openai_sdk",
        runtime["api_key"],
        runtime.get("base_url") or "",
        tuple(sorted(headers.items())),
    )
    client = client_cache.get(cache_key)
    if client is None:
        client_kwargs: dict[str, Any] = {
            "api_key": runtime["api_key"],
            "default_headers": headers or None,
        }
        if runtime.get("base_url"):
            client_kwargs["base_url"] = runtime["base_url"]
        client = OpenAI(**client_kwargs)
        client_cache[cache_key] = client
    return client


def _empty_run_log(provider: str, model: str, error_message: str) -> dict[str, Any]:
    return {
        "status": "error",
        "request": {"provider": provider, "model": model},
        "response": {"output_text": "", "output_text_length": 0},
        "timings": {},
        "errors": [error_message],
    }


def extract_gemini(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    runtime: dict[str, Any],
    prompt_text: str,
    source_path: Path,
) -> dict[str, Any]:
    """Source-only Gemini extraction. Mirrors benchmark_source_packet.build_source_packet."""
    client = _gemini_client(client_cache, settings, runtime)

    prepare_started_perf = time.perf_counter()
    source_request_image = prepare_request_image(source_path, settings)
    parts = [
        types.Content(
            role="user",
            parts=[
                types.Part.from_text(text="SOURCE_IMAGE"),
                types.Part.from_bytes(
                    data=source_request_image["bytes_data"],
                    mime_type=source_request_image["mime_type"],
                ),
            ],
        ),
    ]
    request_build_ms = duration_ms(prepare_started_perf)

    config = build_generation_config(settings, prompt_text)
    request_send_perf = time.perf_counter()
    request_send_at = now_iso()

    output_chunks: list[str] = []
    first_chunk_perf: float | None = None
    final_chunk_perf: float | None = None
    first_chunk_at: str | None = None
    final_chunk_at: str | None = None
    usage_metadata: Any = None
    final_chunk_payload: Any = None
    chunk_count = 0
    status = "ok"
    error_message = None

    try:
        stream = client.models.generate_content_stream(
            model=settings["model"],
            contents=parts,
            config=config,
        )
        for chunk in stream:
            chunk_count += 1
            chunk_perf = time.perf_counter()
            if first_chunk_perf is None:
                first_chunk_perf = chunk_perf
                first_chunk_at = now_iso()
            final_chunk_perf = chunk_perf
            final_chunk_at = now_iso()
            if getattr(chunk, "text", None):
                output_chunks.append(chunk.text)
            if getattr(chunk, "usage_metadata", None) is not None:
                usage_metadata = plain_data(chunk.usage_metadata)
            final_chunk_payload = plain_data(chunk)
    except Exception as exc:
        status = "error"
        error_message = str(exc)

    finished_perf = time.perf_counter()
    if final_chunk_perf is None:
        final_chunk_perf = finished_perf

    output_text = "".join(output_chunks).strip()
    stream_duration_ms = (
        duration_ms(first_chunk_perf, final_chunk_perf)
        if first_chunk_perf is not None
        else None
    )

    run_log: dict[str, Any] = {
        "status": status,
        "request": {
            "provider": "gemini",
            "model": settings["model"],
            "request_send_at": request_send_at,
            "prompt_chars": len(prompt_text),
            "instruction_chars": len(prompt_text),
            "source_image_bytes": source_request_image["request_bytes"],
            "source_original_image_bytes": source_request_image["original_bytes"],
            "images": {"source": source_request_image["log"]},
        },
        "response": {
            "usage_metadata": usage_metadata,
            "chunk_count": chunk_count,
            "response_metadata": final_chunk_payload,
            "output_text": output_text,
            "output_text_length": len(output_text),
        },
        "timings": {
            "request_build_ms": request_build_ms,
            "source_image_prepare_ms": source_request_image["duration_ms"],
            "request_send_at": request_send_at,
            "first_chunk_at": first_chunk_at,
            "final_chunk_at": final_chunk_at,
            "ttft_ms": duration_ms(request_send_perf, first_chunk_perf)
            if first_chunk_perf is not None
            else None,
            "stream_duration_ms": stream_duration_ms,
            "model_latency_ms": duration_ms(request_send_perf, final_chunk_perf),
        },
    }
    if error_message:
        run_log["errors"] = [error_message]
    return {"run_log": run_log, "output_text": output_text}


def extract_openai_sdk(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    runtime: dict[str, Any],
    prompt_text: str,
    source_path: Path,
) -> dict[str, Any]:
    """Source-only OpenAI-style extraction. Mirrors providers.openai_sdk.generate_completion
    but sends only the source image."""
    client = _openai_client(client_cache, runtime)

    prepare_started_perf = time.perf_counter()
    source_request_image = prepare_request_image(source_path, settings)
    source_b64 = base64.b64encode(source_request_image["bytes_data"]).decode("ascii")
    source_data_uri = f"data:{source_request_image['mime_type']};base64,{source_b64}"
    instruction_text = "Use the source image as the source context."
    request_build_ms = duration_ms(prepare_started_perf)

    api_style = runtime["api_style"]
    request_client = client.with_options(timeout=float(settings.get("timeout_seconds", 120)))

    output_chunks: list[str] = []
    first_chunk_perf: float | None = None
    final_chunk_perf: float | None = None
    first_chunk_at: str | None = None
    final_chunk_at: str | None = None
    usage_metadata: Any = None
    final_chunk_payload: Any = None
    chunk_count = 0
    status = "ok"
    error_message = None

    request_send_perf = time.perf_counter()
    request_send_at = now_iso()

    try:
        if api_style == "chat_completions":
            messages = [
                {"role": "system", "content": prompt_text},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": instruction_text},
                        {"type": "text", "text": "SOURCE_IMAGE"},
                        {"type": "image_url", "image_url": {"url": source_data_uri}},
                    ],
                },
            ]
            request_kwargs: dict[str, Any] = {
                "model": settings["model"],
                "messages": messages,
                "stream": True,
                "stream_options": {"include_usage": True},
            }
            if settings.get("temperature") is not None:
                request_kwargs["temperature"] = float(settings["temperature"])
            if settings.get("max_output_tokens") is not None:
                request_kwargs["max_tokens"] = int(settings["max_output_tokens"])
            if runtime.get("extra_body") is not None:
                request_kwargs["extra_body"] = runtime["extra_body"]
            if runtime.get("extra_headers"):
                request_kwargs["extra_headers"] = runtime["extra_headers"]

            request_send_perf = time.perf_counter()
            request_send_at = now_iso()
            stream = request_client.chat.completions.create(**request_kwargs)
            for chunk in stream:
                chunk_count += 1
                chunk_perf = time.perf_counter()
                if first_chunk_perf is None:
                    first_chunk_perf = chunk_perf
                    first_chunk_at = now_iso()
                final_chunk_perf = chunk_perf
                final_chunk_at = now_iso()

                if chunk.choices:
                    delta = chunk.choices[0].delta
                    if getattr(delta, "content", None):
                        output_chunks.append(delta.content)
                if getattr(chunk, "usage", None) is not None:
                    usage_metadata = plain_data(chunk.usage)
                final_chunk_payload = plain_data(chunk)
        elif api_style == "responses":
            responses_input = [
                {
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": instruction_text},
                        {"type": "input_text", "text": "SOURCE_IMAGE"},
                        {"type": "input_image", "image_url": source_data_uri},
                    ],
                }
            ]
            request_kwargs = {
                "model": settings["model"],
                "instructions": prompt_text,
                "input": responses_input,
                "stream": True,
            }
            if settings.get("temperature") is not None:
                request_kwargs["temperature"] = float(settings["temperature"])
            if settings.get("max_output_tokens") is not None:
                request_kwargs["max_output_tokens"] = int(settings["max_output_tokens"])
            if runtime.get("extra_body") is not None:
                request_kwargs["extra_body"] = runtime["extra_body"]
            if runtime.get("extra_headers"):
                request_kwargs["extra_headers"] = runtime["extra_headers"]

            completed_response = None
            request_send_perf = time.perf_counter()
            request_send_at = now_iso()
            stream = request_client.responses.create(**request_kwargs)
            for event in stream:
                chunk_count += 1
                chunk_perf = time.perf_counter()
                if first_chunk_perf is None:
                    first_chunk_perf = chunk_perf
                    first_chunk_at = now_iso()
                final_chunk_perf = chunk_perf
                final_chunk_at = now_iso()

                event_type = getattr(event, "type", "")
                if event_type == "response.output_text.delta" and getattr(event, "delta", None):
                    output_chunks.append(event.delta)
                elif event_type == "response.completed":
                    completed_response = getattr(event, "response", None)
                    usage_metadata = plain_data(getattr(completed_response, "usage", None))
                elif event_type in {"response.failed", "response.incomplete"}:
                    status = "error"
                    completed_response = getattr(event, "response", None)
                    usage_metadata = plain_data(getattr(completed_response, "usage", None))
                    err = getattr(completed_response, "error", None)
                    error_message = (
                        getattr(err, "message", None)
                        if err is not None
                        else str(getattr(completed_response, "status", event_type))
                    )
                elif event_type == "error":
                    status = "error"
                    error_message = str(getattr(event, "message", "streaming error"))
                final_chunk_payload = plain_data(event)

            if completed_response is not None and not output_chunks:
                completed_text = getattr(completed_response, "output_text", None)
                if completed_text:
                    output_chunks.append(str(completed_text))
            if completed_response is not None:
                final_chunk_payload = plain_data(completed_response)
        else:
            raise ValueError(f"Unsupported api_style: {api_style}")
    except Exception as exc:
        status = "error"
        error_message = str(exc)

    finished_perf = time.perf_counter()
    if final_chunk_perf is None:
        final_chunk_perf = finished_perf

    output_text = "".join(output_chunks).strip()
    stream_duration_ms = (
        duration_ms(first_chunk_perf, final_chunk_perf)
        if first_chunk_perf is not None
        else None
    )

    run_log: dict[str, Any] = {
        "status": status,
        "request": {
            "provider": "openai_sdk",
            "api_style": api_style,
            "base_url": runtime.get("base_url"),
            "model": settings["model"],
            "request_send_at": request_send_at,
            "prompt_chars": len(prompt_text),
            "instruction_chars": len(instruction_text),
            "source_image_bytes": source_request_image["request_bytes"],
            "source_original_image_bytes": source_request_image["original_bytes"],
            "images": {"source": source_request_image["log"]},
        },
        "response": {
            "usage_metadata": usage_metadata,
            "chunk_count": chunk_count,
            "response_metadata": final_chunk_payload,
            "output_text": output_text,
            "output_text_length": len(output_text),
        },
        "timings": {
            "request_build_ms": request_build_ms,
            "source_image_prepare_ms": source_request_image["duration_ms"],
            "request_send_at": request_send_at,
            "first_chunk_at": first_chunk_at,
            "final_chunk_at": final_chunk_at,
            "ttft_ms": duration_ms(request_send_perf, first_chunk_perf)
            if first_chunk_perf is not None
            else None,
            "stream_duration_ms": stream_duration_ms,
            "model_latency_ms": duration_ms(request_send_perf, final_chunk_perf),
        },
    }
    if error_message:
        run_log["errors"] = [error_message]
    return {"run_log": run_log, "output_text": output_text}


def run_extract(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    runtime: dict[str, Any],
    prompt_text: str,
    source_path: Path,
) -> dict[str, Any]:
    provider = runtime["provider"]
    if provider == "gemini":
        return extract_gemini(client_cache, settings, runtime, prompt_text, source_path)
    if provider == "openai_sdk":
        return extract_openai_sdk(client_cache, settings, runtime, prompt_text, source_path)
    raise ValueError(f"Unsupported provider: {provider}")


def run_one_config(
    config_path: Path,
    fixtures: list[dict[str, Any]],
    prompt_text: str,
    out_dir: Path,
    client_cache: dict[tuple[Any, ...], Any],
    *,
    max_output_tokens: int | None = None,
) -> dict[str, Any]:
    settings, raw_config = load_settings_for_config(config_path)
    if max_output_tokens is not None:
        settings["max_output_tokens"] = int(max_output_tokens)
    config_name = raw_config.get("name") or config_path.stem
    config_out = out_dir / config_name
    config_out.mkdir(parents=True, exist_ok=True)

    record: dict[str, Any] = {
        "name": config_name,
        "config_path": str(config_path),
        "provider": settings.get("provider"),
        "model": settings.get("model"),
        "api_style": (settings.get("provider_options") or {}).get("api_style", "n/a"),
        "skipped": False,
        "skip_reason": None,
        "fixture_runs": [],
    }

    try:
        runtime = resolve_runtime_settings(settings)
    except (MissingCredentialError, ValueError) as exc:
        record["skipped"] = True
        record["skip_reason"] = str(exc)
        print(f"[bake-off] skipping config {config_name}: {exc}")
        return record

    for fixture in fixtures:
        fixture_id = fixture["fixture_id"]
        fixture_out = config_out / fixture_id
        fixture_out.mkdir(parents=True, exist_ok=True)
        print(f"[bake-off] {config_name} x {fixture_id}")
        try:
            generation = run_extract(
                client_cache,
                settings,
                runtime,
                prompt_text,
                fixture["source_path"],
            )
        except Exception as exc:
            generation = {
                "run_log": _empty_run_log(
                    settings.get("provider", "?"),
                    settings.get("model", "?"),
                    str(exc),
                ),
                "output_text": "",
            }
            print(f"[bake-off] ERROR {config_name} x {fixture_id}: {exc}")

        run_log = generation["run_log"]
        run_log["config_name"] = config_name
        run_log["fixture_id"] = fixture_id
        output_text = generation["output_text"]
        (fixture_out / "source_packet.txt").write_text(
            output_text + ("\n" if output_text else ""),
            encoding="utf-8",
        )
        save_json_file(fixture_out / "run.json", run_log)
        record["fixture_runs"].append(
            {
                "fixture_id": fixture_id,
                "status": run_log.get("status"),
                "model_latency_ms": (run_log.get("timings") or {}).get("model_latency_ms"),
                "ttft_ms": (run_log.get("timings") or {}).get("ttft_ms"),
                "request_build_ms": (run_log.get("timings") or {}).get("request_build_ms"),
                "output_chars": (run_log.get("response") or {}).get("output_text_length"),
                "errors": run_log.get("errors") or [],
            }
        )
    return record


def score_config(config_dir: Path, gold_path: Path) -> dict[str, Any] | None:
    """Run compare_source_packets logic in-process for one config dir."""
    if not any(p.is_dir() for p in config_dir.iterdir() if p.name not in {"gold_packet_compare.json", "gold_packet_compare.md"}):
        return None
    gold_packets = csp.load_json(gold_path)
    results: dict[str, dict[str, Any]] = {}
    for fixture_id in sorted(gold_packets.keys()):
        pred_text_path = config_dir / fixture_id / "source_packet.txt"
        pred_json_path = config_dir / fixture_id / "source_packet.json"
        if pred_json_path.exists():
            pred_packet = csp.load_json(pred_json_path)
            packet_format = "json"
        elif pred_text_path.exists():
            pred_packet = pred_text_path.read_text(encoding="utf-8")
            packet_format = "text"
        else:
            print(f"[bake-off] missing predicted packet for {config_dir.name}/{fixture_id}; skipping fixture")
            continue
        results[fixture_id] = csp.compare_fixture(gold_packets[fixture_id], pred_packet, packet_format)

    if not results:
        return None
    summary = csp.build_summary(results)
    payload = {
        "gold_path": str(gold_path),
        "pred_dir": str(config_dir),
        "summary": summary,
        "results": results,
    }
    csp.write_json(config_dir / "gold_packet_compare.json", payload)
    csp.write_markdown(config_dir / "gold_packet_compare.md", summary, results)
    return summary


def latency_stats(records: list[dict[str, Any]]) -> dict[str, Any]:
    ok_latencies = [
        r["model_latency_ms"]
        for r in records
        if r.get("status") == "ok" and r.get("model_latency_ms") is not None
    ]
    ok_ttft = [
        r["ttft_ms"]
        for r in records
        if r.get("status") == "ok" and r.get("ttft_ms") is not None
    ]
    error_count = sum(1 for r in records if r.get("status") != "ok")

    def _mean(values: list[float]) -> float | None:
        return round(statistics.mean(values), 2) if values else None

    def _p90(values: list[float]) -> float | None:
        if not values:
            return None
        s = sorted(values)
        idx = max(0, min(len(s) - 1, int(round(0.9 * (len(s) - 1)))))
        return round(s[idx], 2)

    return {
        "ok_count": len(ok_latencies),
        "error_count": error_count,
        "model_latency_mean_ms": _mean(ok_latencies),
        "model_latency_p90_ms": _p90(ok_latencies),
        "ttft_mean_ms": _mean(ok_ttft),
    }


def write_summary(
    out_dir: Path,
    *,
    extract_prompt_path: Path,
    fixture_ids: list[str],
    config_records: list[dict[str, Any]],
    config_summaries: dict[str, dict[str, Any] | None],
    max_output_tokens: int,
) -> None:
    rows: list[dict[str, Any]] = []
    for record in config_records:
        latency = latency_stats(record["fixture_runs"])
        score = config_summaries.get(record["name"])
        rows.append(
            {
                "name": record["name"],
                "provider": record["provider"],
                "model": record["model"],
                "api_style": record["api_style"],
                "skipped": record["skipped"],
                "skip_reason": record["skip_reason"],
                "salient_recall": score.get("salient_text_recall") if score else None,
                "salient_matches": (
                    f"{score['salient_text_matches']}/{score['salient_text_total']}" if score else "n/a"
                ),
                "source_kind_accuracy": score.get("source_kind_accuracy") if score else None,
                "source_kind_matches": (
                    f"{score['source_kind_matches']}/{score['fixture_count']}" if score else "n/a"
                ),
                "loose_recall": score.get("candidate_field_loose_recall") if score else None,
                "loose_matches": (
                    f"{(score['candidate_field_strict_matches'] or 0) + score['candidate_field_loose_only_matches']}/{score['candidate_field_total']}"
                    if score
                    else "n/a"
                ),
                "can_answer_accuracy": score.get("can_answer_accuracy") if score else None,
                "can_answer_matches": (
                    f"{score['can_answer_matches']}/{score['fixture_count']}" if score else "n/a"
                ),
                "model_latency_mean_ms": latency["model_latency_mean_ms"],
                "model_latency_p90_ms": latency["model_latency_p90_ms"],
                "ttft_mean_ms": latency["ttft_mean_ms"],
                "ok_count": latency["ok_count"],
                "error_count": latency["error_count"],
            }
        )

    def _fmt_pct(value: Any) -> str:
        return f"{value:.3f}" if isinstance(value, (int, float)) else "n/a"

    def _fmt_ms(value: Any) -> str:
        return f"{value:.0f}" if isinstance(value, (int, float)) else "n/a"

    lines = [
        "# Cross-Model Source-Packet Extraction Bake-Off",
        "",
        f"- Generated: `{now_iso()}`",
        f"- Extract prompt: `{os.path.relpath(extract_prompt_path, ROOT_DIR)}`",
        f"- Max output tokens (override applied to all configs): `{max_output_tokens}`",
        f"- Fixtures (`{len(fixture_ids)}`): " + ", ".join(f"`{f}`" for f in fixture_ids),
        f"- Configs scored: `{sum(1 for r in rows if not r['skipped'])}` / `{len(rows)}`",
        "",
        "## Per-config metrics",
        "",
        "| Config | Provider | Model | Salient | Kind | Loose fields | Can-answer | Mean latency (ms) | P90 latency (ms) | Errors |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        if row["skipped"]:
            lines.append(
                f"| `{row['name']}` | `{row['provider']}` | `{row['model']}` | "
                f"_skipped: {row['skip_reason']}_ | | | | | | |"
            )
            continue
        lines.append(
            f"| `{row['name']}` | `{row['provider']}` | `{row['model']}` | "
            f"`{row['salient_matches']}` (`{_fmt_pct(row['salient_recall'])}`) | "
            f"`{row['source_kind_matches']}` (`{_fmt_pct(row['source_kind_accuracy'])}`) | "
            f"`{row['loose_matches']}` (`{_fmt_pct(row['loose_recall'])}`) | "
            f"`{row['can_answer_matches']}` (`{_fmt_pct(row['can_answer_accuracy'])}`) | "
            f"`{_fmt_ms(row['model_latency_mean_ms'])}` | "
            f"`{_fmt_ms(row['model_latency_p90_ms'])}` | "
            f"`{row['error_count']}/{row['ok_count'] + row['error_count']}` |"
        )

    scored_rows = [r for r in rows if not r["skipped"] and r["salient_recall"] is not None]
    if scored_rows:
        def _best(metric: str, *, higher_is_better: bool = True) -> dict[str, Any] | None:
            valid = [r for r in scored_rows if r.get(metric) is not None]
            if not valid:
                return None
            return max(valid, key=lambda r: r[metric]) if higher_is_better else min(
                valid, key=lambda r: r[metric]
            )

        best_salient = _best("salient_recall")
        best_kind = _best("source_kind_accuracy")
        best_loose = _best("loose_recall")
        best_can_answer = _best("can_answer_accuracy")
        fastest = _best("model_latency_mean_ms", higher_is_better=False)

        lines.extend(
            [
                "",
                "## Best per metric",
                "",
                f"- Salient recall: `{best_salient['name']}` — `{best_salient['salient_matches']}` (`{_fmt_pct(best_salient['salient_recall'])}`)" if best_salient else "- Salient recall: n/a",
                f"- Source-kind accuracy: `{best_kind['name']}` — `{best_kind['source_kind_matches']}` (`{_fmt_pct(best_kind['source_kind_accuracy'])}`)" if best_kind else "- Source-kind accuracy: n/a",
                f"- Candidate-field loose recall: `{best_loose['name']}` — `{best_loose['loose_matches']}` (`{_fmt_pct(best_loose['loose_recall'])}`)" if best_loose else "- Candidate-field loose recall: n/a",
                f"- Can-answer accuracy: `{best_can_answer['name']}` — `{best_can_answer['can_answer_matches']}` (`{_fmt_pct(best_can_answer['can_answer_accuracy'])}`)" if best_can_answer else "- Can-answer accuracy: n/a",
                f"- Fastest mean extraction latency: `{fastest['name']}` — `{_fmt_ms(fastest['model_latency_mean_ms'])} ms`" if fastest else "- Fastest mean extraction latency: n/a",
            ]
        )

    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    save_json_file(
        out_dir / "summary.json",
        {
            "generated_at": now_iso(),
            "extract_prompt_path": str(extract_prompt_path),
            "max_output_tokens": max_output_tokens,
            "fixtures": fixture_ids,
            "configs": rows,
        },
    )


def main() -> int:
    args = parse_args()
    load_workspace_env()

    extract_prompt_path = resolve_from_root(args.extract_prompt_path)
    if not extract_prompt_path.exists():
        print(f"Extract prompt not found: {extract_prompt_path}", file=sys.stderr)
        return 1
    prompt_text = extract_prompt_path.read_text(encoding="utf-8").strip()

    gold_path = resolve_from_root(args.gold)
    if not gold_path.exists():
        print(f"Gold corpus not found: {gold_path}", file=sys.stderr)
        return 1

    fixture_paths = [p for p in expand_glob(args.fixtures) if p.is_dir()]
    if args.limit_fixtures is not None:
        fixture_paths = fixture_paths[: args.limit_fixtures]
    if not fixture_paths:
        print(f"No fixtures matched: {args.fixtures}", file=sys.stderr)
        return 1
    fixtures = [fixture_record(p) for p in fixture_paths]

    config_paths = [p for p in expand_glob(args.configs) if p.is_file()]
    if not config_paths:
        print(f"No configs matched: {args.configs}", file=sys.stderr)
        return 1

    out_dir = resolve_from_root(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"[bake-off] {len(config_paths)} configs x {len(fixtures)} fixtures "
        f"-> {out_dir}"
    )

    client_cache: dict[tuple[Any, ...], Any] = {}
    config_records: list[dict[str, Any]] = []
    for config_path in config_paths:
        record = run_one_config(
            config_path,
            fixtures,
            prompt_text,
            out_dir,
            client_cache,
            max_output_tokens=args.max_output_tokens,
        )
        config_records.append(record)

    config_summaries: dict[str, dict[str, Any] | None] = {}
    for record in config_records:
        if record["skipped"]:
            config_summaries[record["name"]] = None
            continue
        summary = score_config(out_dir / record["name"], gold_path)
        config_summaries[record["name"]] = summary

    write_summary(
        out_dir,
        extract_prompt_path=extract_prompt_path,
        fixture_ids=[f["fixture_id"] for f in fixtures],
        config_records=config_records,
        config_summaries=config_summaries,
        max_output_tokens=args.max_output_tokens,
    )

    print(f"[bake-off] wrote {out_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
