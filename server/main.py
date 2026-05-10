from __future__ import annotations

import atexit
import json
import logging
import os
import re
import subprocess
from datetime import datetime, timezone
from functools import lru_cache
from hashlib import sha256
from pathlib import Path
from typing import Any, Optional
from uuid import uuid4

import httpx
from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from posthog import Posthog
from pydantic import BaseModel, Field, field_validator

try:
    from . import gemini
    from .auth import (
        check_signup_rate_limit,
        client_ip_for,
        generate_device_token,
        require_bearer_token,
        token_hash_for,
    )
    from .cache import ResponseCache, ThreadCache
    from .env_loader import load_workspace_env
    from .storage import TelemetryStore
except ImportError:
    import gemini  # type: ignore[no-redef]
    from auth import (  # type: ignore[no-redef]
        check_signup_rate_limit,
        client_ip_for,
        generate_device_token,
        require_bearer_token,
        token_hash_for,
    )
    from cache import ResponseCache, ThreadCache  # type: ignore[no-redef]
    from env_loader import load_workspace_env  # type: ignore[no-redef]
    from storage import TelemetryStore  # type: ignore[no-redef]


load_workspace_env()

_posthog_api_key = os.environ.get("POSTHOG_API_KEY", "")
if _posthog_api_key:
    _posthog_client: Optional[Posthog] = Posthog(
        _posthog_api_key,
        host=os.environ.get("POSTHOG_HOST", "https://us.i.posthog.com"),
        enable_exception_autocapture=False,
    )
    atexit.register(_posthog_client.shutdown)
else:
    _posthog_client = None


def _posthog_capture(distinct_id: str, event: str, properties: Optional[dict] = None) -> None:
    if _posthog_client is None:
        return
    if properties is None:
        _posthog_client.capture(event, distinct_id=distinct_id)
    else:
        _posthog_client.capture(event, distinct_id=distinct_id, properties=properties)

MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024
MAX_SCREENSHOT_FRAMES = 8
REPO_ROOT = Path(__file__).resolve().parents[1]
PROMPT_PATH = Path(__file__).resolve().with_name("prompt.txt")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

GEMINI_UPSTREAM = "https://generativelanguage.googleapis.com"
PROXY_TIMEOUT_SECONDS = 120.0
DEFAULT_ALLOWED_MODELS = gemini.DEFAULT_SETTINGS["model"]
_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}

app = FastAPI(title="Blink Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://useblink.dev",
        "https://www.useblink.dev",
        "http://localhost:4321",
    ],
    allow_methods=["POST", "GET", "OPTIONS"],
    allow_headers=["content-type", "authorization"],
    allow_credentials=False,
)
logger = logging.getLogger("blink.tldr.server")
_DEPRECATION_WARNED: set[str] = set()
REDACTED_CONTENT_KEYS = {
    "text",
    "value",
    "selected_text",
    "nearby_relevant_text",
    "custom_reply_text",
    "chosen_text",
    "tldr",
    "previous_suggestions",
}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class BetaSignupRequest(BaseModel):
    email: str = Field(min_length=1, max_length=320)
    source: Optional[str] = Field(default=None, max_length=120)
    hp: Optional[str] = Field(default=None, max_length=500)

    @field_validator("email")
    @classmethod
    def validate_email(cls, value: str) -> str:
        candidate = value.strip()
        if len(candidate) > 320 or not EMAIL_RE.match(candidate):
            raise ValueError("invalid email")
        return value


@lru_cache(maxsize=1)
def _prompt_text() -> str:
    return PROMPT_PATH.read_text(encoding="utf-8")


@lru_cache(maxsize=1)
def _version() -> str:
    for key in ("RAILWAY_GIT_COMMIT_SHA", "SOURCE_VERSION", "GIT_COMMIT"):
        value = os.environ.get(key)
        if value:
            return value[:12]
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


@lru_cache(maxsize=1)
def _response_cache() -> ResponseCache:
    return ResponseCache.from_env()


@lru_cache(maxsize=1)
def _thread_cache() -> ThreadCache:
    return ThreadCache.from_env()


@lru_cache(maxsize=1)
def _telemetry_store() -> TelemetryStore:
    return TelemetryStore.from_env()


async def _notify_discord_signup(
    *,
    email_original: str,
    source: str | None,
    signup_id: str,
) -> None:
    webhook_url = (os.environ.get("BLINK_DISCORD_SIGNUP_WEBHOOK_URL") or "").strip()
    if not webhook_url:
        return
    payload = {
        "username": "blink-signups",
        "content": f"new beta signup: `{email_original}`",
        "embeds": [
            {
                "title": email_original,
                "color": 0x58A6FF,
                "fields": [
                    {
                        "name": "source",
                        "value": source or "—",
                        "inline": True,
                    },
                    {
                        "name": "signup_id",
                        "value": signup_id,
                        "inline": True,
                    },
                ],
            }
        ],
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(webhook_url, json=payload)
        if response.status_code >= 400:
            logger.warning(
                "beta_signup_discord_failed status=%s body=%s",
                response.status_code,
                response.text[:240],
            )
    except Exception as exc:
        logger.warning(
            "beta_signup_discord_failed error=%s",
            _sanitized_error_message(exc),
        )


def _ip_hash_for(ip: str) -> str:
    salt = (os.environ.get("BLINK_IP_HASH_SALT") or "").strip()
    if not salt:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: BLINK_IP_HASH_SALT is empty",
        )
    material = f"{salt}{ip or 'unknown'}"
    return sha256(material.encode("utf-8")).hexdigest()


def _env(name: str, deprecated: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is not None:
        return value
    if deprecated is None:
        return None
    value = os.environ.get(deprecated)
    if value is not None and deprecated not in _DEPRECATION_WARNED:
        _DEPRECATION_WARNED.add(deprecated)
        logger.warning("%s is deprecated, use %s", deprecated, name)
    return value


def _bool_env(name: str, default: bool) -> bool:
    legacy = name.replace("BLINK_", "TLDR_", 1) if name.startswith("BLINK_") else None
    raw = _env(name, legacy)
    if raw is None:
        return default
    return raw.strip().lower() not in {"", "0", "false", "no", "off"}


def _allowed_models() -> set[str]:
    raw = (
        _env("BLINK_ALLOWED_MODELS", "TLDR_ALLOWED_MODELS")
        or DEFAULT_ALLOWED_MODELS
    ).strip()
    return {item.strip() for item in raw.split(",") if item.strip()}


def _sanitized_error_message(exc: Exception) -> str:
    message = " ".join(str(exc).split())
    if not message:
        return "Gemini upstream error"
    return message[:240]


def _content_retention_allowed(envelope: dict[str, Any]) -> bool:
    consent = envelope.get("consent")
    if not isinstance(consent, dict):
        return False
    return bool(consent.get("allow_content_retention", False))


def _log_request(
    *,
    token_id: str,
    status_name: str,
    duration_ms: Any,
    usage_tokens: Any,
) -> None:
    logger.info(
        "tldr_request token_id=%s status=%s duration_ms=%s usage_tokens=%s",
        token_id,
        status_name,
        duration_ms,
        usage_tokens,
    )


def _dict_or_none(value: Any) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _list_or_empty(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _normalize_reroll_context(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="reroll_context must be a JSON object",
        )
    source_request_id = str(value.get("source_request_id") or "").strip()
    if (
        not source_request_id
        or len(source_request_id) > 64
        or UUID_RE.fullmatch(source_request_id) is None
    ):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="reroll_context.source_request_id must be a UUID",
        )
    try:
        schema_version = int(value.get("schema_version") or 1)
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="reroll_context.schema_version must be an integer",
        ) from exc
    return {
        "schema_version": schema_version,
        "source_request_id": source_request_id,
    }


def _redacted_text_summary(value: str) -> dict[str, Any]:
    return {
        "redacted": True,
        "char_count": len(value),
        "sha256_prefix": sha256(value.encode("utf-8")).hexdigest()[:12],
    }


def _sanitize_content_payload(value: Any, *, allow_content_retention: bool) -> Any:
    if allow_content_retention:
        return value
    if isinstance(value, dict):
        sanitized: dict[str, Any] = {}
        for key, item in value.items():
            if key in REDACTED_CONTENT_KEYS and isinstance(item, str):
                sanitized[key] = _redacted_text_summary(item)
            elif key in REDACTED_CONTENT_KEYS and isinstance(item, list):
                sanitized[key] = [
                    _redacted_text_summary(str(entry))
                    if isinstance(entry, str)
                    else _sanitize_content_payload(
                        entry,
                        allow_content_retention=allow_content_retention,
                    )
                    for entry in item
                ]
            else:
                sanitized[key] = _sanitize_content_payload(
                    item,
                    allow_content_retention=allow_content_retention,
                )
        return sanitized
    if isinstance(value, list):
        return [
            _sanitize_content_payload(
                item,
                allow_content_retention=allow_content_retention,
            )
            for item in value
        ]
    return value


def _privacy_safe_envelope(envelope: dict[str, Any]) -> dict[str, Any]:
    allow_content_retention = _content_retention_allowed(envelope)
    if allow_content_retention:
        return envelope
    sanitized = dict(envelope)
    sanitized["ocr_packet"] = _sanitize_content_payload(
        envelope.get("ocr_packet"),
        allow_content_retention=allow_content_retention,
    )
    sanitized["focused_context"] = _sanitize_content_payload(
        envelope.get("focused_context"),
        allow_content_retention=allow_content_retention,
    )
    sanitized["stateful_context"] = _sanitize_content_payload(
        envelope.get("stateful_context"),
        allow_content_retention=allow_content_retention,
    )
    sanitized["reroll_context"] = _sanitize_content_payload(
        envelope.get("reroll_context"),
        allow_content_retention=allow_content_retention,
    )
    return sanitized


def _cache_allowed(envelope: dict[str, Any]) -> bool:
    return _content_retention_allowed(envelope)


def _normalize_request_envelope(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request must be a JSON object",
        )

    request_id = str(payload.get("request_id") or "").strip()
    if not request_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request_id is required",
        )

    input_mode = str(payload.get("input_mode") or "screenshot").strip().lower()
    if input_mode not in {"screenshot", "ocr", "hybrid"}:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="input_mode must be screenshot, ocr, or hybrid",
        )

    client = _dict_or_none(payload.get("client")) or {}
    install_id = str(client.get("install_id") or "").strip() or None
    consent = payload.get("consent")
    consent_dict = consent if isinstance(consent, dict) else {}
    return {
        "schema_version": int(payload.get("schema_version") or 1),
        "request_id": request_id,
        "client": client,
        "install_id": install_id,
        "capture_mode": str(payload.get("capture_mode") or "frontmost_window").strip().lower(),
        "preferences": _dict_or_none(payload.get("preferences")) or {},
        "frontmost_app": _dict_or_none(payload.get("frontmost_app")) or {},
        "input_mode": input_mode,
        "screenshot": _dict_or_none(payload.get("screenshot")),
        "frames": _list_or_empty(payload.get("frames")),
        "image_diagnostics": _dict_or_none(payload.get("image_diagnostics")),
        "ocr_packet": _dict_or_none(payload.get("ocr_packet")),
        "focused_context": _dict_or_none(payload.get("focused_context")),
        "stateful_context": _dict_or_none(payload.get("stateful_context")),
        "reroll_context": _normalize_reroll_context(payload.get("reroll_context")),
        "consent": {
            "allow_event_logging": bool(consent_dict.get("allow_event_logging", True)),
            "allow_content_retention": bool(consent_dict.get("allow_content_retention", False)),
        },
        "warnings": _list_or_empty(payload.get("warnings")),
    }


def _normalize_event_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="event body must be a JSON object",
        )
    request_id = str(payload.get("request_id") or "").strip()
    event_type = str(payload.get("event_type") or "").strip()
    if not request_id or not event_type:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request_id and event_type are required",
        )
    normalized = dict(payload)
    client = _dict_or_none(normalized.get("client")) or {}
    normalized["client"] = client
    normalized["install_id"] = str(client.get("install_id") or "").strip() or None
    return normalized


def _make_legacy_request_envelope() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "request_id": f"legacy-{uuid4().hex}",
        "client": {"mode": "legacy_upload"},
        "install_id": None,
        "capture_mode": "frontmost_window",
        "preferences": {},
        "frontmost_app": {},
        "input_mode": "screenshot",
        "screenshot": None,
        "frames": [],
        "image_diagnostics": None,
        "ocr_packet": None,
        "focused_context": None,
        "stateful_context": None,
        "reroll_context": None,
        "consent": {
            "allow_event_logging": False,
            "allow_content_retention": False,
        },
        "warnings": ["legacy_contract"],
    }


def _selected_settings(envelope: dict[str, Any], warnings: list[str]) -> dict[str, Any]:
    settings = gemini.DEFAULT_SETTINGS.copy()
    preferences = envelope.get("preferences") or {}
    requested_model = str(preferences.get("model") or "").strip()
    if requested_model:
        if requested_model in _allowed_models():
            settings["model"] = requested_model
        else:
            warnings.append("requested_model_disallowed")

    temperature = preferences.get("temperature")
    if isinstance(temperature, (int, float)):
        settings["temperature"] = float(temperature)

    max_output_tokens = preferences.get("max_output_tokens")
    if isinstance(max_output_tokens, int) and max_output_tokens > 0:
        settings["max_output_tokens"] = max_output_tokens

    thinking_level = preferences.get("thinking_level")
    if isinstance(thinking_level, str):
        candidate = thinking_level.strip().lower()
        if candidate in {"low", "medium", "high"}:
            settings["thinking_level"] = candidate
        elif candidate:
            warnings.append("requested_thinking_level_disallowed")
    return settings


def _ordered_image_hash(image_bytes_list: list[bytes]) -> str | None:
    if not image_bytes_list:
        return None
    if len(image_bytes_list) == 1:
        return sha256(image_bytes_list[0]).hexdigest()
    ordered = sha256()
    for image_bytes in image_bytes_list:
        ordered.update(sha256(image_bytes).hexdigest().encode("ascii"))
    return ordered.hexdigest()


def _request_cache_key(envelope: dict[str, Any], image_bytes_list: list[bytes]) -> str:
    material = {
        "capture_mode": envelope.get("capture_mode"),
        "input_mode": envelope.get("input_mode"),
        "preferences": envelope.get("preferences"),
        "frontmost_app": envelope.get("frontmost_app"),
        "ocr_packet": envelope.get("ocr_packet"),
        "focused_context": envelope.get("focused_context"),
        "stateful_context": envelope.get("stateful_context"),
        "reroll_context": envelope.get("reroll_context"),
        "conversation_thread": envelope.get("conversation_thread"),
    }
    image_hash = _ordered_image_hash(image_bytes_list)
    if image_hash is not None:
        material["screenshot_sha256"] = image_hash
    return sha256(
        json.dumps(material, ensure_ascii=True, sort_keys=True).encode("utf-8")
    ).hexdigest()


def _ok_response(payload: dict[str, Any], request_id: str, warnings: list[str]) -> dict[str, Any]:
    return {
        "request_id": request_id,
        "status": "ok",
        "tldr": payload["tldr"],
        "suggestions": payload["suggestions"],
        "suggestion_details": payload.get("suggestion_details")
        or [
            {"text": str(item), "tags": []}
            for item in payload.get("suggestions") or []
        ],
        "duration_ms": payload["duration_ms"],
        "model": payload["model"],
        "warnings": warnings,
    }


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _capture_thread_turn(request_id: str, image_bytes_list: list[bytes]) -> dict[str, Any]:
    turn: dict[str, Any] = {
        "role": "user",
        "kind": "capture",
        "request_id": request_id,
        "image_count": len(image_bytes_list),
    }
    image_hash = _ordered_image_hash(image_bytes_list)
    if image_hash is not None:
        turn["screenshot_sha256"] = image_hash
    return turn


def _suggestion_details_from_payload(payload: dict[str, Any]) -> list[dict[str, Any]]:
    details = payload.get("suggestion_details")
    if isinstance(details, list):
        normalized = []
        for item in details:
            if not isinstance(item, dict):
                continue
            text = str(item.get("text") or "").strip()
            if not text:
                continue
            raw_tags = item.get("tags")
            tags = [
                str(tag).strip()
                for tag in raw_tags
                if str(tag).strip()
            ][:2] if isinstance(raw_tags, list) else []
            normalized.append({"text": text, "tags": tags})
            if len(normalized) >= 3:
                break
        if normalized:
            return normalized
    return [
        {"text": str(item or "").strip(), "tags": []}
        for item in payload.get("suggestions") or []
        if str(item or "").strip()
    ][:3]


def _model_thread_turn(request_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    details = _suggestion_details_from_payload(payload)
    return {
        "role": "model",
        "kind": "response",
        "request_id": request_id,
        "tldr": str(payload.get("tldr") or ""),
        "suggestions": [item["text"] for item in details],
        "suggestion_details": details,
    }


def _reroll_thread_turn(request_id: str) -> dict[str, Any]:
    return {
        "role": "user",
        "kind": "reroll",
        "request_id": request_id,
        "text": gemini.REROLL_CONTENT_TEXT,
    }


def _new_thread(
    *,
    root_request_id: str,
    latest_request_id: str,
    turns: list[dict[str, Any]],
) -> dict[str, Any]:
    now = _now_iso()
    return {
        "schema_version": 1,
        "root_request_id": root_request_id,
        "latest_request_id": latest_request_id,
        "created_at": now,
        "updated_at": now,
        "turns": turns,
    }


def _valid_thread_turns(thread: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not isinstance(thread, dict):
        return []
    turns = thread.get("turns")
    if not isinstance(turns, list):
        return []
    return [turn for turn in turns if isinstance(turn, dict)]


def _fallback_thread_from_store(
    *,
    source_request_id: str,
    token_id: str,
    warnings: list[str],
) -> dict[str, Any] | None:
    logger.warning(
        "reroll_context_lookup_started token_id=%s source_request_id=%s",
        token_id,
        source_request_id,
    )
    try:
        previous = _telemetry_store().get_previous_response(source_request_id, token_id)
    except Exception as exc:
        logger.warning(
            "reroll_context_lookup_failed token_id=%s source_request_id=%s error=%s",
            token_id,
            source_request_id,
            _sanitized_error_message(exc),
        )
        warnings.append("reroll_context_lookup_failed")
        previous = None
    if not isinstance(previous, dict):
        logger.warning(
            "reroll_context_missing_previous token_id=%s source_request_id=%s",
            token_id,
            source_request_id,
        )
        warnings.append("reroll_context_missing_previous")
        return None
    details = _suggestion_details_from_payload(previous)
    logger.warning(
        "reroll_context_hydrated token_id=%s source_request_id=%s previous_suggestion_count=%s",
        token_id,
        source_request_id,
        len(details),
    )
    warnings.append("reroll_context_hydrated")
    return _new_thread(
        root_request_id=source_request_id,
        latest_request_id=source_request_id,
        turns=[
            {
                "role": "user",
                "kind": "capture",
                "request_id": source_request_id,
            },
            _model_thread_turn(source_request_id, previous),
        ],
    )


def _thread_context_for_request(
    *,
    envelope: dict[str, Any],
    token_id: str,
    warnings: list[str],
) -> dict[str, Any] | None:
    reroll_context = envelope.get("reroll_context")
    if not isinstance(reroll_context, dict):
        return None
    source_request_id = str(reroll_context.get("source_request_id") or "").strip()
    if not source_request_id:
        return None

    cache = _thread_cache()
    root_request_id = source_request_id
    thread: dict[str, Any] | None = None
    if cache.enabled:
        resolved_root = cache.resolve_root(
            token_id=token_id,
            request_id=source_request_id,
        )
        if resolved_root:
            root_request_id = resolved_root
        thread = cache.get_thread(
            token_id=token_id,
            root_request_id=root_request_id,
        )
        if thread is None and root_request_id != source_request_id:
            thread = cache.get_thread(
                token_id=token_id,
                root_request_id=source_request_id,
            )
            if thread is not None:
                root_request_id = source_request_id
        if thread is not None and _valid_thread_turns(thread):
            warnings.append("reroll_thread_cache_hit")
            return {
                "root_request_id": str(thread.get("root_request_id") or root_request_id),
                "source_request_id": source_request_id,
                "thread": thread,
            }
        warnings.append("reroll_thread_cache_miss")

    thread = _fallback_thread_from_store(
        source_request_id=source_request_id,
        token_id=token_id,
        warnings=warnings,
    )
    if thread is None:
        return None
    return {
        "root_request_id": source_request_id,
        "source_request_id": source_request_id,
        "thread": thread,
    }


def _conversation_turns_for_request(
    thread_context: dict[str, Any] | None,
    request_id: str,
) -> list[dict[str, Any]] | None:
    if thread_context is None:
        return None
    turns = _valid_thread_turns(thread_context.get("thread"))
    if not turns:
        return None
    return turns + [_reroll_thread_turn(request_id)]


def _store_thread_success(
    *,
    token_id: str,
    envelope: dict[str, Any],
    image_bytes_list: list[bytes],
    payload: dict[str, Any],
    thread_context: dict[str, Any] | None,
) -> None:
    cache = _thread_cache()
    if not cache.enabled:
        return
    request_id = str(envelope["request_id"])
    if thread_context is None:
        root_request_id = request_id
        thread = _new_thread(
            root_request_id=root_request_id,
            latest_request_id=request_id,
            turns=[
                _capture_thread_turn(request_id, image_bytes_list),
                _model_thread_turn(request_id, payload),
            ],
        )
    else:
        root_request_id = str(thread_context.get("root_request_id") or "").strip()
        if not root_request_id:
            root_request_id = request_id
        source_request_id = str(thread_context.get("source_request_id") or "").strip()
        original = thread_context.get("thread") if isinstance(thread_context.get("thread"), dict) else {}
        turns = _valid_thread_turns(original)
        thread = {
            "schema_version": 1,
            "root_request_id": root_request_id,
            "latest_request_id": request_id,
            "created_at": str(original.get("created_at") or _now_iso()),
            "updated_at": _now_iso(),
            "turns": turns + [
                _reroll_thread_turn(request_id),
                _model_thread_turn(request_id, payload),
            ],
        }
        if source_request_id:
            cache.set_root_alias(
                token_id=token_id,
                request_id=source_request_id,
                root_request_id=root_request_id,
            )
    cache.set_thread(
        token_id=token_id,
        root_request_id=root_request_id,
        payload=thread,
    )
    cache.set_root_alias(
        token_id=token_id,
        request_id=request_id,
        root_request_id=root_request_id,
    )


def _record_request(
    *,
    token_id: str,
    envelope: dict[str, Any],
    settings: dict[str, Any],
    status_name: str,
    latency_ms: int | None,
    usage_tokens: int | None,
    input_hash: str,
    warnings: list[str],
    error: str | None,
    summary: str | None = None,
    suggestions: list[str] | None = None,
    suggestion_details: list[dict[str, Any]] | None = None,
    raw_model_output: str | None = None,
) -> None:
    try:
        _telemetry_store().record_request(
            {
                "request_id": envelope["request_id"],
                "token_id": token_id,
                "client": envelope.get("client") or {},
                "install_id": envelope.get("install_id"),
                "capture_mode": envelope.get("capture_mode"),
                "input_mode": envelope.get("input_mode"),
                "frontmost_app": envelope.get("frontmost_app") or {},
                "screenshot": envelope.get("screenshot") or {},
                "frames": envelope.get("frames") or [],
                "image_diagnostics": envelope.get("image_diagnostics") or {},
                "ocr_packet": envelope.get("ocr_packet") or {},
                "focused_context": envelope.get("focused_context") or {},
                "stateful_context": envelope.get("stateful_context") or {},
                "reroll_context": envelope.get("reroll_context") or {},
                "consent": envelope.get("consent") or {},
                "requested_preferences": envelope.get("preferences") or {},
                "model_used": settings.get("model"),
                "status": status_name,
                "latency_ms": latency_ms,
                "usage_tokens": usage_tokens,
                "input_hash": input_hash,
                "summary": summary,
                "suggestions": suggestion_details if suggestion_details is not None else suggestions,
                "raw_model_output": raw_model_output,
                "warnings": warnings,
                "error": error,
            }
        )
    except Exception as exc:
        logger.warning(
            "tldr_request_storage_failed token_id=%s request_id=%s error=%s",
            token_id,
            envelope["request_id"],
            _sanitized_error_message(exc),
        )


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    return {"ok": True, "version": _version()}


@app.post("/v1/auth/mint")
async def mint_device_token(
    request: Request,
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any]:
    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request body must contain valid JSON",
        ) from exc
    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request body must be a JSON object",
        )
    install_id = str(payload.get("install_id") or "").strip()
    if not install_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="install_id is required",
        )
    if len(install_id) > 128:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="install_id exceeds 128 characters",
        )
    plaintext_token = generate_device_token()
    try:
        _telemetry_store().mint_device_token(
            install_id=install_id,
            token_hash=token_hash_for(plaintext_token),
        )
    except Exception as exc:
        logger.warning(
            "device_token_mint_failed bootstrap_token_id=%s install_id=%s error=%s",
            token_id,
            install_id,
            _sanitized_error_message(exc),
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="device token storage unavailable",
        ) from exc
    _posthog_capture(
        install_id,
        "device_token_minted",
    )
    return {
        "token": plaintext_token,
        "token_type": "bearer",
    }


async def _run_tldr_request(
    *,
    envelope: dict[str, Any],
    screenshots: list[UploadFile],
    token_id: str,
    stream: bool = False,
) -> dict[str, Any] | StreamingResponse:
    warnings = list(envelope.get("warnings") or [])
    images: list[tuple[bytes, str]] = []
    image_bytes_list: list[bytes] = []
    if len(screenshots) > MAX_SCREENSHOT_FRAMES:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail="too many screenshots; maximum is 8",
        )
    total_image_bytes = 0
    for screenshot in screenshots:
        image_bytes = await screenshot.read()
        total_image_bytes += len(image_bytes)
        if len(image_bytes) > MAX_SCREENSHOT_BYTES:
            _log_request(
                token_id=token_id,
                status_name="too_large",
                duration_ms=None,
                usage_tokens=None,
            )
            raise HTTPException(
                status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                detail="screenshot exceeds 10MB limit",
            )
        if total_image_bytes > MAX_SCREENSHOT_FRAMES * MAX_SCREENSHOT_BYTES:
            raise HTTPException(
                status_code=status.HTTP_413_CONTENT_TOO_LARGE,
                detail="screenshots exceed aggregate size limit",
            )
        image_bytes_list.append(image_bytes)
        images.append((image_bytes, screenshot.content_type or "image/png"))

    if not images and envelope.get("input_mode") == "screenshot":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="screenshot mode requires a screenshot upload",
        )
    if not images:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request must include a screenshot",
        )

    model_envelope = dict(envelope)
    reroll_context = envelope.get("reroll_context")
    if isinstance(reroll_context, dict):
        logger.warning(
            "reroll_request_received token_id=%s request_id=%s source_request_id=%s",
            token_id,
            envelope.get("request_id"),
            reroll_context.get("source_request_id"),
        )
    thread_context = _thread_context_for_request(
        envelope=envelope,
        token_id=token_id,
        warnings=warnings,
    )
    conversation_turns = _conversation_turns_for_request(
        thread_context,
        str(envelope["request_id"]),
    )
    if conversation_turns is not None:
        model_envelope["conversation_thread"] = {
            "root_request_id": thread_context.get("root_request_id") if thread_context else None,
            "turns": conversation_turns,
        }
    storage_envelope = _privacy_safe_envelope(envelope)
    settings = _selected_settings(envelope, warnings)
    distinct_id = envelope.get("install_id") or f"token:{token_id}"
    input_hash = _request_cache_key(storage_envelope, image_bytes_list)
    cache = _response_cache()
    cache_key = _request_cache_key(model_envelope, image_bytes_list) if _cache_allowed(envelope) else None
    if not stream and cache.enabled and cache_key is not None:
        cached = cache.get(cache_key)
        if cached is not None:
            cached_warnings = warnings + ["cache_hit"]
            _log_request(
                token_id=token_id,
                status_name="ok_cached",
                duration_ms=cached.get("duration_ms"),
                usage_tokens=None,
            )
            _record_request(
                token_id=token_id,
                envelope=storage_envelope,
                settings=settings,
                status_name="ok_cached",
                latency_ms=cached.get("duration_ms"),
                usage_tokens=None,
                input_hash=input_hash,
                warnings=cached_warnings,
                error=None,
                summary=str(cached.get("tldr") or ""),
                suggestions=[str(item) for item in cached.get("suggestions") or []],
                suggestion_details=(
                    cached.get("suggestion_details")
                    if isinstance(cached.get("suggestion_details"), list)
                    else None
                ),
            )
            _posthog_capture(
                distinct_id,
                "tldr_request_completed",
                properties={
                    "input_mode": envelope.get("input_mode"),
                    "capture_mode": envelope.get("capture_mode"),
                    "model": cached.get("model"),
                    "latency_ms": cached.get("duration_ms"),
                    "cache_hit": True,
                },
            )
            _store_thread_success(
                token_id=token_id,
                envelope=envelope,
                image_bytes_list=image_bytes_list,
                payload=cached,
                thread_context=thread_context,
            )
            return _ok_response(cached, envelope["request_id"], cached_warnings)

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: GEMINI_API_KEY is empty",
        )

    client = gemini.create_client(api_key, settings)
    prompt_text = gemini.prompt_with_context(
        _prompt_text(),
        model_envelope.get("stateful_context"),
        None if conversation_turns is not None else model_envelope.get("reroll_context"),
    )
    if stream:
        def stream_events() -> Any:
            try:
                for event in gemini.generate_tldr_and_suggestions_streaming(
                    client=client,
                    settings=settings,
                    prompt_text=prompt_text,
                    images=images,
                    conversation_turns=conversation_turns,
                ):
                    event_name = str(event.get("event") or "message")
                    data = event.get("data") if isinstance(event.get("data"), dict) else {}
                    if event_name == "final":
                        if data.get("status") == "ok":
                            usage_tokens = gemini.usage_token_count(data.get("usage"))
                            _log_request(
                                token_id=token_id,
                                status_name="ok",
                                duration_ms=data.get("duration_ms"),
                                usage_tokens=usage_tokens,
                            )
                            _record_request(
                                token_id=token_id,
                                envelope=storage_envelope,
                                settings=settings,
                                status_name="ok",
                                latency_ms=data.get("duration_ms"),
                                usage_tokens=usage_tokens,
                                input_hash=input_hash,
                                warnings=warnings,
                                error=None,
                                summary=str(data.get("tldr") or ""),
                                suggestions=[str(item) for item in data.get("suggestions") or []],
                                suggestion_details=(
                                    data.get("suggestion_details")
                                    if isinstance(data.get("suggestion_details"), list)
                                    else None
                                ),
                                raw_model_output=str(data.get("raw") or ""),
                            )
                            _posthog_capture(
                                distinct_id,
                                "tldr_request_completed",
                                properties={
                                    "input_mode": envelope.get("input_mode"),
                                    "capture_mode": envelope.get("capture_mode"),
                                    "model": data.get("model"),
                                    "latency_ms": data.get("duration_ms"),
                                    "usage_tokens": usage_tokens,
                                    "cache_hit": False,
                                },
                            )
                            _store_thread_success(
                                token_id=token_id,
                                envelope=envelope,
                                image_bytes_list=image_bytes_list,
                                payload=data,
                                thread_context=thread_context,
                            )
                            data = _ok_response(data, envelope["request_id"], warnings)
                        else:
                            # SSE intentionally returns HTTP 200 with status in the
                            # frame: HTTP headers are already flushed by the time we
                            # know the model's response was bad. The JSON path
                            # raises 503 in the same case (see below).
                            status_name = str(data.get("status") or "error")
                            detail = f"{status_name}: Gemini returned an incomplete response"
                            usage_tokens = gemini.usage_token_count(data.get("usage"))
                            _log_request(
                                token_id=token_id,
                                status_name=status_name,
                                duration_ms=data.get("duration_ms"),
                                usage_tokens=usage_tokens,
                            )
                            _record_request(
                                token_id=token_id,
                                envelope=storage_envelope,
                                settings=settings,
                                status_name=status_name,
                                latency_ms=data.get("duration_ms"),
                                usage_tokens=usage_tokens,
                                input_hash=input_hash,
                                warnings=warnings,
                                error=detail,
                                summary=str(data.get("tldr") or ""),
                                suggestions=[str(item) for item in data.get("suggestions") or []],
                                raw_model_output=str(data.get("raw") or ""),
                            )
                            _posthog_capture(
                                distinct_id,
                                "tldr_request_failed",
                                properties={
                                    "input_mode": envelope.get("input_mode"),
                                    "capture_mode": envelope.get("capture_mode"),
                                    "failure_status": status_name,
                                },
                            )
                            data = {
                                "request_id": envelope["request_id"],
                                "status": status_name,
                                "tldr": data.get("tldr"),
                                "suggestions": data.get("suggestions") or [],
                                "duration_ms": data.get("duration_ms"),
                                "model": data.get("model"),
                                "warnings": warnings,
                            }
                    yield f"event: {event_name}\ndata: {json.dumps(data, ensure_ascii=True)}\n\n"
            except Exception as exc:
                detail = f"Gemini upstream error: {_sanitized_error_message(exc)}"
                _log_request(
                    token_id=token_id,
                    status_name="upstream_error",
                    duration_ms=None,
                    usage_tokens=None,
                )
                _record_request(
                    token_id=token_id,
                    envelope=storage_envelope,
                    settings=settings,
                    status_name="upstream_error",
                    latency_ms=None,
                    usage_tokens=None,
                    input_hash=input_hash,
                    warnings=warnings,
                    error=detail,
                )
                _posthog_capture(
                    distinct_id,
                    "tldr_request_failed",
                    properties={
                        "input_mode": envelope.get("input_mode"),
                        "capture_mode": envelope.get("capture_mode"),
                        "failure_status": "upstream_error",
                    },
                )
                data = {
                    "request_id": envelope["request_id"],
                    "status": "error",
                    "detail": detail,
                    "warnings": warnings,
                }
                yield f"event: error\ndata: {json.dumps(data, ensure_ascii=True)}\n\n"

        return StreamingResponse(stream_events(), media_type="text/event-stream")

    try:
        payload = gemini.generate_tldr_and_suggestions(
            client=client,
            settings=settings,
            prompt_text=prompt_text,
            images=images,
            conversation_turns=conversation_turns,
        )
    except Exception as exc:
        detail = f"Gemini upstream error: {_sanitized_error_message(exc)}"
        _log_request(
            token_id=token_id,
            status_name="upstream_error",
            duration_ms=None,
            usage_tokens=None,
        )
        _record_request(
            token_id=token_id,
            envelope=storage_envelope,
            settings=settings,
            status_name="upstream_error",
            latency_ms=None,
            usage_tokens=None,
            input_hash=input_hash,
            warnings=warnings,
            error=detail,
        )
        _posthog_capture(
            distinct_id,
            "tldr_request_failed",
            properties={
                "input_mode": envelope.get("input_mode"),
                "capture_mode": envelope.get("capture_mode"),
                "failure_status": "upstream_error",
            },
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=detail,
        ) from exc

    usage_tokens = gemini.usage_token_count(payload.get("usage"))
    _log_request(
        token_id=token_id,
        status_name=str(payload.get("status")),
        duration_ms=payload.get("duration_ms"),
        usage_tokens=usage_tokens,
    )

    if payload.get("status") == "ok":
        if cache.enabled and cache_key is not None:
            cache.set(
                cache_key,
                {
                    "tldr": payload["tldr"],
                    "suggestions": payload["suggestions"],
                    "suggestion_details": payload.get("suggestion_details"),
                    "duration_ms": payload["duration_ms"],
                    "model": payload["model"],
                },
            )
        _record_request(
            token_id=token_id,
            envelope=storage_envelope,
            settings=settings,
            status_name="ok",
            latency_ms=payload.get("duration_ms"),
            usage_tokens=usage_tokens,
            input_hash=input_hash,
            warnings=warnings,
            error=None,
            summary=str(payload.get("tldr") or ""),
            suggestions=[str(item) for item in payload.get("suggestions") or []],
            suggestion_details=(
                payload.get("suggestion_details")
                if isinstance(payload.get("suggestion_details"), list)
                else None
            ),
            raw_model_output=str(payload.get("raw") or ""),
        )
        _posthog_capture(
            distinct_id,
            "tldr_request_completed",
            properties={
                "input_mode": envelope.get("input_mode"),
                "capture_mode": envelope.get("capture_mode"),
                "model": payload.get("model"),
                "latency_ms": payload.get("duration_ms"),
                "usage_tokens": usage_tokens,
                "cache_hit": False,
            },
        )
        _store_thread_success(
            token_id=token_id,
            envelope=envelope,
            image_bytes_list=image_bytes_list,
            payload=payload,
            thread_context=thread_context,
        )
        return _ok_response(payload, envelope["request_id"], warnings)

    if payload.get("status") == "parse_error":
        detail = "parse_error: Gemini returned non-JSON output"
        _record_request(
            token_id=token_id,
            envelope=storage_envelope,
            settings=settings,
            status_name="parse_error",
            latency_ms=payload.get("duration_ms"),
            usage_tokens=usage_tokens,
            input_hash=input_hash,
            warnings=warnings,
            error=detail,
            raw_model_output=str(payload.get("raw") or ""),
        )
        _posthog_capture(
            distinct_id,
            "tldr_request_failed",
            properties={
                "input_mode": envelope.get("input_mode"),
                "capture_mode": envelope.get("capture_mode"),
                "failure_status": "parse_error",
            },
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=detail,
        )

    detail = "schema_mismatch: Gemini returned an incomplete response"
    _record_request(
        token_id=token_id,
        envelope=storage_envelope,
        settings=settings,
        status_name="schema_mismatch",
        latency_ms=payload.get("duration_ms"),
        usage_tokens=usage_tokens,
        input_hash=input_hash,
        warnings=warnings,
        error=detail,
        summary=str(payload.get("tldr") or ""),
        suggestions=[str(item) for item in payload.get("suggestions") or []],
        raw_model_output=str(payload.get("raw") or ""),
    )
    _posthog_capture(
        distinct_id,
        "tldr_request_failed",
        properties={
            "input_mode": envelope.get("input_mode"),
            "capture_mode": envelope.get("capture_mode"),
            "failure_status": "schema_mismatch",
        },
    )
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail=detail,
    )


@app.post("/tldr")
async def tldr(
    screenshot: UploadFile = File(...),
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any]:
    payload = await _run_tldr_request(
        envelope=_make_legacy_request_envelope(),
        screenshots=[screenshot],
        token_id=token_id,
    )
    return {
        "tldr": payload["tldr"],
        "suggestions": payload["suggestions"],
        "duration_ms": payload["duration_ms"],
        "model": payload["model"],
    }


def _frame_index(field_name: str) -> int | None:
    if field_name == "screenshot":
        return 0
    raw = field_name.removeprefix("screenshot_")
    if raw == field_name or not raw.isdecimal():
        return None
    index = int(raw)
    if index < 0 or index >= MAX_SCREENSHOT_FRAMES:
        return None
    return index


@app.post("/v1/tldr", response_model=None)
async def tldr_v1(
    http_request: Request,
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any] | StreamingResponse:
    form = await http_request.form()
    request = form.get("request")
    if not isinstance(request, str):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request is required",
        )
    try:
        payload = json.loads(request)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request must contain valid JSON",
        ) from exc
    envelope = _normalize_request_envelope(payload)
    screenshots_by_index: dict[int, UploadFile] = {}
    for key, value in form.multi_items():
        if key == "screenshot" or key.startswith("screenshot_"):
            frame_index = _frame_index(key)
            if frame_index is None:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"invalid screenshot frame field: {key}",
                )
            if frame_index in screenshots_by_index:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"duplicate screenshot frame index: {frame_index}",
                )
            if isinstance(value, str):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=f"screenshot frame field must be a file: {key}",
                )
            screenshots_by_index[frame_index] = value
    wants_stream = "text/event-stream" in http_request.headers.get("accept", "")
    return await _run_tldr_request(
        envelope=envelope,
        screenshots=[
            screenshots_by_index[index]
            for index in sorted(screenshots_by_index)
        ],
        token_id=token_id,
        stream=wants_stream,
    )


@app.post("/v1/tldr/events")
async def tldr_events(
    request: Request,
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any]:
    try:
        payload = _normalize_event_payload(await request.json())
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="event body must contain valid JSON",
        ) from exc

    stored = False
    if _bool_env("BLINK_EVENT_LOGGING", True):
        try:
            stored = _telemetry_store().record_event(
                token_id=token_id,
                event_type=str(payload["event_type"]),
                payload=payload,
            )
        except Exception as exc:
            logger.warning(
                "tldr_event_storage_failed token_id=%s request_id=%s error=%s",
                token_id,
                payload["request_id"],
                _sanitized_error_message(exc),
            )
    logger.info(
        "tldr_event token_id=%s request_id=%s event_type=%s",
        token_id,
        payload["request_id"],
        payload["event_type"],
    )
    _posthog_capture(
        payload.get("install_id") or f"token:{token_id}",
        "tldr_client_event_received",
        properties={
            "event_type": str(payload["event_type"]),
            "stored": stored,
        },
    )
    return {"ok": True, "stored": stored}


@app.post("/v1/beta-signup")
async def beta_signup(
    payload: BetaSignupRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> dict[str, Any]:
    if payload.hp and payload.hp.strip():
        return {"ok": True}

    email_original = payload.email.strip()
    email_normalized = email_original.lower()
    source = payload.source.strip() if payload.source else None
    ip_hash = _ip_hash_for(client_ip_for(request))
    check_signup_rate_limit(ip_hash)

    signup_id = uuid4().hex
    try:
        inserted = _telemetry_store().record_beta_signup(
            signup_id=signup_id,
            email_normalized=email_normalized,
            email_original=email_original,
            source=source,
            user_agent=request.headers.get("user-agent"),
            ip_hash=ip_hash,
        )
    except Exception as exc:
        logger.warning(
            "beta_signup_storage_failed source=%s error=%s",
            payload.source,
            _sanitized_error_message(exc),
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="beta signup storage unavailable",
        ) from exc

    if inserted:
        _posthog_capture(
            signup_id,
            "beta_signup_recorded",
            properties={"source": source},
        )
        background_tasks.add_task(
            _notify_discord_signup,
            email_original=email_original,
            source=source,
            signup_id=signup_id,
        )
        return {"ok": True, "signup_id": signup_id, "already_signed_up": False}

    _posthog_capture(
        f"hash:{ip_hash[:16]}",
        "beta_signup_duplicate",
        properties={"source": source},
    )
    return {"ok": True, "already_signed_up": True}


async def _proxy_to_gemini(
    request: Request,
    upstream_path: str,
    token_id: str,
) -> StreamingResponse:
    real_api_key = os.environ.get("GEMINI_API_KEY")
    if not real_api_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: GEMINI_API_KEY is empty",
        )

    body = await request.body()
    target_url = f"{GEMINI_UPSTREAM}/{upstream_path}"

    forward_headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in _HOP_BY_HOP
        and key.lower() not in {"authorization", "x-goog-api-key", "cookie"}
    }
    forward_headers["x-goog-api-key"] = real_api_key

    client = httpx.AsyncClient(timeout=PROXY_TIMEOUT_SECONDS)
    upstream_request = client.build_request(
        request.method,
        target_url,
        params=request.query_params,
        content=body,
        headers=forward_headers,
    )
    try:
        upstream = await client.send(upstream_request, stream=True)
    except httpx.HTTPError as exc:
        await client.aclose()
        _log_request(
            token_id=token_id,
            status_name="proxy_upstream_error",
            duration_ms=None,
            usage_tokens=None,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Gemini upstream error: {_sanitized_error_message(exc)}",
        ) from exc

    response_headers = {
        key: value
        for key, value in upstream.headers.items()
        if key.lower() not in _HOP_BY_HOP
    }

    async def iterate() -> Any:
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    _log_request(
        token_id=token_id,
        status_name=f"proxy_{upstream.status_code}",
        duration_ms=None,
        usage_tokens=None,
    )
    return StreamingResponse(
        iterate(),
        status_code=upstream.status_code,
        headers=response_headers,
        media_type=upstream.headers.get("content-type"),
    )


@app.api_route(
    "/v1beta/{path:path}",
    methods=["GET", "POST"],
)
async def gemini_proxy(
    path: str,
    request: Request,
    token_id: str = Depends(require_bearer_token),
) -> StreamingResponse:
    return await _proxy_to_gemini(request, f"v1beta/{path}", token_id)
