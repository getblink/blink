#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import re
import shutil
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a reusable screenshot-to-field experiment bundle."
    )
    parser.add_argument("name", help="Short name for the trial bundle.")
    parser.add_argument(
        "--source",
        action="append",
        dest="sources",
        required=True,
        help="Absolute or relative path to a source image. Repeat for multiple images.",
    )
    parser.add_argument(
        "--target",
        action="append",
        dest="targets",
        required=True,
        help="Absolute or relative path to a target image. Repeat for multiple images.",
    )
    parser.add_argument(
        "--intent",
        default="copy_exact",
        help="High-level task intent, e.g. copy_exact or summarize_for_field.",
    )
    parser.add_argument(
        "--target-context-file",
        help="Path to a JSON file describing focused-field context.",
    )
    parser.add_argument(
        "--annotation-file",
        help="Path to a JSON file describing optional annotation hints.",
    )
    parser.add_argument(
        "--notes",
        default="",
        help="Freeform notes about the trial.",
    )
    parser.add_argument(
        "--output-dir",
        default="scratchpad/runs",
        help="Directory where generated trial bundles should be written.",
    )
    return parser.parse_args()


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return slug or "trial"


def load_json_file(path_str: str | None) -> Any:
    if not path_str:
        return None
    path = Path(path_str).expanduser().resolve()
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def ensure_files(paths: list[str], kind: str) -> list[Path]:
    resolved: list[Path] = []
    for raw_path in paths:
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file():
            raise FileNotFoundError(f"{kind} image not found: {path}")
        resolved.append(path)
    return resolved


def copy_assets(paths: list[Path], destination: Path) -> list[str]:
    destination.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []
    for index, path in enumerate(paths, start=1):
        suffix = path.suffix or ".bin"
        filename = f"{index:02d}-{slugify(path.stem)}{suffix.lower()}"
        output_path = destination / filename
        shutil.copy2(path, output_path)
        copied.append(str(output_path.relative_to(destination.parent)))
    return copied


def render_prompt(
    *,
    source_count: int,
    target_count: int,
    task_intent: str,
    target_context: Any,
    annotation_hints: Any,
) -> str:
    target_context_block = (
        json.dumps(target_context, indent=2, ensure_ascii=True)
        if target_context is not None
        else "Not provided."
    )
    annotation_block = (
        json.dumps(annotation_hints, indent=2, ensure_ascii=True)
        if annotation_hints is not None
        else "Not provided."
    )
    return f"""You are a precise clipboard assistant.

Task:
Given {source_count} SOURCE_IMAGE(S) and {target_count} TARGET_IMAGE(S), return ONLY the text that should be inserted into the intended target field.

Task metadata:
- task_intent: "{task_intent}"

Target context:
{target_context_block}

Annotation hints:
{annotation_block}

Rules:
1) Use the source images as the primary truth for content.
2) Use the target images to determine the intended destination field and local UI constraints.
3) If target context is provided, treat it as the strongest hint for which field the user means.
4) Prefer exact carry-over unless task_intent or output constraints require transformation.
5) If existing field text is provided, return the exact text needed for that current field state.
6) Return plain text only. No explanations.
7) If the correct result should be empty, return [[BLANK]].
8) If uncertain, return [[NEEDS_REVIEW: reason in <=12 words]].
"""


def render_markdown(
    *,
    title: str,
    notes: str,
    prompt_text: str,
    source_paths: list[str],
    target_paths: list[str],
    target_context: Any,
    annotation_hints: Any,
) -> str:
    target_context_block = json.dumps(target_context, indent=2, ensure_ascii=True)
    annotation_block = json.dumps(annotation_hints, indent=2, ensure_ascii=True)
    lines = [f"# Trial Packet: {title}", ""]

    if notes:
        lines.extend(["## Notes", "", notes, ""])

    lines.extend(["## Source Images", ""])
    for path in source_paths:
        lines.append(f"- `{path}`")

    lines.extend(["", "## Target Images", ""])
    for path in target_paths:
        lines.append(f"- `{path}`")

    lines.extend(
        [
            "",
            "## Prompt",
            "",
            "```text",
            prompt_text.rstrip(),
            "```",
            "",
            "## Target Context",
            "",
            "```json",
            target_context_block,
            "```",
            "",
            "## Annotation Hints",
            "",
            "```json",
            annotation_block,
            "```",
            "",
        ]
    )
    return "\n".join(lines)


def render_html(
    *,
    title: str,
    notes: str,
    prompt_text: str,
    source_paths: list[str],
    target_paths: list[str],
    target_context: Any,
    annotation_hints: Any,
) -> str:
    def image_cards(paths: list[str]) -> str:
        cards = []
        for path in paths:
            safe_path = html.escape(path, quote=True)
            safe_label = html.escape(path)
            cards.append(
                f"""
                <figure class="card">
                  <img src="{safe_path}" alt="{safe_label}">
                  <figcaption>{safe_label}</figcaption>
                </figure>
                """
            )
        return "\n".join(cards)

    notes_block = (
        f"<section><h2>Notes</h2><p>{html.escape(notes)}</p></section>" if notes else ""
    )
    target_context_block = html.escape(
        json.dumps(target_context, indent=2, ensure_ascii=True)
    )
    annotation_block = html.escape(
        json.dumps(annotation_hints, indent=2, ensure_ascii=True)
    )
    prompt_block = html.escape(prompt_text)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      color-scheme: light;
      --bg: #f5f1ea;
      --panel: #fffdf8;
      --ink: #1c1a18;
      --muted: #6c655d;
      --line: #d9d0c5;
      --accent: #1155cc;
    }}
    * {{
      box-sizing: border-box;
    }}
    body {{
      margin: 0;
      font-family: Georgia, "Times New Roman", serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(17, 85, 204, 0.08), transparent 28rem),
        linear-gradient(180deg, #f7f3ec, var(--bg));
    }}
    main {{
      max-width: 1200px;
      margin: 0 auto;
      padding: 32px 20px 48px;
    }}
    h1, h2 {{
      margin: 0 0 12px;
    }}
    p {{
      margin: 0 0 16px;
      color: var(--muted);
      line-height: 1.5;
    }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 20px;
      box-shadow: 0 18px 40px rgba(28, 26, 24, 0.07);
    }}
    .grid {{
      display: grid;
      gap: 20px;
    }}
    .images {{
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    }}
    .two-up {{
      grid-template-columns: 1.1fr 0.9fr;
      align-items: start;
    }}
    .card {{
      margin: 0;
      border: 1px solid var(--line);
      border-radius: 14px;
      overflow: hidden;
      background: #ffffff;
    }}
    .card img {{
      display: block;
      width: 100%;
      height: auto;
      background: #ede7de;
    }}
    .card figcaption {{
      padding: 10px 12px;
      font-size: 14px;
      color: var(--muted);
      border-top: 1px solid var(--line);
    }}
    pre {{
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      font: 13px/1.5 "SFMono-Regular", Menlo, monospace;
      color: #27221d;
    }}
    .stack {{
      display: grid;
      gap: 20px;
    }}
    @media (max-width: 900px) {{
      .two-up {{
        grid-template-columns: 1fr;
      }}
    }}
  </style>
</head>
<body>
  <main class="stack">
    <section class="panel">
      <h1>{html.escape(title)}</h1>
      <p>Scratchpad bundle for a manual screenshot-to-field experiment.</p>
      {notes_block}
    </section>
    <section class="grid two-up">
      <div class="panel">
        <h2>Source Images</h2>
        <div class="grid images">
          {image_cards(source_paths)}
        </div>
      </div>
      <div class="panel">
        <h2>Target Images</h2>
        <div class="grid images">
          {image_cards(target_paths)}
        </div>
      </div>
    </section>
    <section class="grid two-up">
      <div class="panel stack">
        <div>
          <h2>Prompt</h2>
          <pre>{prompt_block}</pre>
        </div>
      </div>
      <div class="stack">
        <section class="panel">
          <h2>Target Context</h2>
          <pre>{target_context_block}</pre>
        </section>
        <section class="panel">
          <h2>Annotation Hints</h2>
          <pre>{annotation_block}</pre>
        </section>
      </div>
    </section>
  </main>
</body>
</html>
"""


def main() -> None:
    args = parse_args()
    sources = ensure_files(args.sources, "source")
    targets = ensure_files(args.targets, "target")
    target_context = load_json_file(args.target_context_file) or {}
    annotation_hints = load_json_file(args.annotation_file) or {}

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = slugify(args.name)
    run_dir = Path(args.output_dir).expanduser().resolve() / f"{timestamp}-{slug}"
    source_dir = run_dir / "source"
    target_dir = run_dir / "target"

    source_paths = copy_assets(sources, source_dir)
    target_paths = copy_assets(targets, target_dir)

    prompt_text = render_prompt(
        source_count=len(source_paths),
        target_count=len(target_paths),
        task_intent=args.intent,
        target_context=target_context,
        annotation_hints=annotation_hints,
    )

    run_record = {
        "name": args.name,
        "slug": slug,
        "created_at": dt.datetime.now().isoformat(timespec="seconds"),
        "task_intent": args.intent,
        "notes": args.notes,
        "source_images": source_paths,
        "target_images": target_paths,
        "target_context": target_context,
        "annotation_hints": annotation_hints,
    }

    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "prompt.txt").write_text(prompt_text, encoding="utf-8")
    (run_dir / "trial.json").write_text(
        json.dumps(run_record, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    (run_dir / "trial.md").write_text(
        render_markdown(
            title=args.name,
            notes=args.notes,
            prompt_text=prompt_text,
            source_paths=source_paths,
            target_paths=target_paths,
            target_context=target_context,
            annotation_hints=annotation_hints,
        ),
        encoding="utf-8",
    )
    (run_dir / "preview.html").write_text(
        render_html(
            title=args.name,
            notes=args.notes,
            prompt_text=prompt_text,
            source_paths=source_paths,
            target_paths=target_paths,
            target_context=target_context,
            annotation_hints=annotation_hints,
        ),
        encoding="utf-8",
    )

    print(run_dir)


if __name__ == "__main__":
    main()
