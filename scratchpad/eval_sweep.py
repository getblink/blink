#!/usr/bin/env python3

from __future__ import annotations

import argparse
import glob
import html
import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

from env_loader import load_workspace_env
from gemini_runner import now_iso, plain_data
from make_trial import slugify
from providers import dispatch, provider_name


BASE_DIR = Path(__file__).resolve().parent
ROOT_DIR = BASE_DIR.parent
PROMPT_PATH = BASE_DIR / "prompt.txt"
SETTINGS_PATH = BASE_DIR / "settings.json"

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
    parser = argparse.ArgumentParser(description="Run an offline fixture x config sweep.")
    parser.add_argument(
        "--fixtures",
        required=True,
        help="Glob for fixture directories, e.g. 'scratchpad/fixtures/*chrome*'.",
    )
    parser.add_argument(
        "--configs",
        required=True,
        help="Glob for config JSON files, e.g. 'scratchpad/eval_configs/*.json'.",
    )
    parser.add_argument(
        "--out",
        required=True,
        help="Output directory for the sweep bundle.",
    )
    return parser.parse_args()


def load_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json_file(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def resolve_from_root(path_str: str) -> Path:
    path = Path(path_str).expanduser()
    if path.is_absolute():
        return path
    return (ROOT_DIR / path).resolve()


def expand_glob(pattern: str) -> list[Path]:
    absolute_pattern = pattern if pattern.startswith("/") else str(ROOT_DIR / pattern)
    # Preserve symlinked fixture paths so sweep artifacts keep workspace-relative
    # links that still work after archive bundles dereference the pool.
    return sorted(Path(match) for match in glob.glob(absolute_pattern))


def load_settings() -> dict[str, Any]:
    settings = DEFAULT_SETTINGS.copy()
    if SETTINGS_PATH.exists():
        settings.update(load_json_file(SETTINGS_PATH))
    settings["stream_to_terminal"] = False
    settings["copy_to_clipboard"] = False
    return settings


def load_prompt(prompt_path: str | None) -> str:
    path = resolve_from_root(prompt_path) if prompt_path else PROMPT_PATH
    return path.read_text(encoding="utf-8").strip()


def relative_link(from_dir: Path, to_path: Path) -> str:
    return os.path.relpath(to_path, start=from_dir)


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


def config_record(config_path: Path, base_settings: dict[str, Any]) -> dict[str, Any]:
    raw_config = load_json_file(config_path)
    name = raw_config.get("name") or slugify(config_path.stem)
    prompt_path = raw_config.get("prompt_path")
    settings = base_settings.copy()
    for key, value in raw_config.items():
        if key not in {"name", "prompt_path"}:
            settings[key] = value
    settings["stream_to_terminal"] = False
    settings["copy_to_clipboard"] = False
    settings["provider"] = provider_name(settings)
    return {
        "name": name,
        "config_path": config_path,
        "prompt_path": prompt_path,
        "prompt_text": load_prompt(prompt_path),
        "settings": settings,
        "raw_config": raw_config,
    }


def usage_summary(run_log: dict[str, Any]) -> str:
    usage = run_log.get("response", {}).get("usage_metadata")
    if not isinstance(usage, dict):
        return "n/a"
    prompt_tokens = (
        usage.get("prompt_token_count")
        or usage.get("promptTokenCount")
        or usage.get("prompt_tokens")
        or usage.get("input_tokens")
    )
    output_tokens = (
        usage.get("candidates_token_count")
        or usage.get("candidatesTokenCount")
        or usage.get("completion_tokens")
        or usage.get("output_tokens")
    )
    return f"prompt={prompt_tokens or 'n/a'}, output={output_tokens or 'n/a'}"


def format_ms(value: Any) -> str:
    if value is None:
        return "n/a"
    try:
        return f"{float(value):.2f}"
    except (TypeError, ValueError):
        return str(value)


def display_setting(settings: dict[str, Any], key: str) -> Any:
    value = settings.get(key)
    if value in {None, ""}:
        return "n/a"
    return value


def run_sweep(
    fixtures: list[dict[str, Any]],
    configs: list[dict[str, Any]],
    out_dir: Path,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    client_cache: dict[tuple[Any, ...], Any] = {}
    sweep_results: list[dict[str, Any]] = []
    sweep_manifest = {
        "generated_at": now_iso(),
        "fixtures": [item["fixture_id"] for item in fixtures],
        "configs": [item["name"] for item in configs],
        "results": [],
    }

    for fixture in fixtures:
        fixture_result = {"fixture_id": fixture["fixture_id"], "runs": []}
        for config in configs:
            run_dir = out_dir / fixture["fixture_id"] / config["name"]
            run_dir.mkdir(parents=True, exist_ok=True)
            print(f"[sweep] {fixture['fixture_id']} x {config['name']}")
            try:
                generation = dispatch(
                    client_cache,
                    config,
                    config["prompt_text"],
                    fixture["source_path"],
                    fixture["target_path"],
                    fixture["target_metadata"],
                )
            except Exception as exc:
                error_message = str(exc)
                print(
                    f"[sweep] ERROR {fixture['fixture_id']} x {config['name']}: {error_message}",
                )
                generation = {
                    "run_log": {
                        "status": "error",
                        "errors": [error_message],
                        "timings": {},
                        "request": {},
                        "response": {},
                    },
                    "output_text": "",
                }
            run_log = generation["run_log"]
            run_log["fixture_id"] = fixture["fixture_id"]
            run_log["config_name"] = config["name"]
            run_log["config_path"] = str(config["config_path"])
            run_log["prompt_path"] = str(resolve_from_root(config["prompt_path"])) if config["prompt_path"] else str(PROMPT_PATH)
            if run_log.get("status") == "error":
                errors = run_log.get("errors") or ["unknown error"]
                print(
                    f"[sweep] cell status=error: {fixture['fixture_id']} x {config['name']}: {errors[0]}"
                )
            output_text = generation["output_text"]
            (run_dir / "output.txt").write_text(
                output_text + ("\n" if output_text else ""),
                encoding="utf-8",
            )
            save_json_file(run_dir / "run.json", run_log)
            cell_result = {
                "fixture_id": fixture["fixture_id"],
                "config_name": config["name"],
                "status": run_log["status"],
                "latency_ms": run_log.get("timings", {}).get("model_latency_ms"),
                "model_latency_ms": run_log.get("timings", {}).get("model_latency_ms"),
                "ttft_ms": run_log.get("timings", {}).get("ttft_ms"),
                "stream_duration_ms": run_log.get("timings", {}).get("stream_duration_ms"),
                "usage": run_log.get("response", {}).get("usage_metadata"),
                "output_text": output_text,
                "errors": list(run_log.get("errors") or []),
                "provider": provider_name(config["settings"]),
                "model": config["settings"].get("model"),
                "run_json": run_dir / "run.json",
                "output_txt": run_dir / "output.txt",
            }
            fixture_result["runs"].append(cell_result)
            sweep_results.append(
                {
                    "fixture": fixture,
                    "config": config,
                    "result": cell_result,
                }
            )
        sweep_manifest["results"].append(fixture_result)
    return sweep_manifest, sweep_results


def render_summary(
    *,
    out_dir: Path,
    fixtures: list[dict[str, Any]],
    configs: list[dict[str, Any]],
    sweep_results: list[dict[str, Any]],
) -> str:
    lines: list[str] = ["# Sweep Summary", ""]

    lines.extend(["## Fixtures", ""])
    for fixture in fixtures:
        manifest_link = relative_link(out_dir, fixture["fixture_dir"] / "fixture.json")
        source_link = relative_link(out_dir, fixture["source_path"])
        target_link = relative_link(out_dir, fixture["target_path"])
        lines.append(
            f"- `{fixture['fixture_id']}`: [fixture.json]({manifest_link}), "
            f"[source.png]({source_link}), [target.png]({target_link})"
        )

    lines.extend(
        [
            "",
            "## Configs",
            "",
            "| Name | Provider | Model | Temp | Media | Thinking | Prompt |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
    )
    for config in configs:
        settings = config["settings"]
        config_provider = provider_name(settings)
        prompt_label = config["prompt_path"] or "scratchpad/prompt.txt"
        media_label = display_setting(settings, "media_resolution") if config_provider == "gemini" else "n/a"
        thinking_label = display_setting(settings, "thinking_level") if config_provider == "gemini" else "n/a"
        lines.append(
            f"| `{config['name']}` | `{config_provider}` | `{display_setting(settings, 'model')}` | "
            f"`{display_setting(settings, 'temperature')}` | `{media_label}` | "
            f"`{thinking_label}` | `{prompt_label}` |"
        )

    lines.extend(["", "## Per-fixture Outputs", ""])
    for fixture in fixtures:
        lines.extend([f"### {fixture['fixture_id']}", ""])
        related = [item for item in sweep_results if item["fixture"]["fixture_id"] == fixture["fixture_id"]]
        for item in related:
            result = item["result"]
            run_json_link = relative_link(out_dir, result["run_json"])
            output_txt_link = relative_link(out_dir, result["output_txt"])
            lines.extend(
                [
                    f"#### {item['config']['name']}",
                    "",
                    f"- Status: `{result['status']}`",
                    f"- Model latency: `{format_ms(result.get('model_latency_ms', result.get('latency_ms')))} ms`",
                    f"- TTFT: `{format_ms(result.get('ttft_ms'))} ms`",
                    f"- Stream duration: `{format_ms(result.get('stream_duration_ms'))} ms`",
                    f"- Usage: `{usage_summary({'response': {'usage_metadata': result['usage']}})}`",
                    f"- Artifacts: [run.json]({run_json_link}), [output.txt]({output_txt_link})",
                    "",
                ]
            )
            if result.get("errors"):
                lines.extend([f"- Error: `{result['errors'][0]}`", ""])
            lines.extend(
                [
                    "```text",
                    result["output_text"].rstrip(),
                    "```",
                    "",
                ]
            )

    lines.extend(
        [
            "## Judging Rubric (Claude fills)",
            "",
            "For each fixture:",
            "1. Pick the best config.",
            "2. Give a one-sentence why.",
            "",
            "For each config:",
            "1. Summarize strengths.",
            "2. Summarize failure modes.",
            "3. Give an overall letter grade.",
            "",
            "Overall recommendation:",
            "1. Recommend the config to keep testing.",
            "2. Call out the next prompt or capture improvement to try.",
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
        (item["fixture"]["fixture_id"], item["config"]["name"]): item["result"]
        for item in sweep_results
    }
    config_names = [config["name"] for config in configs]
    rows: list[str] = []
    for fixture in fixtures:
        header_links = " · ".join(
            [
                f'<a href="{html.escape(relative_link(out_dir, fixture["target_path"]))}">target</a>',
                f'<a href="{html.escape(relative_link(out_dir, fixture["source_path"]))}">source</a>',
                f'<a href="{html.escape(relative_link(out_dir, fixture["fixture_dir"] / "fixture.json"))}">fixture.json</a>',
            ]
        )
        cells = [
            (
                f'<th class="fixture-head"><div>{html.escape(fixture["fixture_id"])}</div>'
                f'<div class="fixture-links">{header_links}</div></th>'
            )
        ]
        target_thumb = html.escape(relative_link(out_dir, fixture["target_path"]))
        for config_name in config_names:
            result = result_map[(fixture["fixture_id"], config_name)]
            output_preview = html.escape(result["output_text"] or "")
            error_preview = html.escape((result.get("errors") or [""])[0])
            run_json = html.escape(relative_link(out_dir, result["run_json"]))
            output_txt = html.escape(relative_link(out_dir, result["output_txt"]))
            cells.append(
                f"""
                <td class="cell">
                  <a href="{target_thumb}" class="thumb-link"><img src="{target_thumb}" alt="{html.escape(fixture['fixture_id'])}" class="thumb"></a>
                  <div class="meta"><strong>{html.escape(config_name)}</strong></div>
                  <div class="meta">provider: {html.escape(str(result.get('provider') or 'n/a'))}</div>
                  <div class="meta">model: {html.escape(str(result.get('model') or 'n/a'))}</div>
                  <div class="meta">status: {html.escape(str(result['status']))}</div>
                  <div class="meta">latency: {html.escape(format_ms(result.get('model_latency_ms', result.get('latency_ms'))))} ms</div>
                  <div class="meta">ttft: {html.escape(format_ms(result.get('ttft_ms')))} ms</div>
                  <div class="meta">stream: {html.escape(format_ms(result.get('stream_duration_ms')))} ms</div>
                  {'<div class="meta error">error: ' + error_preview + '</div>' if error_preview else ''}
                  <pre>{output_preview}</pre>
                  <div class="links"><a href="{run_json}">run.json</a> · <a href="{output_txt}">output.txt</a></div>
                </td>
                """
            )
        rows.append("<tr>" + "".join(cells) + "</tr>")

    header_cells = "".join(f"<th>{html.escape(config['name'])}</th>" for config in configs)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Blink Sweep Compare</title>
  <style>
    :root {{
      --bg: #f4efe6;
      --card: #fffaf2;
      --ink: #1f1d1a;
      --line: #d3c9bb;
      --accent: #b04a2f;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 24px;
      background: radial-gradient(circle at top left, #fff7dd, var(--bg) 45%);
      color: var(--ink);
      font: 14px/1.45 "Iowan Old Style", "Palatino Linotype", serif;
    }}
    h1 {{
      margin: 0 0 16px;
      font-size: 28px;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }}
    th, td {{
      border: 1px solid var(--line);
      vertical-align: top;
      padding: 12px;
      background: var(--card);
    }}
    th {{
      position: sticky;
      top: 0;
      background: #f8efe2;
      z-index: 1;
    }}
    .fixture-head {{
      min-width: 240px;
      text-align: left;
    }}
    .fixture-links, .links, .meta {{
      margin-top: 6px;
      font-size: 12px;
    }}
    .error {{
      color: #8b1e16;
      font-weight: 600;
    }}
    .thumb {{
      width: 100%;
      max-width: 220px;
      border: 1px solid var(--line);
      display: block;
      margin-bottom: 8px;
    }}
    pre {{
      margin: 8px 0 0;
      padding: 10px;
      white-space: pre-wrap;
      background: #fff;
      border: 1px solid var(--line);
      min-height: 140px;
    }}
    a {{
      color: var(--accent);
    }}
  </style>
</head>
<body>
  <h1>Blink Sweep Compare</h1>
  <table>
    <thead>
      <tr>
        <th>Fixture</th>
        {header_cells}
      </tr>
    </thead>
    <tbody>
      {"".join(rows)}
    </tbody>
  </table>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    load_workspace_env()
    fixture_dirs = [path for path in expand_glob(args.fixtures) if (path / "fixture.json").exists()]
    config_paths = [path for path in expand_glob(args.configs) if path.suffix == ".json"]
    if not fixture_dirs:
        print(f"No fixtures matched: {args.fixtures}")
        return 1
    if not config_paths:
        print(f"No configs matched: {args.configs}")
        return 1

    out_dir = resolve_from_root(args.out)
    if out_dir.name == "{auto-timestamp}":
        out_dir = out_dir.parent / datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir.mkdir(parents=True, exist_ok=True)

    base_settings = load_settings()
    fixtures = [fixture_record(path) for path in fixture_dirs]
    configs = [config_record(path, base_settings) for path in config_paths]
    sweep_manifest, sweep_results = run_sweep(fixtures, configs, out_dir)

    save_json_file(out_dir / "sweep.json", sweep_manifest)
    (out_dir / "summary.md").write_text(
        render_summary(
            out_dir=out_dir,
            fixtures=fixtures,
            configs=configs,
            sweep_results=sweep_results,
        ),
        encoding="utf-8",
    )
    (out_dir / "compare.html").write_text(
        render_compare_html(
            out_dir=out_dir,
            fixtures=fixtures,
            configs=configs,
            sweep_results=sweep_results,
        ),
        encoding="utf-8",
    )
    print(f"[sweep] wrote {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
