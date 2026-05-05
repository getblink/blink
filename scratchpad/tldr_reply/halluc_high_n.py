"""High-N hallucination comparison: LOW vs MEDIUM, old vs new OCR prefix.

7 cells x N trials on fixture 20260504-024528-026 (the only one with an
explicit Gemini version mention in its chat).
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from statistics import median

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRATCHPAD_DIR = REPO_ROOT / "scratchpad"
APP_PYTHON_DIR = REPO_ROOT / "app" / "python"
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(APP_PYTHON_DIR))
sys.path.insert(0, str(SCRATCHPAD_DIR))

from env_loader import load_workspace_env  # type: ignore
from gemini_runner import prepare_request_image  # type: ignore
from source_ocr import build_native_ocr_source_packet  # type: ignore
from google import genai  # type: ignore
from google.genai import types  # type: ignore

PROMPT_PATH = SCRATCHPAD_DIR / "tldr_reply" / "prompt.txt"

OLD_PREFIX = (
    "Structured capture context (JSON). Treat it as additional evidence; "
    "do not repeat it verbatim in the output. If stateful_context is "
    "present, use preference_examples to infer which suggestions the user "
    "finds useful, use voice_samples only as examples of the user's writing "
    "style, and use recent_surface_history only for continuity in this same "
    "immediate surface. Current screen evidence wins; never import unsupported "
    "facts from history."
)

NEW_PREFIX = (
    "OCR transcription extracted from the same screenshot at full resolution "
    "and included verbatim below. Treat the OCR packet_text as the "
    "authoritative source for any text content visible in the screenshot: "
    "when the image and OCR disagree on specific text (names, numbers, "
    "version identifiers, exact phrasing), trust the OCR. Use the image only "
    "for layout, hierarchy, and visual context that OCR cannot capture. "
    "Never substitute training-data priors for OCR text. Do not repeat the "
    "OCR JSON verbatim in the output."
)

CONTENT_TEXT_WITH_CONTEXT = (
    "Summarize this active window and propose three replies. Use any "
    "structured capture context if it is present."
)
CONTENT_TEXT_PLAIN = "Summarize this active window and propose three replies."

FIXTURE = "20260504-024528-026"
TRIALS = 20
MODEL = os.environ.get("HALLUC_MODEL", "gemini-3-flash-preview")


def _is_thinking_model(name: str) -> bool:
    n = (name or "").lower()
    if not n.startswith(("gemini-3-", "gemini-3.")):
        return False
    if "flash-lite" in n:
        return False
    return True

CELLS = [
    {
        "name": "A_baseline_LOW",
        "preprocess": False,
        "include_ocr": False,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_LOW",
        "prefix": None,
    },
    {
        "name": "B_q70_d1600_LOW",
        "preprocess": True,
        "format": "jpeg",
        "max_dim": 1600,
        "jpeg_quality": 70,
        "include_ocr": False,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_LOW",
        "prefix": None,
    },
    {
        "name": "C_q70_d1600_MEDIUM",
        "preprocess": True,
        "format": "jpeg",
        "max_dim": 1600,
        "jpeg_quality": 70,
        "include_ocr": False,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_MEDIUM",
        "prefix": None,
    },
    {
        "name": "D_q60_ocr_LOW_OLD_prefix",
        "preprocess": True,
        "format": "jpeg",
        "max_dim": 1280,
        "jpeg_quality": 60,
        "include_ocr": True,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_LOW",
        "prefix": OLD_PREFIX,
    },
    {
        "name": "E_q60_ocr_LOW_NEW_prefix",
        "preprocess": True,
        "format": "jpeg",
        "max_dim": 1280,
        "jpeg_quality": 60,
        "include_ocr": True,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_LOW",
        "prefix": NEW_PREFIX,
    },
    {
        "name": "F_q60_ocr_MEDIUM_NEW_prefix",
        "preprocess": True,
        "format": "jpeg",
        "max_dim": 1280,
        "jpeg_quality": 60,
        "include_ocr": True,
        "use_image": True,
        "media_resolution": "MEDIA_RESOLUTION_MEDIUM",
        "prefix": NEW_PREFIX,
    },
    {
        "name": "G_ocr_only_NEW_prefix",
        "preprocess": False,
        "include_ocr": True,
        "use_image": False,
        "media_resolution": "MEDIA_RESOLUTION_LOW",
        "prefix": NEW_PREFIX,
    },
]


def classify(text: str) -> str:
    t = text.lower()
    if re.search(r"gemini\s*1\.5", t) or "1.5 pro" in t or "1.5 flash" in t:
        return "1.5"
    if re.search(r"gemini\s*2\.0", t):
        return "2.0"
    if re.search(r"gemini\s*2\.5", t):
        return "2.5"
    if re.search(r"gemini\s*3(?:\.\d)?\s*(?:flash|pro)", t) or "gemini 3 " in t:
        return "3.x"
    return "no-version"


def build_settings(cell: dict) -> dict:
    s: dict = {
        "temperature": 0.2,
        "max_output_tokens": 2048,
        "media_resolution": cell["media_resolution"],
        "preprocess_request_images": cell.get("preprocess", False),
        "request_image_format": cell.get("format", "png"),
        "request_image_max_dimension": cell.get("max_dim", 1600),
        "request_image_jpeg_quality": cell.get("jpeg_quality", 80),
    }
    return s


def build_contents(*, cell: dict, screenshot: Path, ocr_packet: dict | None,
                   request_image: dict | None) -> list:
    contents: list = []
    if cell.get("include_ocr") and ocr_packet:
        envelope = {
            "capture_mode": "halluc_high_n",
            "input_mode": "tldr_reply",
            "ocr_packet": {
                "status": ocr_packet.get("status"),
                "source_packet_kind": ocr_packet.get("source_packet_kind"),
                "packet_variant": ocr_packet.get("packet_variant"),
                "packet_text": ocr_packet.get("packet_text"),
                "packet_chars": ocr_packet.get("packet_chars"),
            },
        }
        context_text = json.dumps(envelope, ensure_ascii=True, sort_keys=True)
        contents.append((cell["prefix"] or OLD_PREFIX) + "\n" + context_text)
    if cell.get("use_image") and request_image:
        contents.append(
            types.Part.from_bytes(
                data=request_image["bytes_data"],
                mime_type=request_image["mime_type"],
            )
        )
    contents.append(
        CONTENT_TEXT_WITH_CONTEXT if cell.get("include_ocr") else CONTENT_TEXT_PLAIN
    )
    return contents


def main() -> int:
    load_workspace_env()
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY not set", file=sys.stderr)
        return 1
    system_prompt = PROMPT_PATH.read_text()
    client = genai.Client(api_key=api_key)
    screenshot = SCRATCHPAD_DIR / "tldr_reply" / "fixtures" / "from_runs" / FIXTURE / "screenshot.png"
    model_slug = MODEL.replace("/", "_").replace(".", "_")
    out_root = SCRATCHPAD_DIR / "sweeps" / "tldr_halluc_high_n" / model_slug
    out_root.mkdir(parents=True, exist_ok=True)
    print(f"MODEL: {MODEL}  (thinking={_is_thinking_model(MODEL)})")
    print(f"OUT  : {out_root}")

    # Build OCR packet ONCE (reused across all OCR cells)
    print("Building OCR packet...")
    ocr_t0 = time.perf_counter()
    ocr_packet = build_native_ocr_source_packet(source_path=screenshot)
    ocr_build_ms = int(round((time.perf_counter() - ocr_t0) * 1000))
    print(f"  OCR packet: {ocr_packet.get('packet_chars')} chars in {ocr_build_ms}ms")

    all_results: list[dict] = []
    for cell in CELLS:
        print(f"\n=== {cell['name']} ===")
        # Prep image once per cell (settings invariant within cell)
        if cell.get("use_image"):
            cell_dir = out_root / cell["name"]
            cell_dir.mkdir(exist_ok=True)
            request_image = prepare_request_image(
                screenshot, build_settings(cell), dest_dir=cell_dir
            )
            print(f"  image: {request_image['request_bytes']} bytes ({request_image['mime_type']})")
        else:
            request_image = None

        contents = build_contents(
            cell=cell, screenshot=screenshot,
            ocr_packet=ocr_packet, request_image=request_image,
        )
        cfg_kwargs = dict(
            system_instruction=system_prompt,
            temperature=0.2,
            max_output_tokens=2048 if _is_thinking_model(MODEL) else 1024,
            media_resolution=cell["media_resolution"],
            response_mime_type="application/json",
        )
        if _is_thinking_model(MODEL):
            cfg_kwargs["thinking_config"] = types.ThinkingConfig(thinking_level="low")
        cfg = types.GenerateContentConfig(**cfg_kwargs)

        def run_trial(trial: int) -> dict:
            started = time.perf_counter()
            try:
                response = client.models.generate_content(
                    model=MODEL, contents=contents, config=cfg,
                )
                duration_ms = int(round((time.perf_counter() - started) * 1000))
                text = (response.text or "").strip()
                usage = getattr(response, "usage_metadata", None)
                ptok = getattr(usage, "prompt_token_count", None) if usage else None
                otok = getattr(usage, "candidates_token_count", None) if usage else None
                try:
                    parsed = json.loads(text)
                    tldr = parsed.get("tldr") or ""
                    suggestions = parsed.get("suggestions") or []
                except Exception:
                    tldr = ""
                    suggestions = []
                joined = tldr + " " + " ".join(suggestions)
                cls = classify(joined)
                return {
                    "cell": cell["name"], "trial": trial, "duration_ms": duration_ms,
                    "prompt_tokens": ptok, "output_tokens": otok,
                    "tldr": tldr, "suggestions": suggestions, "classification": cls,
                }
            except Exception as exc:
                return {"cell": cell["name"], "trial": trial, "error": str(exc)}

        with ThreadPoolExecutor(max_workers=5, thread_name_prefix="halluc-trial") as ex:
            futures = {ex.submit(run_trial, t): t for t in range(1, TRIALS + 1)}
            cell_results = []
            for fut in futures:
                pass  # iterate to start
            from concurrent.futures import as_completed
            for fut in as_completed(futures):
                r = fut.result()
                cell_results.append(r)
                if "error" in r:
                    print(f"  t{r['trial']:>2}: ERROR {r['error']}")
                else:
                    marker = "⚠" if r["classification"] in ("1.5", "2.0", "2.5") else "✓"
                    print(f"  t{r['trial']:>2}: {r['duration_ms']:>5}ms  ptok={r['prompt_tokens']}  cls={r['classification']} {marker}")
            cell_results.sort(key=lambda r: r["trial"])
            all_results.extend(cell_results)

    out_path = out_root / "results.json"
    out_path.write_text(json.dumps(all_results, indent=2, ensure_ascii=True))

    # Summary
    print("\n\n=== SUMMARY ===")
    print(f"{'cell':<35} {'1.5':>4} {'3.x':>4} {'no-v':>5} {'med ms':>7} {'med ptok':>8}")
    by_cell: dict[str, list] = {}
    for r in all_results:
        if "classification" not in r: continue
        by_cell.setdefault(r["cell"], []).append(r)
    for cell in CELLS:
        rs = by_cell.get(cell["name"], [])
        c15 = sum(1 for r in rs if r["classification"] == "1.5")
        c3 = sum(1 for r in rs if r["classification"] == "3.x")
        cnv = sum(1 for r in rs if r["classification"] == "no-version")
        med_ms = int(median([r["duration_ms"] for r in rs])) if rs else 0
        med_pt = int(median([r["prompt_tokens"] for r in rs if r.get("prompt_tokens")])) if rs else 0
        print(f"{cell['name']:<35} {c15:>4} {c3:>4} {cnv:>5} {med_ms:>7} {med_pt:>8}")
    print(f"\nresults: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
