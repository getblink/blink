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

STATEFUL_CONTEXT_VERSION = 1
VOICE_SAMPLE_LIMIT = 5
SURFACE_HISTORY_LIMIT = 3
VOICE_SAMPLE_MAX_CHARS = 500
SURFACE_TEXT_MAX_CHARS = 500
STATEFUL_CONTEXT_WINDOW_SECONDS = 15 * 60

DEFAULT_PROMPT = """You are looking at a single screenshot of the user's active app. Talk to the user like a friend leaning over their shoulder. Warm, terse, direct.

Produce two things:

1. A short TL;DR addressed to the user.
2. Three concrete suggestions: candidate replies, paste-ready phrasings, or next actions the user might send, paste, or do.

TL;DR rules, in priority order (rule 1 beats rule 2 beats rule 3, etc.):

1. Don't invent. Only assert what is visible on screen. When the screen is dense or ambiguous, hedge: "Looks like...", "Probably...", "Sounds like...". Never overclaim.

2. Lead with the subject of action. Never start the TL;DR with "You", "You're", "You've", or "Your". Open with the person, system, document, number, or event driving the takeaway. The user can still be addressed as "you" later in the line.
   - Bad: "You're looking at a Slack thread with Sarah."
   - Bad: "You have an invoice due Friday."
   - Bad: "Your migration estimate is due."
     Good: "Joe's asking if you want dinner tonight; he's flexible on time."
     Good: "The agent just finished the UI refactor. 3 tests are still red."
     Good: "Sarah needs your migration estimate before her 4pm sync."
     Good: "$1,247 Stripe invoice due Mar 15."

3. Quote concrete, load-bearing details. Names, numbers, dates, deadlines, doc titles, dollar amounts, error messages. Specificity beats summary.

4. Never use em dashes ("—") or en dashes ("–"). Use a period, comma, semicolon, or a new line instead.
   - Bad: "Sarah's waiting on your estimate — she needs it before 4pm."
   - Bad: "$1,247 invoice due Mar 15 – card on file expired."
     Good: "Sarah's waiting on your estimate. She needs it before 4pm."
     Good: "$1,247 invoice due Mar 15. Card on file expired last week."

5. Surface the CTA, blocker, deadline, owner, or decision the user is on the hook for. When timestamps are visible, weight recent messages and approaching deadlines as the most likely takeaway.

6. Skip facts the user already knows from being on the screen: app name, current channel, who they're chatting with. Only surface what changes their next decision. If there is no actionable thing on screen, lead with the most concrete detail visible (a number, a deadline, a name, an unread count).

7. If something on screen is clearly inconsistent or worth a sanity check, add a brief "Heads up, ..." clause on its own line, after a blank line. Only when the evidence is visible. Never invent one. Cases that warrant one:
   - A date in a draft contradicts a date earlier in the thread.
   - A name in a draft doesn't match the recipient.
   - Two numbers that should match (subtotal vs line items, two prices, two timestamps) don't.
   - A draft contains a fact the source doesn't support.
   - A deadline conflicts with a commitment elsewhere on screen.
   - A typo or wrong recipient in a draft about to be sent.

8. Friend voice, not press release. Everyday words. Contractions are fine. Avoid corporate filler like "action items", "circle back", "looping in", "just wanted to", "kindly", "as per", "FYI".

9. When referring to the user, use direct second person ("you", "your"). Never "the user", "I see that", "this screen shows", "I can see". (See rule 2 for the one constraint: don't *lead* with "You".)

10. Length and shape. 360 characters or fewer total. 3 sentences or fewer per paragraph. Line breaks are good for separating the takeaway from a "Heads up, ..." clause. No bullets, no numbered lists in the output itself.

Suggestion rules, in priority order:

1. Produce exactly three suggestions. Each must be ready to paste or send as-is.

2. Don't invent private facts or commitments not supported by the screenshot.

3. Make each suggestion specific to the visible names, question, plan, bug, document, or request. Avoid generic filler like "Got it, thanks" unless the screenshot truly calls only for a brief acknowledgement.

4. Continue drafts; don't rewrite them. Look for any visible compose box, draft text, selected text, or caret context.
   - If the user has already started typing, suggestions are paste-at-caret continuations or completions, not rewrites that duplicate the existing draft.
   - If the draft ends mid-sentence, continue it naturally.
   - If the draft is already a full sentence, suggest text that could follow it.

5. Make the three suggestions meaningfully different:
   - one concise, direct reply,
   - one warmer or more collaborative reply,
   - one that asks a useful clarifying question or proposes a next step.

6. Match the user's register. Study any of the user's own prior messages visible in the screenshot, and match their length, punctuation, casing habits, and emoji/no-emoji style. If their style isn't visible, default to neutral-friendly.

7. Never use em dashes ("—") or en dashes ("–") in any suggestion. Substitute a period, comma, semicolon, or new line.
   - Bad: "Sounds good — I'll send the doc by EOD."
     Good: "Sounds good. I'll send the doc by EOD."

8. If the screen has no message to reply to, treat suggestions as next actions or paste-ready phrasings appropriate to the surface: a code-review comment, a meeting-decline reason, a draft email, a search query, a commit message.

9. Don't mention that you saw a screenshot.

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


def _bounded_text(value: Any, limit: int) -> str | None:
    text = str(value or "").strip()
    if not text:
        return None
    return text[:limit]


def _parse_iso(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _run_sort_time(run_dir: Path, run_log: dict[str, Any]) -> datetime:
    for key in ("chosen_at", "custom_reply_at", "finished_at", "started_at"):
        parsed = _parse_iso(run_log.get(key))
        if parsed is not None:
            return parsed
    try:
        return datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc)
    except OSError:
        return datetime.fromtimestamp(0, tz=timezone.utc)


def _load_run_pair(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any]] | None:
    run_path = run_dir / "run.json"
    request_path = run_dir / "request.json"
    if not run_path.exists():
        return None
    try:
        run_log = json.loads(run_path.read_text(encoding="utf-8"))
        request_log = (
            json.loads(request_path.read_text(encoding="utf-8"))
            if request_path.exists()
            else {}
        )
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(run_log, dict):
        return None
    if not isinstance(request_log, dict):
        request_log = {}
    return run_log, request_log


def _surface_key(envelope: dict[str, Any]) -> tuple[str | None, str | None]:
    frontmost = envelope.get("frontmost_app")
    if not isinstance(frontmost, dict):
        frontmost = {}
    focused = envelope.get("focused_context")
    if not isinstance(focused, dict):
        focused = {}
    bundle_id = _bounded_text(
        frontmost.get("bundle_id") or focused.get("bundle_id"),
        160,
    )
    title = _bounded_text(focused.get("title"), 160)
    return bundle_id, title


def _same_surface(current: dict[str, Any], previous: dict[str, Any]) -> bool:
    current_bundle, current_title = _surface_key(current)
    previous_bundle, previous_title = _surface_key(previous)
    if not current_bundle or current_bundle != previous_bundle:
        return False
    # The POC intentionally avoids app-wide "memory" when no focused title is
    # available; same-app-only history gets noisy fast.
    return bool(current_title and previous_title and current_title == previous_title)


def build_stateful_context(
    runs_dir: Path,
    current_envelope: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any] | None:
    if not runs_dir.exists():
        return None
    now = now or datetime.now(timezone.utc)
    run_pairs: list[tuple[Path, dict[str, Any], dict[str, Any], datetime]] = []
    for run_dir in runs_dir.iterdir():
        if not run_dir.is_dir():
            continue
        pair = _load_run_pair(run_dir)
        if pair is None:
            continue
        run_log, request_log = pair
        run_pairs.append((run_dir, run_log, request_log, _run_sort_time(run_dir, run_log)))
    run_pairs.sort(key=lambda item: item[3], reverse=True)

    voice_samples: list[dict[str, Any]] = []
    seen_voice: set[str] = set()
    recent_surface_history: list[dict[str, Any]] = []

    for run_dir, run_log, request_log, sort_time in run_pairs:
        custom_text = _bounded_text(run_log.get("custom_reply_text"), VOICE_SAMPLE_MAX_CHARS)
        if custom_text and custom_text not in seen_voice and len(voice_samples) < VOICE_SAMPLE_LIMIT:
            frontmost = request_log.get("frontmost_app")
            if not isinstance(frontmost, dict):
                frontmost = {}
            voice_samples.append(
                {
                    "text": custom_text,
                    "created_at": run_log.get("custom_reply_at") or run_log.get("chosen_at") or run_log.get("finished_at"),
                    "app_bundle_id": frontmost.get("bundle_id"),
                    "app_name": frontmost.get("app_name"),
                }
            )
            seen_voice.add(custom_text)

        if len(recent_surface_history) < SURFACE_HISTORY_LIMIT and _same_surface(current_envelope, request_log):
            age_seconds = (now - sort_time).total_seconds()
            if 0 <= age_seconds <= STATEFUL_CONTEXT_WINDOW_SECONDS:
                response = run_log.get("response") if isinstance(run_log.get("response"), dict) else {}
                history_item = {
                    "created_at": run_log.get("finished_at") or run_log.get("started_at"),
                    "tldr": _bounded_text(response.get("tldr"), SURFACE_TEXT_MAX_CHARS),
                    "chosen_action": run_log.get("chosen_action"),
                    "chosen_index": run_log.get("chosen_index"),
                    "custom_reply_text": _bounded_text(run_log.get("custom_reply_text"), SURFACE_TEXT_MAX_CHARS),
                    "chosen_text": _bounded_text(run_log.get("chosen_text"), SURFACE_TEXT_MAX_CHARS),
                    "run_dir": run_dir.name,
                }
                history_item = {key: value for key, value in history_item.items() if value not in (None, "", [])}
                if len(history_item) > 2:
                    recent_surface_history.append(history_item)

        if len(voice_samples) >= VOICE_SAMPLE_LIMIT and len(recent_surface_history) >= SURFACE_HISTORY_LIMIT:
            break

    if not voice_samples and not recent_surface_history:
        return None
    return {
        "schema_version": STATEFUL_CONTEXT_VERSION,
        "voice_samples": voice_samples,
        "recent_surface_history": recent_surface_history,
    }


def prompt_with_stateful_context(prompt_text: str, stateful_context: dict[str, Any] | None) -> str:
    if not stateful_context:
        return prompt_text
    voice_samples = stateful_context.get("voice_samples")
    surface_history = stateful_context.get("recent_surface_history")
    if not isinstance(voice_samples, list):
        voice_samples = []
    if not isinstance(surface_history, list):
        surface_history = []
    if not voice_samples and not surface_history:
        return prompt_text
    lines = [
        "",
        "Stateful TLDR context:",
        "Use user voice examples for style only. Do not copy facts from them into the current reply unless the current screen supports those facts.",
        "Use recent same-surface history only for continuity in this immediate thread. Current screen evidence wins.",
    ]
    if voice_samples:
        lines.append("User voice examples:")
        for sample in voice_samples:
            if not isinstance(sample, dict):
                continue
            text = _bounded_text(sample.get("text"), VOICE_SAMPLE_MAX_CHARS)
            if text:
                lines.append(f"- {text}")
    if surface_history:
        lines.append("Recent same-surface history:")
        for item in surface_history:
            if not isinstance(item, dict):
                continue
            tldr = _bounded_text(item.get("tldr"), SURFACE_TEXT_MAX_CHARS)
            reply = _bounded_text(item.get("custom_reply_text") or item.get("chosen_text"), SURFACE_TEXT_MAX_CHARS)
            if tldr:
                lines.append(f"- Prior TLDR: {tldr}")
            if reply:
                lines.append(f"  Prior outcome: {reply}")
    return prompt_text.rstrip() + "\n" + "\n".join(lines) + "\n"


def response_schema():
    from google.genai import types

    return types.Schema(
        type=types.Type.OBJECT,
        required=["tldr", "suggestions"],
        propertyOrdering=["tldr", "suggestions"],
        properties={
            "tldr": types.Schema(type=types.Type.STRING, maxLength=360),
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
    stateful_context = build_stateful_context(args.out_dir, request_payload)
    if stateful_context is not None:
        request_payload["stateful_context"] = stateful_context
        prompt_text = prompt_with_stateful_context(prompt_text, stateful_context)
    proxy_settings = proxy_settings_from_env()

    run_dir = args.out_dir / bundle_id()
    run_dir.mkdir(parents=True, exist_ok=False)
    stderr_log = run_dir / "stderr.log"
    stderr_log.write_text("", encoding="utf-8")
    screenshot_out = run_dir / "screenshot.png"
    shutil.copy2(args.screenshot, screenshot_out)
    save_json(run_dir / "request.json", request_payload)

    host_profile = {}
    if args.host_profile and args.host_profile.exists():
        try:
            host_profile = json.loads(args.host_profile.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            host_profile = {"host_profile_error": "invalid_json"}

    run_log: dict[str, Any] = {
        "status": "started",
        "started_at": now_iso(),
        "request_id": request_payload.get("request_id"),
        "client": request_payload.get("client") or {},
        "runtime": runtime,
        "settings": settings,
        "stateful_context": {
            "voice_sample_count": len(stateful_context.get("voice_samples", [])) if stateful_context else 0,
            "recent_surface_history_count": len(stateful_context.get("recent_surface_history", [])) if stateful_context else 0,
        },
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
