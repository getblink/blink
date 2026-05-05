"""Ask gemini-3-flash-preview to identify the Gemini model version in the screenshot.

Focused sub-experiment for the hallucination fixtures.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRATCHPAD_DIR = REPO_ROOT / "scratchpad"
sys.path.insert(0, str(SCRATCHPAD_DIR))

from env_loader import load_workspace_env  # type: ignore
from google import genai  # type: ignore
from google.genai import types  # type: ignore

PROMPT = (
    "Look at the screenshot. Identify EXACTLY which Gemini model version is "
    "being discussed (e.g. 'Gemini 1.5 Pro', 'Gemini 2.5 Flash', 'Gemini 3 "
    "Flash', 'Gemini 3.1 Flash-Lite'). Quote the literal text you see in the "
    "image that names the model. If multiple Gemini versions are mentioned, "
    "list every one. If you cannot read any model name, say 'unreadable'. "
    "Reply in 2-3 short sentences."
)

FIXTURES = [
    "20260504-024528-026",
    "20260504-024931-862",
]
TRIALS = 5
MODEL = "gemini-3-flash-preview"


def main() -> int:
    load_workspace_env()
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY not set", file=sys.stderr)
        return 1
    client = genai.Client(api_key=api_key)
    fixtures_root = SCRATCHPAD_DIR / "tldr_reply" / "fixtures" / "from_runs"

    out: list[dict] = []
    for fx in FIXTURES:
        image_path = fixtures_root / fx / "screenshot.png"
        image_part = types.Part.from_bytes(
            data=image_path.read_bytes(), mime_type="image/png"
        )
        for trial in range(1, TRIALS + 1):
            started = time.perf_counter()
            response = client.models.generate_content(
                model=MODEL,
                contents=[image_part, PROMPT],
                config=types.GenerateContentConfig(
                    temperature=0.2,
                    max_output_tokens=2048,
                    media_resolution="MEDIA_RESOLUTION_LOW",
                    thinking_config=types.ThinkingConfig(thinking_level="low"),
                ),
            )
            duration_ms = int(round((time.perf_counter() - started) * 1000))
            text = (response.text or "").strip()
            print(f"[{fx} t{trial}] {duration_ms}ms")
            print(f"  {text}")
            print()
            out.append(
                {
                    "fixture": fx,
                    "trial": trial,
                    "duration_ms": duration_ms,
                    "answer": text,
                    "media_resolution": "LOW",
                }
            )

    # Also try once at MEDIUM resolution per fixture as a control
    for fx in FIXTURES:
        image_path = fixtures_root / fx / "screenshot.png"
        image_part = types.Part.from_bytes(
            data=image_path.read_bytes(), mime_type="image/png"
        )
        started = time.perf_counter()
        response = client.models.generate_content(
            model=MODEL,
            contents=[image_part, PROMPT],
            config=types.GenerateContentConfig(
                temperature=0.2,
                max_output_tokens=2048,
                media_resolution="MEDIA_RESOLUTION_MEDIUM",
                thinking_config=types.ThinkingConfig(thinking_level="low"),
            ),
        )
        duration_ms = int(round((time.perf_counter() - started) * 1000))
        text = (response.text or "").strip()
        print(f"[{fx} MEDIUM] {duration_ms}ms")
        print(f"  {text}")
        print()
        out.append(
            {
                "fixture": fx,
                "trial": "medium",
                "duration_ms": duration_ms,
                "answer": text,
                "media_resolution": "MEDIUM",
            }
        )

    out_path = (
        SCRATCHPAD_DIR / "sweeps" / "tldr_halluc_fp_ask_version" / "results.json"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=True))
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
