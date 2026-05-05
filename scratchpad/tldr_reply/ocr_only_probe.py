"""OCR-only experiment: send the OCR packet text with no screenshot.

Tests whether dropping the image entirely changes the hallucination
behavior on the two Gemini-version-mention fixtures.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRATCHPAD_DIR = REPO_ROOT / "scratchpad"
APP_PYTHON_DIR = REPO_ROOT / "app" / "python"
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(APP_PYTHON_DIR))
sys.path.insert(0, str(SCRATCHPAD_DIR))

from env_loader import load_workspace_env  # type: ignore
from source_ocr import build_native_ocr_source_packet  # type: ignore
from google import genai  # type: ignore
from google.genai import types  # type: ignore

PROMPT_PATH = SCRATCHPAD_DIR / "tldr_reply" / "prompt.txt"
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
    system_prompt = PROMPT_PATH.read_text()
    client = genai.Client(api_key=api_key)
    fixtures_root = SCRATCHPAD_DIR / "tldr_reply" / "fixtures" / "from_runs"

    out: list[dict] = []
    for fx in FIXTURES:
        screenshot = fixtures_root / fx / "screenshot.png"
        # Build the same filtered OCR packet the sweep would use
        packet = build_native_ocr_source_packet(source_path=screenshot)
        envelope = {
            "input_mode": "tldr_reply",
            "capture_mode": "ocr_only_probe",
            "ocr_packet": {
                "status": packet.get("status"),
                "source_packet_kind": packet.get("source_packet_kind"),
                "packet_variant": packet.get("packet_variant"),
                "packet_text": packet.get("packet_text"),
                "packet_chars": packet.get("packet_chars"),
            },
        }
        context_text = json.dumps(envelope, ensure_ascii=True, sort_keys=True)
        print(f"\n=== fixture {fx} ===")
        print(f"OCR packet chars: {packet.get('packet_chars')}")
        for trial in range(1, TRIALS + 1):
            started = time.perf_counter()
            response = client.models.generate_content(
                model=MODEL,
                contents=[
                    SERVER_CONTEXT_PREFIX + "\n" + context_text,
                    SERVER_CONTENT_TEXT,
                ],
                config=types.GenerateContentConfig(
                    system_instruction=system_prompt,
                    temperature=0.2,
                    max_output_tokens=2048,
                    media_resolution="MEDIA_RESOLUTION_LOW",
                    response_mime_type="application/json",
                    thinking_config=types.ThinkingConfig(thinking_level="low"),
                ),
            )
            duration_ms = int(round((time.perf_counter() - started) * 1000))
            text = (response.text or "").strip()
            usage = getattr(response, "usage_metadata", None)
            ptok = getattr(usage, "prompt_token_count", None) if usage else None
            otok = getattr(usage, "candidates_token_count", None) if usage else None
            print(f"\n[t{trial}] {duration_ms}ms  prompt_tok={ptok}  out_tok={otok}")
            try:
                parsed = json.loads(text)
                print(f"  tldr: {parsed.get('tldr')}")
                for i, s in enumerate(parsed.get('suggestions') or [], 1):
                    print(f"  #{i}: {s}")
                out.append(
                    {
                        "fixture": fx,
                        "trial": trial,
                        "duration_ms": duration_ms,
                        "prompt_tokens": ptok,
                        "output_tokens": otok,
                        "tldr": parsed.get("tldr"),
                        "suggestions": parsed.get("suggestions"),
                        "raw": text,
                    }
                )
            except Exception as exc:
                print(f"  parse_error: {exc}")
                print(f"  raw: {text[:300]}")
                out.append(
                    {
                        "fixture": fx,
                        "trial": trial,
                        "duration_ms": duration_ms,
                        "parse_error": str(exc),
                        "raw": text,
                    }
                )

    out_path = SCRATCHPAD_DIR / "sweeps" / "tldr_halluc_fp_ocr_only" / "results.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=True))
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
