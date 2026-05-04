from __future__ import annotations

# Forked from scratchpad/tldr_reply/gemini.py @ 3f7352ae6c27b8099fe000d7a64a0b02b6f0f209

import json
import re
import time
from pathlib import Path
from typing import Any

DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.2,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "timeout_seconds": 120,
}


def plain_data(value: Any) -> Any:
    if value is None:
        return None
    if hasattr(value, "model_dump"):
        return value.model_dump(exclude_none=True)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(key): plain_data(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain_data(item) for item in value]
    if isinstance(value, (str, int, float, bool)):
        return value
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            break
    else:
        return str(value)

    payload: dict[str, Any] = {}
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            payload[attr] = float(getattr(value, attr))
    return payload


def create_client(api_key: str | None, settings: dict[str, Any]) -> Any:
    from google import genai
    from google.genai import types

    return genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(
            timeout=int(settings["timeout_seconds"] * 1000)
        ),
    )


def _schema() -> types.Schema:
    from google.genai import types

    return types.Schema(
        type=types.Type.OBJECT,
        required=["tldr", "suggestions"],
        propertyOrdering=["tldr", "suggestions"],
        properties={
            "tldr": types.Schema(
                type=types.Type.STRING,
                maxLength=360,
                description="Short takeaway summary of the screenshot.",
            ),
            "suggestions": types.Schema(
                type=types.Type.ARRAY,
                minItems=3,
                maxItems=3,
                items=types.Schema(
                    type=types.Type.STRING,
                    description="A candidate reply the user might send next.",
                ),
            ),
        },
    )


def _parse_json_response(raw_text: str) -> tuple[dict[str, Any] | None, str | None]:
    try:
        parsed = json.loads(raw_text)
        return parsed, None
    except json.JSONDecodeError as first_error:
        match = re.search(r"\{.*\}", raw_text, flags=re.DOTALL)
        if not match:
            return None, str(first_error)
        try:
            return json.loads(match.group(0)), None
        except json.JSONDecodeError as second_error:
            return None, str(second_error)


def _normalize_payload(parsed: dict[str, Any]) -> tuple[str, list[str]]:
    tldr = str(parsed.get("tldr") or "").strip()
    raw_suggestions = parsed.get("suggestions")
    if not isinstance(raw_suggestions, list):
        raw_suggestions = []
    suggestions = [str(item).strip() for item in raw_suggestions if str(item).strip()]
    return tldr, suggestions[:3]


def usage_token_count(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    for key in ("total_token_count", "total_tokens", "totalTokenCount"):
        value = usage.get(key)
        if isinstance(value, int):
            return value
    return None


def request_context_text(envelope: dict[str, Any]) -> str | None:
    structured: dict[str, Any] = {
        "input_mode": envelope.get("input_mode"),
        "capture_mode": envelope.get("capture_mode"),
    }
    for key in ("frontmost_app", "image_diagnostics", "ocr_packet", "focused_context", "stateful_context"):
        value = envelope.get(key)
        if value not in (None, {}, [], ""):
            structured[key] = value
    if len(structured) <= 2:
        return None
    return json.dumps(structured, ensure_ascii=True, sort_keys=True)


def generate_tldr_and_suggestions(
    client: Any,
    settings: dict[str, Any],
    prompt_text: str,
    image_bytes: bytes | None,
    mime_type: str = "image/png",
    context_text: str | None = None,
) -> dict[str, Any]:
    from google.genai import types

    contents: list[Any] = []
    if context_text:
        contents.append(
            "Structured capture context (JSON). Treat it as additional evidence; "
            "do not repeat it verbatim in the output. If stateful_context is "
            "present, use voice_samples only as examples of the user's writing "
            "style, and use recent_surface_history only for continuity in this "
            "same immediate surface. Current screen evidence wins; never import "
            "unsupported facts from history.\n"
            + context_text
        )
    if image_bytes is not None:
        contents.append(
            types.Part.from_bytes(
                data=image_bytes,
                mime_type=mime_type,
            )
        )
    if not contents:
        raise ValueError("No screenshot or structured context was provided.")

    config = types.GenerateContentConfig(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=settings["max_output_tokens"],
        media_resolution=settings["media_resolution"],
        response_mime_type="application/json",
        response_schema=_schema(),
    )

    started = time.perf_counter()
    response = client.models.generate_content(
        model=settings["model"],
        contents=contents + [
            "Summarize this active window and propose three replies. Use any "
            "structured capture context if it is present."
        ],
        config=config,
    )
    finished = time.perf_counter()

    raw_text = (response.text or "").strip()
    parsed, parse_error = _parse_json_response(raw_text)
    usage = plain_data(getattr(response, "usage_metadata", None))
    payload: dict[str, Any] = {
        "raw": raw_text,
        "usage": usage,
        "duration_ms": int(round((finished - started) * 1000)),
        "parse_error": parse_error,
        "model": settings["model"],
    }
    if parsed is None:
        payload.update(
            {
                "status": "parse_error",
                "tldr": "Gemini returned non-JSON output.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload

    tldr, suggestions = _normalize_payload(parsed)
    if len(suggestions) != 3:
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": tldr or "Gemini returned an incomplete response.",
                "suggestions": suggestions or [raw_text or "[empty response]"],
            }
        )
        return payload

    payload.update(
        {
            "status": "ok",
            "tldr": tldr,
            "suggestions": suggestions,
        }
    )
    return payload
