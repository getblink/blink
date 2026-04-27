#!/usr/bin/env python3
"""Text-only target inference: drop the target image from the LLM call,
inject TARGET_OCR_TEXT instead, reuse the v3-refined source packet from
the existing sweep so we're isolating the target-side image vs no-image
delta only.

For each of the 9 gold-labeled fixtures, this calls Gemini Flash Lite
N times and records:
  - latency (request_path_ms = build + model)
  - output text
  - exact-match against the live two-image baseline output
  - exact-match against the with-image target_only output
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRATCHPAD = ROOT / "scratchpad"
sys.path.insert(0, str(SCRATCHPAD))

from google import genai  # noqa: E402
from google.genai import types  # noqa: E402

from env_loader import load_workspace_env  # noqa: E402
from benchmark_source_packet import (  # noqa: E402
    build_client,
    duration_ms,
    load_settings,
    now_iso,
    run_stream_request,
    total_request_path_ms,
)


CONFIG_PATH = SCRATCHPAD / "eval_configs" / "flash-lite-low-minimal.json"
SOURCE_PACKET_SWEEP = (
    SCRATCHPAD / "sweeps" / "source-packet-v3-ocr-refined-20260424-164555"
)
GOLD_PATH = SCRATCHPAD / "gold_source_packets.json"
FIXTURES_DIR = SCRATCHPAD / "fixtures"
TARGET_PROMPT_PATH = (
    Path(__file__).resolve().parent / "text_only_target_prompt.txt"
)
RUNS = 3


def build_target_text_only(
    *,
    client: genai.Client,
    settings: dict,
    prompt_text: str,
    packet_text: str,
    target_metadata: dict,
    target_ocr_text: str,
) -> dict:
    prepare_started_perf = time.perf_counter()
    metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
    instruction_text = (
        f"SOURCE_PACKET_TEXT:\n{packet_text}\n\n"
        f"TARGET_METADATA_JSON:\n{metadata_json}\n\n"
        f"TARGET_OCR_TEXT:\n{target_ocr_text}\n"
    )
    parts = [
        types.Content(
            role="user",
            parts=[types.Part.from_text(text=instruction_text)],
        )
    ]
    request_build_ms = duration_ms(prepare_started_perf)
    generation = run_stream_request(
        client=client,
        settings=settings,
        prompt_text=prompt_text,
        contents=parts,
        response_mime_type="text/plain",
        request_payload={
            "mode": "source_packet_target_text_only",
            "instruction_chars": len(instruction_text),
            "source_packet_chars": len(packet_text),
            "target_ocr_chars": len(target_ocr_text),
            "target_metadata_chars": len(metadata_json),
        },
    )
    generation["run_log"]["timings"]["request_build_ms"] = request_build_ms
    return generation


def main() -> int:
    load_workspace_env()
    out_dir = Path(__file__).resolve().parent / "text_only_target_runs"
    if out_dir.exists():
        import shutil

        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    settings = load_settings(CONFIG_PATH)
    client, _runtime = build_client(settings)

    target_prompt = TARGET_PROMPT_PATH.read_text(encoding="utf-8").strip()
    gold = json.loads(GOLD_PATH.read_text(encoding="utf-8"))
    fixture_ids = sorted(gold.keys())

    all_results: list[dict] = []

    for fixture_id in fixture_ids:
        fixture_dir = FIXTURES_DIR / fixture_id
        if not (fixture_dir / "fixture.json").exists():
            print(f"[skip] {fixture_id}: missing fixture.json", file=sys.stderr)
            continue
        manifest = json.loads(
            (fixture_dir / "fixture.json").read_text(encoding="utf-8")
        )
        target_metadata = manifest.get("target_metadata") or {}
        ocr_payload = json.loads(
            (fixture_dir / "ocr.json").read_text(encoding="utf-8")
        )
        target_ocr_text = ocr_payload.get("full_text") or ""

        packet_path = SOURCE_PACKET_SWEEP / fixture_id / "source_packet.txt"
        if not packet_path.exists():
            print(f"[skip] {fixture_id}: no precomputed packet", file=sys.stderr)
            continue
        packet_text = packet_path.read_text(encoding="utf-8")

        baseline_output_path = (
            SOURCE_PACKET_SWEEP / fixture_id / "baseline.output.txt"
        )
        with_image_output_path = (
            SOURCE_PACKET_SWEEP / fixture_id / "source_packet.target_only.output.txt"
        )
        baseline_output = (
            baseline_output_path.read_text(encoding="utf-8").strip()
            if baseline_output_path.exists()
            else ""
        )
        with_image_output = (
            with_image_output_path.read_text(encoding="utf-8").strip()
            if with_image_output_path.exists()
            else ""
        )

        fixture_runs = []
        for run_index in range(1, RUNS + 1):
            print(f"[text-only-target] {fixture_id} run {run_index}/{RUNS}")
            generation = build_target_text_only(
                client=client,
                settings=settings,
                prompt_text=target_prompt,
                packet_text=packet_text,
                target_metadata=target_metadata,
                target_ocr_text=target_ocr_text,
            )
            run_log = generation["run_log"]
            output_text = generation["output_text"]
            request_path_ms = total_request_path_ms(run_log)
            fixture_out = out_dir / fixture_id / f"run_{run_index}"
            fixture_out.mkdir(parents=True, exist_ok=True)
            (fixture_out / "output.txt").write_text(
                output_text + ("\n" if output_text else ""), encoding="utf-8"
            )
            (fixture_out / "run.json").write_text(
                json.dumps(run_log, indent=2, default=str) + "\n",
                encoding="utf-8",
            )
            fixture_runs.append(
                {
                    "run": run_index,
                    "status": run_log.get("status"),
                    "request_path_ms": request_path_ms,
                    "ttft_ms": run_log.get("timings", {}).get("ttft_ms"),
                    "output_text": output_text,
                    "exact_match_baseline": output_text.strip()
                    == baseline_output.strip(),
                    "exact_match_with_image": output_text.strip()
                    == with_image_output.strip(),
                }
            )

        all_results.append(
            {
                "fixture_id": fixture_id,
                "baseline_output": baseline_output,
                "with_image_output": with_image_output,
                "runs": fixture_runs,
            }
        )

    # Aggregate
    flat_request_ms = [
        r["request_path_ms"]
        for fixture in all_results
        for r in fixture["runs"]
        if r["request_path_ms"] is not None
    ]
    flat_ttft = [
        r["ttft_ms"]
        for fixture in all_results
        for r in fixture["runs"]
        if r["ttft_ms"] is not None
    ]
    summary = {
        "fixture_count": len(all_results),
        "runs_per_fixture": RUNS,
        "request_path_ms_avg": round(statistics.mean(flat_request_ms), 2)
        if flat_request_ms
        else None,
        "request_path_ms_median": round(statistics.median(flat_request_ms), 2)
        if flat_request_ms
        else None,
        "request_path_ms_min": min(flat_request_ms) if flat_request_ms else None,
        "request_path_ms_max": max(flat_request_ms) if flat_request_ms else None,
        "ttft_ms_avg": round(statistics.mean(flat_ttft), 2) if flat_ttft else None,
        "exact_match_baseline_rate": round(
            sum(
                1
                for fixture in all_results
                for r in fixture["runs"]
                if r["exact_match_baseline"]
            )
            / max(len(flat_request_ms), 1),
            3,
        ),
        "exact_match_with_image_rate": round(
            sum(
                1
                for fixture in all_results
                for r in fixture["runs"]
                if r["exact_match_with_image"]
            )
            / max(len(flat_request_ms), 1),
            3,
        ),
    }
    payload = {
        "generated_at": now_iso(),
        "config_path": str(CONFIG_PATH),
        "source_packet_sweep": str(SOURCE_PACKET_SWEEP),
        "target_prompt_path": str(TARGET_PROMPT_PATH),
        "summary": summary,
        "results": all_results,
    }
    (out_dir / "benchmark.json").write_text(
        json.dumps(payload, indent=2, default=str) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
