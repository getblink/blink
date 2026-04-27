#!/usr/bin/env python3

from __future__ import annotations

import argparse
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

from env_loader import load_workspace_env
from gemini_runner import (
    build_generation_config,
    duration_ms,
    generate_completion as baseline_generate_completion,
    now_iso,
    plain_data,
    prepare_request_image,
)
from providers import MissingCredentialError, resolve_runtime_settings


BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent
SETTINGS_PATH = BASE_DIR / "settings.json"
BASELINE_PROMPT_PATH = BASE_DIR / "prompt.txt"
DEFAULT_SOURCE_PACKET_EXTRACT_PROMPT_PATH = BASE_DIR / "source_packet_extract_prompt.txt"
DEFAULT_SOURCE_PACKET_TARGET_PROMPT_PATH = BASE_DIR / "source_packet_target_prompt.txt"
DEFAULT_CONFIG_PATH = BASE_DIR / "eval_configs" / "flash-lite-low-minimal.json"

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
        description="Benchmark current two-image prompting vs cached source-packet prompting.",
    )
    parser.add_argument(
        "--fixtures",
        required=True,
        help="Glob for fixture directories, e.g. 'scratchpad/fixtures/*'.",
    )
    parser.add_argument(
        "--config",
        default=str(DEFAULT_CONFIG_PATH),
        help="Config JSON to use for both baseline and packet runs.",
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
        "--extract-prompt-path",
        default=str(DEFAULT_SOURCE_PACKET_EXTRACT_PROMPT_PATH),
        help="Path to the source-packet extraction prompt.",
    )
    parser.add_argument(
        "--target-prompt-path",
        default=str(DEFAULT_SOURCE_PACKET_TARGET_PROMPT_PATH),
        help="Path to the source-packet target-only prompt.",
    )
    parser.add_argument(
        "--packet-format",
        choices=["json", "text"],
        default="json",
        help="Whether the extractor should emit a JSON packet or a plain-text packet.",
    )
    parser.add_argument(
        "--max-output-tokens",
        type=int,
        default=None,
        help="Optional override for settings.max_output_tokens during the benchmark.",
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


def load_settings(config_path: Path) -> dict[str, Any]:
    settings = dict(DEFAULT_SETTINGS)
    if SETTINGS_PATH.exists():
        settings.update(load_json_file(SETTINGS_PATH))
    raw_config = load_json_file(config_path)
    for key, value in raw_config.items():
        if key not in {"name", "prompt_path"}:
            settings[key] = value
    settings["stream_to_terminal"] = False
    settings["copy_to_clipboard"] = False
    return settings


def fixture_record(fixture_dir: Path) -> dict[str, Any]:
    manifest = load_json_file(fixture_dir / "fixture.json")
    return {
        "fixture_id": manifest["fixture_id"],
        "fixture_dir": fixture_dir,
        "manifest": manifest,
        "source_path": fixture_dir / manifest["source"]["image_path"],
        "target_path": fixture_dir / manifest["target"]["image_path"],
        "target_metadata": manifest["target_metadata"],
    }


def build_client(settings: dict[str, Any]) -> tuple[genai.Client, dict[str, Any]]:
    runtime = resolve_runtime_settings(settings)
    if runtime["provider"] != "gemini":
        raise ValueError(
            "source-packet benchmark currently supports Gemini configs only; "
            f"got provider={runtime['provider']!r}",
        )
    timeout_ms = int(float(settings.get("timeout_seconds", 120)) * 1000)
    client = genai.Client(
        api_key=runtime["api_key"],
        http_options=types.HttpOptions(timeout=timeout_ms),
    )
    return client, runtime


def packet_generation_config(settings: dict[str, Any], prompt_text: str, response_mime_type: str) -> Any:
    config = build_generation_config(settings, prompt_text)
    config_kwargs = plain_data(config)
    config_kwargs["response_mime_type"] = response_mime_type
    return types.GenerateContentConfig(**config_kwargs)


def run_stream_request(
    *,
    client: genai.Client,
    settings: dict[str, Any],
    prompt_text: str,
    contents: list[Any],
    response_mime_type: str,
    request_payload: dict[str, Any],
) -> dict[str, Any]:
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

    config = packet_generation_config(settings, prompt_text, response_mime_type)
    request_send_perf = time.perf_counter()
    request_send_at = now_iso()

    try:
        stream = client.models.generate_content_stream(
            model=settings["model"],
            contents=contents,
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
    stream_duration_ms = None
    if first_chunk_perf is not None and final_chunk_perf is not None:
        stream_duration_ms = duration_ms(first_chunk_perf, final_chunk_perf)

    run_log = {
        "status": status,
        "request": {
            "model": settings["model"],
            "request_send_at": request_send_at,
            "prompt_chars": len(prompt_text),
            **request_payload,
        },
        "response": {
            "usage_metadata": usage_metadata,
            "chunk_count": chunk_count,
            "response_metadata": final_chunk_payload,
            "output_text": output_text,
            "output_text_length": len(output_text),
        },
        "timings": {
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


def build_source_packet(
    client: genai.Client,
    settings: dict[str, Any],
    source_path: Path,
    prompt_text: str,
    packet_format: str,
) -> dict[str, Any]:
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
    generation = run_stream_request(
        client=client,
        settings=settings,
        prompt_text=prompt_text,
        contents=parts,
        response_mime_type="application/json" if packet_format == "json" else "text/plain",
        request_payload={
            "mode": "source_packet_extract",
            "source_packet_format": packet_format,
            "instruction_chars": len(prompt_text),
            "source_image_bytes": source_request_image["request_bytes"],
            "source_original_image_bytes": source_request_image["original_bytes"],
            "images": {"source": source_request_image["log"]},
        },
    )
    generation["run_log"]["timings"]["request_build_ms"] = request_build_ms
    generation["run_log"]["timings"]["source_image_prepare_ms"] = source_request_image["duration_ms"]
    packet_payload = None
    packet_error = None
    if generation["run_log"]["status"] == "ok":
        if packet_format == "json":
            try:
                packet_payload = json.loads(generation["output_text"])
                if not isinstance(packet_payload, dict):
                    raise ValueError("source packet response must be a JSON object")
            except Exception as exc:
                packet_error = str(exc)
                generation["run_log"]["status"] = "error"
                generation["run_log"].setdefault("errors", []).append(packet_error)
        else:
            packet_payload = generation["output_text"]
    return {
        "generation": generation,
        "packet": packet_payload,
        "packet_error": packet_error,
    }


def run_source_packet_target(
    client: genai.Client,
    settings: dict[str, Any],
    prompt_text: str,
    packet: Any,
    packet_format: str,
    target_path: Path,
    target_metadata: dict[str, Any],
) -> dict[str, Any]:
    prepare_started_perf = time.perf_counter()
    target_request_image = prepare_request_image(target_path, settings)
    if packet_format == "json":
        packet_text = json.dumps(packet, indent=2, ensure_ascii=True)
        packet_header = "SOURCE_PACKET_JSON"
    else:
        packet_text = str(packet).strip()
        packet_header = "SOURCE_PACKET_TEXT"
    metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
    instruction_text = (
        f"{packet_header}:\n"
        f"{packet_text}\n\n"
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n"
    )
    parts = [
        types.Content(
            role="user",
            parts=[
                types.Part.from_text(text=instruction_text),
                types.Part.from_text(text="TARGET_IMAGE"),
                types.Part.from_bytes(
                    data=target_request_image["bytes_data"],
                    mime_type=target_request_image["mime_type"],
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
            "mode": "source_packet_target_only",
            "source_packet_format": packet_format,
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(packet_text),
            "target_image_bytes": target_request_image["request_bytes"],
            "target_original_image_bytes": target_request_image["original_bytes"],
            "images": {"target": target_request_image["log"]},
        },
    )
    generation["run_log"]["timings"]["request_build_ms"] = request_build_ms
    generation["run_log"]["timings"]["target_image_prepare_ms"] = target_request_image["duration_ms"]
    return generation


def total_request_path_ms(run_log: dict[str, Any]) -> float | None:
    timings = run_log.get("timings") or {}
    request_build_ms = timings.get("request_build_ms")
    model_latency_ms = timings.get("model_latency_ms")
    try:
        if request_build_ms is None or model_latency_ms is None:
            return None
        return round(float(request_build_ms) + float(model_latency_ms), 2)
    except (TypeError, ValueError):
        return None


def format_ms(value: Any) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value):.2f}"
    except (TypeError, ValueError):
        return str(value)


def exact_match(a: str, b: str) -> bool:
    return a.strip() == b.strip()


def packet_text_self_reports_insufficient(packet_text: str) -> bool:
    return "COMPLETENESS: needs_source_image" in packet_text


def packet_char_count(packet: Any, packet_format: str) -> int | None:
    if packet is None:
        return None
    if packet_format == "json":
        return len(json.dumps(packet, ensure_ascii=True))
    return len(str(packet))


def candidate_fallback_reasons(packet: Any, packet_output: str, packet_status: str, packet_format: str) -> list[str]:
    reasons: list[str] = []
    if packet is None:
        reasons.append("source_packet_missing")
    elif packet_format == "json":
        if packet.get("can_answer_without_source_image") is False:
            reasons.append("source_packet_self_reports_insufficient")
    elif packet_format == "text":
        if packet_text_self_reports_insufficient(str(packet)):
            reasons.append("source_packet_self_reports_insufficient")
    if packet_status != "ok":
        reasons.append("packet_generation_error")
    if packet_output.startswith("[[NEEDS_REVIEW:"):
        reasons.append("target_only_needs_review")
    return reasons


def summarize(results: list[dict[str, Any]], reuse_counts: list[int]) -> dict[str, Any]:
    baseline_request_ms = [
        item["baseline"]["request_path_ms"]
        for item in results
        if item["baseline"]["request_path_ms"] is not None
    ]
    packet_extract_ms = [
        item["source_packet"]["extract"]["request_path_ms"]
        for item in results
        if item["source_packet"]["extract"]["request_path_ms"] is not None
    ]
    packet_target_ms = [
        item["source_packet"]["target_only"]["request_path_ms"]
        for item in results
        if item["source_packet"]["target_only"]["request_path_ms"] is not None
    ]
    summary: dict[str, Any] = {
        "fixture_count": len(results),
        "baseline_request_path_ms_avg": round(statistics.mean(baseline_request_ms), 2)
        if baseline_request_ms
        else None,
        "packet_extract_request_path_ms_avg": round(statistics.mean(packet_extract_ms), 2)
        if packet_extract_ms
        else None,
        "packet_target_request_path_ms_avg": round(statistics.mean(packet_target_ms), 2)
        if packet_target_ms
        else None,
        "packet_exact_match_count": sum(1 for item in results if item["source_packet"]["exact_match_baseline"]),
        "packet_fallback_candidate_count": sum(
            1 for item in results if item["source_packet"]["fallback_reasons"]
        ),
        "reuse_estimates": {},
    }
    for reuse in reuse_counts:
        amortized_values: list[float] = []
        deltas: list[float] = []
        for item in results:
            base = item["baseline"]["request_path_ms"]
            extract = item["source_packet"]["extract"]["request_path_ms"]
            target = item["source_packet"]["target_only"]["request_path_ms"]
            if base is None or extract is None or target is None:
                continue
            amortized = round((extract / reuse) + target, 2)
            amortized_values.append(amortized)
            deltas.append(round(base - amortized, 2))
        summary["reuse_estimates"][str(reuse)] = {
            "amortized_packet_request_path_ms_avg": round(statistics.mean(amortized_values), 2)
            if amortized_values
            else None,
            "vs_baseline_request_path_ms_delta_avg": round(statistics.mean(deltas), 2)
            if deltas
            else None,
        }
    return summary


def write_summary(
    out_dir: Path,
    *,
    config_path: Path,
    extract_prompt_path: Path,
    target_prompt_path: Path,
    packet_format: str,
    results: list[dict[str, Any]],
    summary: dict[str, Any],
    reuse_counts: list[int],
) -> None:
    lines = [
        "# Source Packet Benchmark",
        "",
        f"- Generated at: `{now_iso()}`",
        f"- Config: `{os.path.relpath(config_path, ROOT_DIR)}`",
        f"- Extract prompt: `{os.path.relpath(extract_prompt_path, ROOT_DIR)}`",
        f"- Target prompt: `{os.path.relpath(target_prompt_path, ROOT_DIR)}`",
        f"- Packet format: `{packet_format}`",
        f"- Fixture count: `{summary['fixture_count']}`",
        f"- Baseline avg request path: `{format_ms(summary['baseline_request_path_ms_avg'])} ms`",
        f"- Source-packet extract avg: `{format_ms(summary['packet_extract_request_path_ms_avg'])} ms`",
        f"- Source-packet target-only avg: `{format_ms(summary['packet_target_request_path_ms_avg'])} ms`",
        f"- Exact-match vs baseline: `{summary['packet_exact_match_count']}/{summary['fixture_count']}`",
        f"- Candidate fallback count: `{summary['packet_fallback_candidate_count']}`",
        "",
        "## Reuse Estimates",
        "",
        "| Reuse count | Amortized source-packet request path (ms) | Avg delta vs baseline (ms) |",
        "| --- | ---: | ---: |",
    ]
    for reuse in reuse_counts:
        estimate = summary["reuse_estimates"][str(reuse)]
        lines.append(
            f"| `{reuse}` | `{format_ms(estimate['amortized_packet_request_path_ms_avg'])}` | "
            f"`{format_ms(estimate['vs_baseline_request_path_ms_delta_avg'])}` |"
        )
    lines.extend(
        [
            "",
            "## Per Fixture",
            "",
            "| Fixture | Baseline req path (ms) | Packet extract (ms) | Packet target-only (ms) | Exact match | Fallback candidate |",
            "| --- | ---: | ---: | ---: | --- | --- |",
        ]
    )
    for item in results:
        fallback_label = (
            ", ".join(item["source_packet"]["fallback_reasons"])
            if item["source_packet"]["fallback_reasons"]
            else "no"
        )
        lines.append(
            f"| `{item['fixture_id']}` | `{format_ms(item['baseline']['request_path_ms'])}` | "
            f"`{format_ms(item['source_packet']['extract']['request_path_ms'])}` | "
            f"`{format_ms(item['source_packet']['target_only']['request_path_ms'])}` | "
            f"`{'yes' if item['source_packet']['exact_match_baseline'] else 'no'}` | "
            f"`{fallback_label}` |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    load_workspace_env()
    config_path = resolve_from_root(args.config)
    out_dir = resolve_from_root(args.out)
    extract_prompt_path = resolve_from_root(args.extract_prompt_path)
    target_prompt_path = resolve_from_root(args.target_prompt_path)
    out_dir.mkdir(parents=True, exist_ok=False)
    reuse_counts = [int(item.strip()) for item in args.reuse_counts.split(",") if item.strip()]
    packet_format = args.packet_format

    settings = load_settings(config_path)
    if args.max_output_tokens is not None:
        settings["max_output_tokens"] = args.max_output_tokens
    client, runtime = build_client(settings)
    baseline_prompt = BASELINE_PROMPT_PATH.read_text(encoding="utf-8").strip()
    extract_prompt = extract_prompt_path.read_text(encoding="utf-8").strip()
    target_prompt = target_prompt_path.read_text(encoding="utf-8").strip()

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
            "extract_prompt_path": str(extract_prompt_path),
            "target_prompt_path": str(target_prompt_path),
        },
        "packet_format": packet_format,
        "reuse_counts": reuse_counts,
        "fixtures": [fixture["fixture_id"] for fixture in fixtures],
        "results": [],
    }

    for fixture in fixtures:
        print(f"[source-packet] {fixture['fixture_id']}")
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

        packet_result = build_source_packet(
            client,
            settings,
            fixture["source_path"],
            extract_prompt,
            packet_format,
        )
        packet_generation = packet_result["generation"]
        packet_run_log = packet_generation["run_log"]
        packet_request_path_ms = total_request_path_ms(packet_run_log)
        save_json_file(fixture_out / "source_packet.extract.run.json", packet_run_log)
        (fixture_out / "source_packet.extract.output.json").write_text(
            packet_generation["output_text"] + ("\n" if packet_generation["output_text"] else ""),
            encoding="utf-8",
        )

        packet_payload = packet_result["packet"]
        if packet_payload is not None:
            if packet_format == "json":
                save_json_file(fixture_out / "source_packet.json", packet_payload)
                packet_rel_path = os.path.relpath(fixture_out / "source_packet.json", out_dir)
            else:
                (fixture_out / "source_packet.txt").write_text(
                    str(packet_payload) + ("\n" if str(packet_payload) else ""),
                    encoding="utf-8",
                )
                packet_rel_path = os.path.relpath(fixture_out / "source_packet.txt", out_dir)
            target_generation = run_source_packet_target(
                client,
                settings,
                target_prompt,
                packet_payload,
                packet_format,
                fixture["target_path"],
                fixture["target_metadata"],
            )
        else:
            packet_rel_path = None
            target_generation = {
                "run_log": {
                    "status": "error",
                    "errors": ["source packet unavailable"],
                    "request": {},
                    "response": {},
                    "timings": {},
                },
                "output_text": "",
            }
        target_run_log = target_generation["run_log"]
        target_output = target_generation["output_text"]
        target_request_path_ms = total_request_path_ms(target_run_log)
        save_json_file(fixture_out / "source_packet.target_only.run.json", target_run_log)
        (fixture_out / "source_packet.target_only.output.txt").write_text(
            target_output + ("\n" if target_output else ""),
            encoding="utf-8",
        )

        fallback_reasons = candidate_fallback_reasons(
            packet_payload,
            target_output,
            target_run_log.get("status", "error"),
            packet_format,
        )
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
                    "status": packet_run_log.get("status"),
                    "request_path_ms": packet_request_path_ms,
                    "run_log_path": os.path.relpath(
                        fixture_out / "source_packet.extract.run.json",
                        out_dir,
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "source_packet.extract.output.json",
                        out_dir,
                    ),
                },
                "target_only": {
                    "status": target_run_log.get("status"),
                    "request_path_ms": target_request_path_ms,
                    "run_log_path": os.path.relpath(
                        fixture_out / "source_packet.target_only.run.json",
                        out_dir,
                    ),
                    "output_path": os.path.relpath(
                        fixture_out / "source_packet.target_only.output.txt",
                        out_dir,
                    ),
                    "output_text": target_output,
                },
                "packet_path": (
                    packet_rel_path
                ),
                "packet_format": packet_format,
                "packet_chars": packet_char_count(packet_payload, packet_format),
                "exact_match_baseline": exact_match(baseline_output, target_output),
                "fallback_reasons": fallback_reasons,
            },
        }
        results.append(fixture_result)
        benchmark_manifest["results"].append(fixture_result)

    summary = summarize(results, reuse_counts)
    benchmark_manifest["summary"] = summary
    save_json_file(out_dir / "benchmark.json", benchmark_manifest)
    write_summary(
        out_dir,
        config_path=config_path,
        extract_prompt_path=extract_prompt_path,
        target_prompt_path=target_prompt_path,
        packet_format=packet_format,
        results=results,
        summary=summary,
        reuse_counts=reuse_counts,
    )

    print(f"[source-packet] wrote {out_dir}")
    print(
        "[source-packet] baseline avg request path:",
        format_ms(summary["baseline_request_path_ms_avg"]),
        "ms",
    )
    print(
        "[source-packet] target-only avg request path:",
        format_ms(summary["packet_target_request_path_ms_avg"]),
        "ms",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingCredentialError as exc:
        print(f"[source-packet] {exc}", file=sys.stderr)
        raise SystemExit(2)
