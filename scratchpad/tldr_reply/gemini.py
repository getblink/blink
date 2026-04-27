from __future__ import annotations

import json
import os
import re
import time
from pathlib import Path
from typing import Any
from urllib import error, request
from uuid import uuid4

from google import genai
from google.genai import types

from scratchpad.gemini_runner import plain_data


DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.2,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "timeout_seconds": 120,
}

PROXY_URL_ENV = "BLINK_PROXY_URL"
PROXY_TOKEN_ENV = "BLINK_PROXY_TOKEN"


def create_client(api_key: str | None, settings: dict[str, Any]) -> genai.Client:
    return genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(
            timeout=int(settings["timeout_seconds"] * 1000)
        ),
    )


def _schema() -> types.Schema:
    return types.Schema(
        type=types.Type.OBJECT,
        required=["tldr", "suggestions"],
        propertyOrdering=["tldr", "suggestions"],
        properties={
            "tldr": types.Schema(
                type=types.Type.STRING,
                maxLength=180,
                description="One-sentence summary of the screenshot.",
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


def proxy_settings_from_env() -> dict[str, str] | None:
    proxy_url = (os.environ.get(PROXY_URL_ENV) or "").strip()
    proxy_token = (os.environ.get(PROXY_TOKEN_ENV) or "").strip()
    if not proxy_url and not proxy_token:
        return None
    if not proxy_url or not proxy_token:
        raise ValueError(
            f"Set both {PROXY_URL_ENV} and {PROXY_TOKEN_ENV}, or neither."
        )
    return {
        "url": proxy_url.rstrip("/"),
        "token": proxy_token,
    }


def _proxy_error_payload(
    message: str,
    *,
    duration_ms: int | None,
) -> dict[str, Any]:
    return {
        "status": "error",
        "tldr": "Proxy request failed.",
        "suggestions": [message],
        "raw": message,
        "usage": None,
        "duration_ms": duration_ms,
        "parse_error": None,
        "model": None,
    }


def _encode_multipart_screenshot(image_path: Path) -> tuple[bytes, str]:
    boundary = f"blink-{uuid4().hex}"
    image_bytes = image_path.read_bytes()
    parts = [
        f"--{boundary}\r\n".encode("utf-8"),
        (
            'Content-Disposition: form-data; name="screenshot"; '
            f'filename="{image_path.name}"\r\n'
        ).encode("utf-8"),
        b"Content-Type: image/png\r\n\r\n",
        image_bytes,
        b"\r\n",
        f"--{boundary}--\r\n".encode("utf-8"),
    ]
    return b"".join(parts), boundary


def _proxy_error_message(raw_body: str, fallback: str) -> str:
    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError:
        return fallback
    detail = parsed.get("detail")
    if not detail:
        return fallback
    return str(detail)


def generate_via_proxy(
    settings: dict[str, Any],
    image_path: Path,
    proxy_settings: dict[str, str],
) -> dict[str, Any]:
    body, boundary = _encode_multipart_screenshot(image_path)
    request_url = f"{proxy_settings['url']}/tldr"
    timeout_seconds = float(settings["timeout_seconds"])
    req = request.Request(
        request_url,
        data=body,
        headers={
            "Authorization": f"Bearer {proxy_settings['token']}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "application/json",
        },
        method="POST",
    )

    started = time.perf_counter()
    try:
        with request.urlopen(req, timeout=timeout_seconds) as response:
            raw_text = response.read().decode("utf-8")
    except error.HTTPError as exc:
        finished = time.perf_counter()
        raw_body = exc.read().decode("utf-8", errors="replace")
        fallback = f"Proxy returned HTTP {exc.code}."
        return _proxy_error_payload(
            _proxy_error_message(raw_body, fallback),
            duration_ms=int(round((finished - started) * 1000)),
        )
    except error.URLError as exc:
        finished = time.perf_counter()
        return _proxy_error_payload(
            f"Proxy request failed: {exc.reason}",
            duration_ms=int(round((finished - started) * 1000)),
        )

    finished = time.perf_counter()
    parsed, parse_error = _parse_json_response(raw_text)
    payload: dict[str, Any] = {
        "raw": raw_text,
        "usage": None,
        "duration_ms": int(round((finished - started) * 1000)),
        "parse_error": parse_error,
        "model": settings["model"],
    }
    if parsed is None:
        payload.update(
            {
                "status": "parse_error",
                "tldr": "Proxy returned non-JSON output.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload

    tldr, suggestions = _normalize_payload(parsed)
    duration_ms = parsed.get("duration_ms")
    model = parsed.get("model")
    if isinstance(duration_ms, int):
        payload["duration_ms"] = duration_ms
    if isinstance(model, str) and model.strip():
        payload["model"] = model.strip()
    if len(suggestions) != 3:
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": tldr or "Proxy returned an incomplete response.",
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


def generate_tldr_and_suggestions(
    client: genai.Client,
    settings: dict[str, Any],
    prompt_text: str,
    image_path: Path,
) -> dict[str, Any]:
    image_part = types.Part.from_bytes(
        data=image_path.read_bytes(),
        mime_type="image/png",
    )
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
        contents=[
            image_part,
            "Summarize this active window and propose three replies.",
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
