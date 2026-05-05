#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import html
import json
import os
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_PYTHON_DIR = REPO_ROOT / "app" / "python"
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.append(str(APP_PYTHON_DIR))

from scratchpad.env_loader import load_workspace_env  # noqa: E402
from scratchpad.gemini_runner import (  # noqa: E402
    duration_ms,
    plain_data,
    prepare_request_image,
)
from source_ocr import (  # noqa: E402
    SOURCE_OCR_PARAMETERS,
    build_native_ocr_source_packet,
)

from scratchpad.tldr_reply.gemini import (  # noqa: E402
    DEFAULT_SETTINGS,
    _normalize_payload,
    _parse_json_response,
    _schema,
)

PROMPT_PATH = Path(__file__).resolve().parent / "prompt.txt"
MODEL_CONTENT_TEXT = "Summarize this active window and propose three replies."
SERVER_CONTEXT_PREFIX = (
    "Structured capture context (JSON). Treat it as additional evidence; "
    "do not repeat it verbatim in the output. If stateful_context is "
    "present, use preference_examples to infer which suggestions the user "
    "finds useful, use voice_samples only as examples of the user's writing "
    "style, and use recent_surface_history only for continuity in this same "
    "immediate surface. Current screen evidence wins; never import unsupported "
    "facts from history."
)
SERVER_CONTENT_TEXT = (
    "Summarize this active window and propose three replies. Use any "
    "structured capture context if it is present."
)
LATENCY_ACCOUNTING_NOTE = (
    "Latency caveat: total_ms is measured as client-side parallel prep plus the "
    "Gemini SDK call. OCR is only hidden behind local image preparation "
    "(typically sips compression), not separately behind upload. The Gemini SDK "
    "does not expose upload time apart from the network/model call, so these "
    "runs cannot prove OCR is hidden behind upload."
)


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def _is_thinking_model(model: str) -> bool:
    if not model:
        return False
    name = model.lower()
    if not name.startswith(("gemini-3-", "gemini-3.")):
        return False
    return "flash-lite" not in name


def thinking_level_for_model(model: str) -> str | None:
    return "low" if _is_thinking_model(model) else None


def max_output_tokens_for_model(model: str) -> int | None:
    return 2048 if _is_thinking_model(model) else None


def build_generate_config(types_module: Any, prompt_text: str, settings: dict[str, Any]) -> Any:
    model = str(settings.get("model") or "")
    max_tokens = max_output_tokens_for_model(model) or settings["max_output_tokens"]
    kwargs: dict[str, Any] = {
        "system_instruction": prompt_text,
        "temperature": settings["temperature"],
        "max_output_tokens": max_tokens,
        "media_resolution": settings["media_resolution"],
        "response_mime_type": "application/json",
        "response_schema": _schema(),
    }
    level = thinking_level_for_model(model)
    if level is not None:
        kwargs["thinking_config"] = types_module.ThinkingConfig(thinking_level=level)
    return types_module.GenerateContentConfig(**kwargs)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run TLDR fixture x config sweeps.")
    parser.add_argument("--fixtures", required=True, help="Glob for TLDR fixture dirs.")
    parser.add_argument("--configs", required=True, help="Glob for tldr_*.json configs.")
    parser.add_argument("--out", required=True, help="Output directory for sweep bundle.")
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def resolve_path(path_str: str) -> Path:
    path = Path(path_str).expanduser()
    if path.is_absolute():
        return path
    return (REPO_ROOT / path).resolve()


def expand_glob(pattern: str) -> list[Path]:
    absolute = pattern if pattern.startswith("/") else str(REPO_ROOT / pattern)
    return sorted(Path(match) for match in glob.glob(absolute))


def relative_link(from_dir: Path, to_path: Path) -> str:
    return os.path.relpath(to_path, start=from_dir)


def fixture_record(fixture_dir: Path) -> dict[str, Any]:
    manifest_path = fixture_dir / "tldr_fixture.json"
    manifest = load_json(manifest_path)
    screenshot_name = str(manifest.get("screenshot") or "screenshot.png")
    expected_path = fixture_dir / "expected.json"
    expected = load_json(expected_path) if expected_path.exists() else None
    return {
        "slug": str(manifest.get("slug") or fixture_dir.name),
        "fixture_dir": fixture_dir,
        "manifest_path": manifest_path,
        "manifest": manifest,
        "screenshot_path": fixture_dir / screenshot_name,
        "expected_path": expected_path if expected_path.exists() else None,
        "expected": expected if isinstance(expected, dict) else None,
    }


def config_record(config_path: Path, base_settings: dict[str, Any]) -> dict[str, Any]:
    raw_config = load_json(config_path)
    settings = dict(base_settings)
    for key, value in raw_config.items():
        if key not in {"name", "prompt_path"}:
            settings[key] = value
    return {
        "name": str(raw_config.get("name") or config_path.stem),
        "config_path": config_path,
        "raw_config": raw_config,
        "settings": settings,
        "prompt_text": load_prompt(raw_config.get("prompt_path")),
    }


def load_prompt(prompt_path: str | None) -> str:
    path = resolve_path(prompt_path) if prompt_path else PROMPT_PATH
    return path.read_text(encoding="utf-8").strip()


def build_ocr_packet(settings: dict[str, Any], screenshot_path: Path) -> dict[str, Any] | None:
    if not settings.get("tldr_include_ocr_packet"):
        return None
    return build_native_ocr_source_packet(
        source_path=screenshot_path,
        apply_band_filter=not bool(settings.get("tldr_ocr_raw")),
        apply_chrome_filter=not bool(settings.get("tldr_ocr_raw")),
    )


def context_text_for_packet(ocr_packet: dict[str, Any] | None) -> str | None:
    if not ocr_packet:
        return None
    packet_text = str(ocr_packet.get("packet_text") or "").strip()
    if not packet_text:
        return None
    envelope = {
        "capture_mode": "frontmost_window_screenshot",
        "ocr_packet": {
            "status": ocr_packet.get("status"),
            "source_packet_kind": ocr_packet.get("source_packet_kind"),
            "packet_variant": ocr_packet.get("packet_variant")
            or SOURCE_OCR_PARAMETERS.get("packet_variant"),
            "packet_text": packet_text,
            "packet_chars": ocr_packet.get("packet_chars"),
        },
    }
    return json.dumps(envelope, ensure_ascii=True, sort_keys=True)


def build_contents(
    *,
    image_bytes: bytes,
    mime_type: str,
    context_text: str | None,
) -> list[Any]:
    from google.genai import types

    contents: list[Any] = []
    if context_text:
        contents.append(SERVER_CONTEXT_PREFIX + "\n" + context_text)
    contents.append(types.Part.from_bytes(data=image_bytes, mime_type=mime_type))
    contents.append(SERVER_CONTENT_TEXT if context_text else MODEL_CONTENT_TEXT)
    return contents


def generate_cell(
    *,
    client: Any,
    fixture: dict[str, Any],
    config: dict[str, Any],
    run_dir: Path,
) -> dict[str, Any]:
    from google.genai import types

    settings = config["settings"]
    screenshot_path = fixture["screenshot_path"]
    total_started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="tldr-sweep-cell") as executor:
        image_future = executor.submit(
            prepare_request_image,
            screenshot_path,
            settings,
            dest_dir=run_dir,
        )
        ocr_future = executor.submit(build_ocr_packet, settings, screenshot_path)
        request_image = image_future.result()
        ocr_packet = ocr_future.result()
    client_parallel_prep_ms = duration_ms(total_started)

    context_text = context_text_for_packet(ocr_packet)
    contents = build_contents(
        image_bytes=request_image["bytes_data"],
        mime_type=request_image["mime_type"],
        context_text=context_text,
    )
    generation_config = build_generate_config(types, config["prompt_text"], settings)
    network_started = time.perf_counter()
    response = client.models.generate_content(
        model=settings["model"],
        contents=contents,
        config=generation_config,
    )
    network_ms = duration_ms(network_started)
    raw_text = (response.text or "").strip()
    parsed, parse_error = _parse_json_response(raw_text)
    usage = plain_data(getattr(response, "usage_metadata", None))
    status = "ok"
    tldr = ""
    suggestions: list[str] = []
    if parsed is None:
        status = "parse_error"
    else:
        tldr, suggestions = _normalize_payload(parsed)
        if len(suggestions) != 3:
            status = "schema_mismatch"
    total_ms = duration_ms(total_started)
    return {
        "status": status,
        "fixture_slug": fixture["slug"],
        "config_name": config["name"],
        "model": settings["model"],
        "generated_at": now_iso(),
        "tldr": tldr,
        "suggestions": suggestions,
        "raw": raw_text,
        "parse_error": parse_error,
        "usage": usage,
        "timings": {
            "image_prepare_ms": request_image.get("duration_ms"),
            "ocr_ms": None if ocr_packet is None else ocr_packet.get("build_log", {}).get("ocr_ms"),
            "ocr_build_ms": None if ocr_packet is None else ocr_packet.get("build_ms"),
            "client_parallel_prep_ms": client_parallel_prep_ms,
            "network_ms": network_ms,
            "total_ms": total_ms,
        },
        "inputs": {
            "image_bytes_original": request_image["original_bytes"],
            "image_bytes_compressed": request_image["request_bytes"],
            "request_mime_type": request_image["mime_type"],
            "ocr_packet_chars": None if ocr_packet is None else ocr_packet.get("packet_chars"),
            "context_chars": len(context_text or ""),
        },
        "image": request_image["log"],
        "ocr_packet": ocr_packet,
        "settings": settings,
    }


def usage_summary(usage: Any) -> str:
    if not isinstance(usage, dict):
        return "n/a"
    prompt = usage.get("prompt_token_count") or usage.get("promptTokenCount")
    output = usage.get("candidates_token_count") or usage.get("candidatesTokenCount")
    total = usage.get("total_token_count") or usage.get("totalTokenCount")
    return f"prompt={prompt or 'n/a'}, output={output or 'n/a'}, total={total or 'n/a'}"


def usage_int(usage: Any, *keys: str) -> int | None:
    if not isinstance(usage, dict):
        return None
    for key in keys:
        value = usage.get(key)
        if isinstance(value, int):
            return value
    return None


def prompt_tokens(usage: Any) -> int | None:
    return usage_int(usage, "prompt_token_count", "promptTokenCount")


def total_tokens(usage: Any) -> int | None:
    return usage_int(usage, "total_token_count", "totalTokenCount")


def format_delta(value: int | None, baseline: int | None) -> str:
    if value is None or baseline is None:
        return "n/a"
    delta = value - baseline
    sign = "+" if delta > 0 else ""
    return f"{sign}{delta}"


def baseline_prompt_map(
    sweep_results: list[dict[str, Any]],
) -> tuple[dict[str, int | None], list[dict[str, Any]]]:
    baseline_prompt_by_fixture: dict[str, int | None] = {}
    unavailable: list[dict[str, Any]] = []
    for item in sweep_results:
        result = item["result"]
        if result["config_name"] != "tldr_baseline":
            continue
        prompt_value = prompt_tokens(result.get("usage"))
        baseline_prompt_by_fixture[result["fixture_slug"]] = prompt_value
        if prompt_value is None:
            unavailable.append(result)
    return baseline_prompt_by_fixture, unavailable


def baseline_unavailable_reason(result: dict[str, Any]) -> str:
    if result.get("status") != "ok":
        exception = result.get("exception") or {}
        label = exception.get("type") or result.get("status") or "error"
        messages = result.get("errors") or []
        message = messages[0] if messages else exception.get("message")
        return f"{label}: {message}" if message else str(label)
    return "baseline completed without prompt_token_count in usage metadata"


def output_text(run: dict[str, Any]) -> str:
    lines = [str(run.get("tldr") or "")]
    for index, suggestion in enumerate(run.get("suggestions") or [], start=1):
        lines.append(f"{index}. {suggestion}")
    return "\n".join(line for line in lines if line).strip()


def expected_output_text(fixture: dict[str, Any]) -> str:
    expected = fixture.get("expected")
    if not isinstance(expected, dict):
        return ""
    return output_text(expected)


def run_sweep(
    *,
    fixtures: list[dict[str, Any]],
    configs: list[dict[str, Any]],
    out_dir: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    from google import genai

    client = genai.Client(api_key=os.environ.get("GEMINI_API_KEY"))
    results: list[dict[str, Any]] = []
    manifest = {
        "generated_at": now_iso(),
        "fixtures": [fixture["slug"] for fixture in fixtures],
        "configs": [config["name"] for config in configs],
        "cell_count": len(fixtures) * len(configs),
        "failure_count": 0,
        "results": [],
    }
    for fixture in fixtures:
        fixture_result = {"fixture_slug": fixture["slug"], "runs": []}
        for config in configs:
            run_dir = out_dir / fixture["slug"] / config["name"]
            run_dir.mkdir(parents=True, exist_ok=True)
            print(f"[tldr-sweep] {fixture['slug']} x {config['name']}")
            try:
                run = generate_cell(
                    client=client,
                    fixture=fixture,
                    config=config,
                    run_dir=run_dir,
                )
            except Exception as exc:
                error_message = str(exc)
                run = {
                    "status": "error",
                    "fixture_slug": fixture["slug"],
                    "config_name": config["name"],
                    "model": config["settings"].get("model"),
                    "generated_at": now_iso(),
                    "tldr": "Sweep cell failed.",
                    "suggestions": [],
                    "raw": error_message,
                    "parse_error": None,
                    "usage": None,
                    "timings": {},
                    "inputs": {},
                    "settings": config["settings"],
                    "errors": [error_message],
                    "exception": {
                        "type": type(exc).__name__,
                        "message": error_message,
                        "traceback": traceback.format_exc(),
                    },
                }
                print(
                    f"[tldr-sweep] ERROR {fixture['slug']} x {config['name']}: "
                    f"{type(exc).__name__}: {error_message}"
                )
            if run.get("status") != "ok":
                manifest["failure_count"] += 1
            save_json(run_dir / "run.json", run)
            (run_dir / "output.txt").write_text(output_text(run) + "\n", encoding="utf-8")
            result = {
                "fixture_slug": fixture["slug"],
                "config_name": config["name"],
                "status": run["status"],
                "model": run.get("model"),
                "usage": run.get("usage"),
                "timings": run.get("timings") or {},
                "inputs": run.get("inputs") or {},
                "output_text": output_text(run),
                "errors": list(run.get("errors") or []),
                "exception": run.get("exception"),
                "run_json": run_dir / "run.json",
                "output_txt": run_dir / "output.txt",
            }
            fixture_result["runs"].append(result)
            results.append({"fixture": fixture, "config": config, "result": result})
        manifest["results"].append(fixture_result)
    return manifest, results


def format_ms(value: Any) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value):.2f}"
    except (TypeError, ValueError):
        return str(value)


def render_summary(
    *,
    out_dir: Path,
    fixtures: list[dict[str, Any]],
    configs: list[dict[str, Any]],
    sweep_results: list[dict[str, Any]],
) -> str:
    lines = ["# TLDR Sweep Summary", ""]
    failure_results = [
        item["result"] for item in sweep_results if item["result"].get("status") != "ok"
    ]
    lines.extend(
        [
            "## Run Health",
            "",
            f"- Cells: `{len(sweep_results)}`",
            f"- Failures: `{len(failure_results)}`",
            f"- Latency accounting: {LATENCY_ACCOUNTING_NOTE}",
            "",
        ]
    )
    if failure_results:
        lines.extend(["### Failures", ""])
        for result in failure_results:
            exception = result.get("exception") or {}
            label = exception.get("type") or "error"
            message = (result.get("errors") or [exception.get("message") or "unknown error"])[0]
            lines.append(
                f"- `{result['fixture_slug']}` x `{result['config_name']}`: "
                f"`{label}` {message}. "
                f"[run.json]({relative_link(out_dir, result['run_json'])})"
            )
        lines.append("")

    lines.extend(["## Fixtures", ""])
    for fixture in fixtures:
        lines.append(
            f"- `{fixture['slug']}`: "
            f"[tldr_fixture.json]({relative_link(out_dir, fixture['manifest_path'])}), "
            f"[screenshot.png]({relative_link(out_dir, fixture['screenshot_path'])})"
        )
    lines.extend(["", "## Configs", ""])
    lines.extend(
        [
            "| Name | Model | Media resolution | Format | Max dim | JPEG quality | OCR | Raw OCR |",
            "| --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for config in configs:
        settings = config["settings"]
        lines.append(
            f"| `{config['name']}` | `{settings.get('model')}` | "
            f"`{settings.get('media_resolution')}` | "
            f"`{settings.get('request_image_format', 'png')}` | "
            f"`{settings.get('request_image_max_dimension', 'native')}` | "
            f"`{settings.get('request_image_jpeg_quality', 'n/a')}` | "
            f"`{bool(settings.get('tldr_include_ocr_packet'))}` | "
            f"`{bool(settings.get('tldr_ocr_raw'))}` |"
        )
    baseline_prompt_by_fixture, baseline_unavailable = baseline_prompt_map(sweep_results)

    lines.extend(
        [
            "",
            "## Metrics",
            "",
        ]
    )
    if baseline_unavailable:
        lines.extend(
            [
                "> Baseline errored or omitted prompt-token usage for one or more fixtures; prompt-token deltas are unavailable for those rows.",
                "",
            ]
        )
        for result in baseline_unavailable:
            lines.append(
                f"- `{result['fixture_slug']}` baseline: {baseline_unavailable_reason(result)}"
            )
        lines.append("")
    lines.extend(
        [
            "| Fixture | Config | Status | Prompt tokens | Prompt delta vs baseline | Total tokens | Request bytes | OCR ms | Prep ms | Network ms | Total ms |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for item in sweep_results:
        result = item["result"]
        timings = result["timings"]
        inputs = result["inputs"]
        prompt_value = prompt_tokens(result.get("usage"))
        baseline_prompt = baseline_prompt_by_fixture.get(result["fixture_slug"])
        lines.append(
            f"| `{result['fixture_slug']}` | `{result['config_name']}` | "
            f"`{result['status']}` | `{prompt_value if prompt_value is not None else 'n/a'}` | "
            f"`{format_delta(prompt_value, baseline_prompt)}` | "
            f"`{total_tokens(result.get('usage')) if total_tokens(result.get('usage')) is not None else 'n/a'}` | "
            f"`{inputs.get('image_bytes_compressed', 'n/a')}` | "
            f"`{format_ms(timings.get('ocr_ms'))}` | "
            f"`{format_ms(timings.get('client_parallel_prep_ms'))}` | "
            f"`{format_ms(timings.get('network_ms'))}` | "
            f"`{format_ms(timings.get('total_ms'))}` |"
        )

    lines.extend(["", "## Per-fixture Outputs", ""])
    for fixture in fixtures:
        lines.extend([f"### {fixture['slug']}", ""])
        prod_output = expected_output_text(fixture)
        if prod_output:
            expected_link = fixture.get("expected_path")
            artifact_line = (
                f"- Production artifact: [expected.json]({relative_link(out_dir, expected_link)})"
                if isinstance(expected_link, Path)
                else "- Production artifact: `expected.json`"
            )
            lines.extend(
                [
                    "#### prod",
                    "",
                    artifact_line,
                    "",
                    "```text",
                    prod_output,
                    "```",
                    "",
                ]
            )
        related = [item for item in sweep_results if item["fixture"]["slug"] == fixture["slug"]]
        for item in related:
            result = item["result"]
            timings = result["timings"]
            inputs = result["inputs"]
            lines.extend(
                [
                    f"#### {item['config']['name']}",
                    "",
                    f"- Status: `{result['status']}`",
                    f"- Image bytes: `{inputs.get('image_bytes_original', 'n/a')}` original, `{inputs.get('image_bytes_compressed', 'n/a')}` request",
                    f"- OCR: `{format_ms(timings.get('ocr_ms'))} ms`; prep: `{format_ms(timings.get('client_parallel_prep_ms'))} ms`; network/model: `{format_ms(timings.get('network_ms'))} ms`; total: `{format_ms(timings.get('total_ms'))} ms`",
                    f"- Usage: `{usage_summary(result.get('usage'))}`",
                    f"- Artifacts: [run.json]({relative_link(out_dir, result['run_json'])}), [output.txt]({relative_link(out_dir, result['output_txt'])})",
                    "",
                    "```text",
                    result["output_text"],
                    "```",
                    "",
                ]
            )
            if result.get("errors"):
                lines.extend([f"- Error: `{result['errors'][0]}`", ""])
    lines.extend(
        [
            "## Manual Judging Rubric",
            "",
            "For each fixture x config cell, grade:",
            "",
            "1. TLDR accuracy versus the screenshot and, when present, the `prod` output.",
            "2. Suggestion plausibility versus the screenshot and, when present, the `prod` output.",
            "3. Small-text recovery versus baseline.",
            "4. Whether total_ms and image_bytes_compressed justify the OCR/compression tradeoff.",
            "",
            "Overall decision:",
            "",
            "1. Keep production baseline.",
            "2. Try a narrower compression-only setting.",
            "3. Promote one OCR-backed config into Phase B.",
            "",
        ]
    )
    return "\n".join(lines)


def render_compare_html(
    *,
    out_dir: Path,
    fixtures: list[dict[str, Any]],
    configs: list[dict[str, Any]],
    sweep_results: list[dict[str, Any]],
) -> str:
    result_map = {
        (item["fixture"]["slug"], item["config"]["name"]): item["result"]
        for item in sweep_results
    }
    baseline_prompt_by_fixture, baseline_unavailable = baseline_prompt_map(sweep_results)
    baseline_banner = ""
    if baseline_unavailable:
        reasons = "".join(
            "<li>"
            + html.escape(
                f"{result['fixture_slug']} baseline: {baseline_unavailable_reason(result)}"
            )
            + "</li>"
            for result in baseline_unavailable
        )
        baseline_banner = (
            '<section class="warning"><strong>Baseline errored - deltas unavailable.</strong>'
            f"<ul>{reasons}</ul></section>"
        )
    rows: list[str] = []
    for fixture in fixtures:
        screenshot = html.escape(relative_link(out_dir, fixture["screenshot_path"]))
        manifest = html.escape(relative_link(out_dir, fixture["manifest_path"]))
        prod_output = expected_output_text(fixture)
        expected_path = fixture.get("expected_path")
        if prod_output:
            expected_link = (
                html.escape(relative_link(out_dir, expected_path))
                if isinstance(expected_path, Path)
                else ""
            )
            artifact = (
                f'<div><a href="{expected_link}">expected.json</a></div>'
                if expected_link
                else ""
            )
            prod_html = (
                '<td class="prod"><strong>prod</strong>'
                '<div class="meta">production output from imported run</div>'
                f"{artifact}"
                f"<pre>{html.escape(prod_output)}</pre></td>"
            )
        else:
            prod_html = '<td class="prod empty"></td>'
        cells = [
            (
                f'<th class="fixture"><div>{html.escape(fixture["slug"])}</div>'
                f'<a href="{screenshot}"><img src="{screenshot}" alt="{html.escape(fixture["slug"])}"></a>'
                f'<div><a href="{manifest}">tldr_fixture.json</a></div></th>'
            ),
            prod_html,
        ]
        for config in configs:
            result = result_map[(fixture["slug"], config["name"])]
            timings = result["timings"]
            inputs = result["inputs"]
            prompt_value = prompt_tokens(result.get("usage"))
            prompt_delta = format_delta(
                prompt_value,
                baseline_prompt_by_fixture.get(result["fixture_slug"]),
            )
            run_json = html.escape(relative_link(out_dir, result["run_json"]))
            output_txt = html.escape(relative_link(out_dir, result["output_txt"]))
            cells.append(
                f"""
                <td>
                  <strong>{html.escape(config["name"])}</strong>
                  <div class="meta">status: {html.escape(str(result["status"]))}</div>
                  <div class="meta">bytes: {html.escape(str(inputs.get("image_bytes_compressed", "n/a")))} / {html.escape(str(inputs.get("image_bytes_original", "n/a")))}</div>
                  <div class="meta">prompt tokens: {html.escape(str(prompt_value if prompt_value is not None else "n/a"))} ({html.escape(prompt_delta)})</div>
                  <div class="meta">ocr: {html.escape(format_ms(timings.get("ocr_ms")))} ms</div>
                  <div class="meta">prep: {html.escape(format_ms(timings.get("client_parallel_prep_ms")))} ms</div>
                  <div class="meta">network: {html.escape(format_ms(timings.get("network_ms")))} ms</div>
                  <div class="meta">total: {html.escape(format_ms(timings.get("total_ms")))} ms</div>
                  <div class="meta">usage: {html.escape(usage_summary(result.get("usage")))}</div>
                  <pre>{html.escape(result["output_text"])}</pre>
                  <div><a href="{run_json}">run.json</a> · <a href="{output_txt}">output.txt</a></div>
                </td>
                """
            )
        rows.append("<tr>" + "".join(cells) + "</tr>")
    header_cells = "<th>prod</th>" + "".join(
        f"<th>{html.escape(config['name'])}</th>" for config in configs
    )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>TLDR Sweep Compare</title>
  <style>
    body {{ margin: 0; padding: 24px; font: 14px/1.45 -apple-system, BlinkMacSystemFont, sans-serif; color: #202124; background: #f6f7f8; }}
    table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
    th, td {{ vertical-align: top; border: 1px solid #d8dde3; padding: 12px; background: #fff; }}
    th {{ position: sticky; top: 0; background: #eef2f5; z-index: 1; }}
    .fixture {{ min-width: 240px; text-align: left; }}
    img {{ width: 100%; max-width: 240px; display: block; margin: 8px 0; border: 1px solid #d8dde3; }}
    .meta {{ margin-top: 5px; font-size: 12px; color: #555; }}
    .prod {{ background: #fffaf0; }}
    .prod.empty {{ background: #fff; }}
    .warning {{ margin: 0 0 18px; padding: 12px 14px; border: 1px solid #d97706; background: #fff7ed; color: #7c2d12; }}
    .warning ul {{ margin: 6px 0 0 18px; padding: 0; }}
    pre {{ min-height: 160px; white-space: pre-wrap; padding: 10px; background: #f9fafb; border: 1px solid #e1e5e9; }}
  </style>
</head>
<body>
  <h1>TLDR Sweep Compare</h1>
  {baseline_banner}
  <table>
    <thead><tr><th>Fixture</th>{header_cells}</tr></thead>
    <tbody>{"".join(rows)}</tbody>
  </table>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    load_workspace_env()
    if not os.environ.get("GEMINI_API_KEY"):
        print("Set GEMINI_API_KEY before running the TLDR sweep.", file=sys.stderr)
        return 1
    fixture_dirs = [
        path for path in expand_glob(args.fixtures) if (path / "tldr_fixture.json").exists()
    ]
    config_paths = [path for path in expand_glob(args.configs) if path.suffix == ".json"]
    if not fixture_dirs:
        print(f"No TLDR fixtures matched: {args.fixtures}", file=sys.stderr)
        return 1
    if not config_paths:
        print(f"No TLDR configs matched: {args.configs}", file=sys.stderr)
        return 1
    out_dir = resolve_path(args.out)
    if out_dir.name == "{auto-timestamp}":
        out_dir = out_dir.parent / datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)
    base_settings = dict(DEFAULT_SETTINGS)
    base_settings.update(
        {
            "preprocess_request_images": True,
            "request_image_format": "jpeg",
            "request_image_max_dimension": 1600,
            "request_image_jpeg_quality": 80,
            "tldr_include_ocr_packet": False,
            "tldr_ocr_raw": False,
        }
    )
    fixtures = [fixture_record(path) for path in fixture_dirs]
    configs = [config_record(path, base_settings) for path in config_paths]
    manifest, results = run_sweep(fixtures=fixtures, configs=configs, out_dir=out_dir)
    save_json(out_dir / "sweep.json", manifest)
    (out_dir / "summary.md").write_text(
        render_summary(out_dir=out_dir, fixtures=fixtures, configs=configs, sweep_results=results),
        encoding="utf-8",
    )
    (out_dir / "compare.html").write_text(
        render_compare_html(out_dir=out_dir, fixtures=fixtures, configs=configs, sweep_results=results),
        encoding="utf-8",
    )
    print(f"[tldr-sweep] wrote {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
