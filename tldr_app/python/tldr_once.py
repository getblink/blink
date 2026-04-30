#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import traceback
from urllib import error, request
from uuid import uuid4
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from env_loader import load_runtime_env


DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.2,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "timeout_seconds": 120,
}

PROXY_URL_ENV = "BLINK_PROXY_URL"
PROXY_TOKEN_ENV = "BLINK_PROXY_TOKEN"

DEFAULT_PROMPT = """You are looking at a single screenshot of the user's active app.

Your job is to produce two things:

1. A one-sentence TL;DR addressed directly to the user.
2. Three concrete candidate replies the user might send next.

TL;DR rules:

- Keep it to one sentence.
- Keep it under 140 characters.
- Use second person: "You're...", "You need...", or "This asks you to...".
- Summarize the user's immediate situation, not the entire app.
- Do not say "the user".
- If no conversation or reply context is visible, say what the user is looking at and that there is no clear reply target.

Reply suggestion rules:

- Produce exactly three suggestions.
- Each suggestion should be ready to paste as-is.
- Make each suggestion specific to the visible names, question, plan, bug, document, or request.
- Avoid generic filler like "Got it, thanks" unless the screenshot truly calls only for a brief acknowledgement.
- Study any of the user's own prior messages visible in the screenshot.
- Match the user's register, length, punctuation, casing habits, and emoji/no-emoji style when there is enough evidence.
- If the user's own style is not visible, default to neutral-friendly.
- Look for any visible compose box, draft text, selected text, or caret context.
- If the user has already started typing a draft, suggestions should be paste-at-caret continuations or completions, not rewrites that duplicate the existing draft.
- If the draft ends mid-sentence, continue it naturally.
- If the draft is already a full sentence, suggest text that could follow it.
- Make the three suggestions meaningfully different:
  - one concise direct reply,
  - one warmer or more collaborative reply,
  - one reply that asks a useful clarifying question or proposes a next step.
- Do not invent private facts or commitments that are not supported by the screenshot.
- Do not mention that you saw a screenshot.

Output JSON only:

{"tldr": "...", "suggestions": ["...", "...", "..."]}
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def bundle_id() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S-") + f"{datetime.now().microsecond // 1000:03d}"


def plain_data(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if hasattr(value, "model_dump"):
        return plain_data(value.model_dump(exclude_none=True))
    if isinstance(value, dict):
        return {str(key): plain_data(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain_data(item) for item in value]
    return str(value)


def save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def load_json(path: Path | None, fallback: dict[str, Any]) -> dict[str, Any]:
    if path is None or not path.exists():
        return dict(fallback)
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    result = dict(fallback)
    for key in fallback:
        if key in payload:
            result[key] = payload[key]
    return result


def load_json_object(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def read_text(path: Path | None, fallback: str) -> str:
    if path is None or not path.exists():
        return fallback
    return path.read_text(encoding="utf-8")


def response_schema():
    from google.genai import types

    return types.Schema(
        type=types.Type.OBJECT,
        required=["tldr", "suggestions"],
        propertyOrdering=["tldr", "suggestions"],
        properties={
            "tldr": types.Schema(type=types.Type.STRING, maxLength=180),
            "suggestions": types.Schema(
                type=types.Type.ARRAY,
                minItems=3,
                maxItems=3,
                items=types.Schema(type=types.Type.STRING),
            ),
        },
    )


def parse_json_response(raw_text: str) -> tuple[Any | None, str | None]:
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


def normalize_payload(parsed: dict[str, Any]) -> tuple[str, list[str]]:
    tldr = str(parsed.get("tldr") or "").strip()
    raw_suggestions = parsed.get("suggestions")
    if not isinstance(raw_suggestions, list):
        raw_suggestions = []
    suggestions = [str(item).strip() for item in raw_suggestions if str(item).strip()]
    return tldr, suggestions[:3]


def build_response_payload(
    raw_text: str,
    usage: Any,
    duration_ms: int,
) -> dict[str, Any]:
    parsed, parse_error = parse_json_response(raw_text)
    payload: dict[str, Any] = {
        "raw": raw_text,
        "usage": plain_data(usage),
        "duration_ms": duration_ms,
        "parse_error": parse_error,
        "warnings": [],
        "request_id": None,
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
    if not isinstance(parsed, dict):
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": "Gemini returned an unexpected JSON shape.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload
    tldr, suggestions = normalize_payload(parsed)
    if len(suggestions) != 3:
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": tldr or "Gemini returned an incomplete response.",
                "suggestions": suggestions or [raw_text or "[empty response]"],
            }
        )
        return payload
    payload.update({"status": "ok", "tldr": tldr, "suggestions": suggestions})
    return payload


def proxy_settings_from_env() -> dict[str, str] | None:
    proxy_url = (os.environ.get(PROXY_URL_ENV) or "").strip()
    proxy_token = (os.environ.get(PROXY_TOKEN_ENV) or "").strip()
    if not proxy_url and not proxy_token:
        return None
    if not proxy_url or not proxy_token:
        raise ValueError(f"Set both {PROXY_URL_ENV} and {PROXY_TOKEN_ENV}, or neither.")
    return {
        "url": proxy_url.rstrip("/"),
        "token": proxy_token,
    }


def _proxy_error_payload(message: str, *, duration_ms: int | None) -> dict[str, Any]:
    return {
        "status": "error",
        "tldr": "Proxy request failed.",
        "suggestions": [message],
        "raw": message,
        "usage": None,
        "duration_ms": duration_ms,
        "parse_error": None,
        "warnings": [],
        "request_id": None,
        "model": None,
    }


def _proxy_error_message(raw_body: str, fallback: str) -> str:
    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError:
        return fallback
    detail = parsed.get("detail")
    if not detail:
        return fallback
    return str(detail)


def _encode_multipart_request(
    request_payload: dict[str, Any],
    image_path: Path | None,
) -> tuple[bytes, str]:
    boundary = f"tldr-{uuid4().hex}"
    request_json = json.dumps(request_payload, ensure_ascii=True, sort_keys=True).encode("utf-8")
    parts: list[bytes] = [
        f"--{boundary}\r\n".encode("utf-8"),
        b'Content-Disposition: form-data; name="request"\r\n',
        b"Content-Type: application/json\r\n\r\n",
        request_json,
        b"\r\n",
    ]
    if image_path is not None:
        parts.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                (
                    'Content-Disposition: form-data; name="screenshot"; '
                    f'filename="{image_path.name}"\r\n'
                ).encode("utf-8"),
                b"Content-Type: image/png\r\n\r\n",
                image_path.read_bytes(),
                b"\r\n",
            ]
        )
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(parts), boundary


def generate_via_proxy(
    request_payload: dict[str, Any],
    settings: dict[str, Any],
    proxy_settings: dict[str, str],
    image_path: Path | None,
) -> dict[str, Any]:
    body, boundary = _encode_multipart_request(request_payload, image_path)
    timeout_seconds = float(settings["timeout_seconds"])
    req = request.Request(
        f"{proxy_settings['url']}/v1/tldr",
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
    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError:
        return _proxy_error_payload(
            "Proxy returned non-JSON output.",
            duration_ms=int(round((finished - started) * 1000)),
        )
    if not isinstance(parsed, dict):
        return _proxy_error_payload(
            "Proxy returned an unexpected response.",
            duration_ms=int(round((finished - started) * 1000)),
        )

    payload: dict[str, Any] = {
        "status": str(parsed.get("status") or "error"),
        "tldr": str(parsed.get("tldr") or ""),
        "suggestions": [str(item) for item in parsed.get("suggestions") or [] if str(item).strip()],
        "raw": raw_text,
        "usage": None,
        "duration_ms": int(parsed.get("duration_ms") or round((finished - started) * 1000)),
        "parse_error": None,
        "warnings": parsed.get("warnings") if isinstance(parsed.get("warnings"), list) else [],
        "request_id": parsed.get("request_id"),
        "model": parsed.get("model"),
    }
    return payload


def generate(
    screenshot_path: Path,
    prompt_text: str,
    settings: dict[str, Any],
) -> dict[str, Any]:
    from google import genai
    from google.genai import types

    client = genai.Client(
        api_key=os.environ.get("GEMINI_API_KEY"),
        http_options=types.HttpOptions(timeout=int(settings["timeout_seconds"] * 1000)),
    )
    image_part = types.Part.from_bytes(
        data=screenshot_path.read_bytes(),
        mime_type="image/png",
    )
    config = types.GenerateContentConfig(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=settings["max_output_tokens"],
        media_resolution=settings["media_resolution"],
        response_mime_type="application/json",
        response_schema=response_schema(),
    )
    started = time.perf_counter()
    response = client.models.generate_content(
        model=settings["model"],
        contents=[image_part, "Summarize this active window and propose three replies."],
        config=config,
    )
    duration_ms = int(round((time.perf_counter() - started) * 1000))
    raw_text = (response.text or "").strip()
    return build_response_payload(
        raw_text=raw_text,
        usage=getattr(response, "usage_metadata", None),
        duration_ms=duration_ms,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run one TLDR screenshot request.")
    parser.add_argument("--screenshot", type=Path, required=True)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--settings", type=Path)
    parser.add_argument("--prompt", type=Path)
    parser.add_argument("--host-profile", type=Path)
    parser.add_argument("--request-json", type=Path)
    parser.add_argument("--skip-gemini", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    load_runtime_env()
    settings = load_json(args.settings, DEFAULT_SETTINGS)
    runtime = load_json(args.runtime, {"version": 1, "auto_paste": True, "model": settings["model"]})
    if runtime.get("model"):
        settings["model"] = runtime["model"]
    prompt_text = read_text(args.prompt, DEFAULT_PROMPT)
    request_payload = load_json_object(args.request_json) or {
        "request_id": None,
        "schema_version": 1,
        "input_mode": "screenshot",
    }
    proxy_settings = proxy_settings_from_env()

    run_dir = args.out_dir / bundle_id()
    run_dir.mkdir(parents=True, exist_ok=False)
    stderr_log = run_dir / "stderr.log"
    stderr_log.write_text("", encoding="utf-8")
    screenshot_out = run_dir / "screenshot.png"
    shutil.copy2(args.screenshot, screenshot_out)
    if args.request_json and args.request_json.exists():
        shutil.copy2(args.request_json, run_dir / "request.json")

    host_profile = {}
    if args.host_profile and args.host_profile.exists():
        try:
            host_profile = json.loads(args.host_profile.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            host_profile = {"host_profile_error": "invalid_json"}

    run_log: dict[str, Any] = {
        "status": "started",
        "started_at": now_iso(),
        "runtime": runtime,
        "settings": settings,
        "screenshot": {"path": "screenshot.png", "bytes": screenshot_out.stat().st_size},
    }
    save_json(run_dir / "host_profile.json", host_profile)

    try:
        if args.skip_gemini:
            response = {
                "status": "ok",
                "tldr": "You're testing the packaged TLDR app.",
                "suggestions": [
                    "This looks good to me.",
                    "Nice, the packaged TLDR flow is working.",
                    "Let's try it on one more real conversation.",
                ],
                "raw": "",
                "usage": None,
                "duration_ms": 0,
                "parse_error": None,
                "warnings": [],
                "request_id": request_payload.get("request_id"),
                "model": settings["model"],
            }
        else:
            if proxy_settings is not None and request_payload.get("request_id"):
                response = generate_via_proxy(
                    request_payload=request_payload,
                    settings=settings,
                    proxy_settings=proxy_settings,
                    image_path=screenshot_out,
                )
            else:
                if not os.environ.get("GEMINI_API_KEY"):
                    raise RuntimeError("Set GEMINI_API_KEY in ~/.tldr/.env or the launch environment.")
                response = generate(screenshot_out, prompt_text, settings)
                response["request_id"] = request_payload.get("request_id")
                response["warnings"] = []
                response["model"] = settings["model"]
        save_json(run_dir / "response.json", response)
        run_log.update(
            {
                "status": response["status"],
                "finished_at": now_iso(),
                "request_id": response.get("request_id"),
                "response": {
                    "tldr": response["tldr"],
                    "suggestions": response["suggestions"],
                    "duration_ms": response.get("duration_ms"),
                    "model": response.get("model"),
                    "warnings": response.get("warnings"),
                },
            }
        )
        save_json(run_dir / "run.json", run_log)
        stdout = {
            "status": response["status"],
            "bundle_dir": str(run_dir),
            "tldr": response["tldr"],
            "suggestions": response["suggestions"],
            "request_id": response.get("request_id"),
            "duration_ms": response.get("duration_ms"),
            "warnings": response.get("warnings"),
            "model": response.get("model"),
        }
        print(json.dumps(stdout, ensure_ascii=True), flush=True)
        return 0
    except Exception as exc:
        error_text = traceback.format_exc()
        stderr_log.write_text(error_text, encoding="utf-8")
        print(error_text, file=sys.stderr, end="")
        run_log.update(
            {
                "status": "error",
                "finished_at": now_iso(),
                "error": str(exc),
            }
        )
        save_json(run_dir / "run.json", run_log)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
