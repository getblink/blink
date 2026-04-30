from __future__ import annotations

import json
import logging
import os
import subprocess
from functools import lru_cache
from hashlib import sha256
from pathlib import Path
from typing import Any, Optional
from uuid import uuid4

import httpx
from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import StreamingResponse

try:
    from . import gemini
    from .auth import require_bearer_token
    from .cache import ResponseCache
    from .env_loader import load_workspace_env
    from .storage import TelemetryStore
except ImportError:
    import gemini  # type: ignore[no-redef]
    from auth import require_bearer_token  # type: ignore[no-redef]
    from cache import ResponseCache  # type: ignore[no-redef]
    from env_loader import load_workspace_env  # type: ignore[no-redef]
    from storage import TelemetryStore  # type: ignore[no-redef]


load_workspace_env()

MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024
REPO_ROOT = Path(__file__).resolve().parents[1]
PROMPT_PATH = Path(__file__).resolve().with_name("prompt.txt")

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

app = FastAPI(title="Blink TLDR Server")
logger = logging.getLogger("blink.tldr.server")
REDACTED_CONTENT_KEYS = {"text", "value", "selected_text", "nearby_relevant_text"}


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
def _telemetry_store() -> TelemetryStore:
    return TelemetryStore.from_env()


def _bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"", "0", "false", "no", "off"}


def _allowed_models() -> set[str]:
    raw = (os.environ.get("TLDR_ALLOWED_MODELS") or DEFAULT_ALLOWED_MODELS).strip()
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
            if isinstance(item, str) and key in REDACTED_CONTENT_KEYS:
                sanitized[key] = _redacted_text_summary(item)
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

    consent = payload.get("consent")
    consent_dict = consent if isinstance(consent, dict) else {}
    return {
        "schema_version": int(payload.get("schema_version") or 1),
        "request_id": request_id,
        "client": _dict_or_none(payload.get("client")) or {},
        "capture_mode": str(payload.get("capture_mode") or "frontmost_window").strip().lower(),
        "preferences": _dict_or_none(payload.get("preferences")) or {},
        "frontmost_app": _dict_or_none(payload.get("frontmost_app")) or {},
        "input_mode": input_mode,
        "screenshot": _dict_or_none(payload.get("screenshot")),
        "image_diagnostics": _dict_or_none(payload.get("image_diagnostics")),
        "ocr_packet": _dict_or_none(payload.get("ocr_packet")),
        "focused_context": _dict_or_none(payload.get("focused_context")),
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
    return payload


def _make_legacy_request_envelope() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "request_id": f"legacy-{uuid4().hex}",
        "client": {"mode": "legacy_upload"},
        "capture_mode": "frontmost_window",
        "preferences": {},
        "frontmost_app": {},
        "input_mode": "screenshot",
        "screenshot": None,
        "image_diagnostics": None,
        "ocr_packet": None,
        "focused_context": None,
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
    return settings


def _request_cache_key(envelope: dict[str, Any], image_bytes: bytes | None) -> str:
    material = {
        "capture_mode": envelope.get("capture_mode"),
        "input_mode": envelope.get("input_mode"),
        "preferences": envelope.get("preferences"),
        "frontmost_app": envelope.get("frontmost_app"),
        "ocr_packet": envelope.get("ocr_packet"),
        "focused_context": envelope.get("focused_context"),
    }
    if image_bytes is not None:
        material["screenshot_sha256"] = sha256(image_bytes).hexdigest()
    return sha256(
        json.dumps(material, ensure_ascii=True, sort_keys=True).encode("utf-8")
    ).hexdigest()


def _ok_response(payload: dict[str, Any], request_id: str, warnings: list[str]) -> dict[str, Any]:
    return {
        "request_id": request_id,
        "status": "ok",
        "tldr": payload["tldr"],
        "suggestions": payload["suggestions"],
        "duration_ms": payload["duration_ms"],
        "model": payload["model"],
        "warnings": warnings,
    }


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
) -> None:
    try:
        _telemetry_store().record_request(
            {
                "request_id": envelope["request_id"],
                "token_id": token_id,
                "client": envelope.get("client") or {},
                "capture_mode": envelope.get("capture_mode"),
                "input_mode": envelope.get("input_mode"),
                "frontmost_app": envelope.get("frontmost_app") or {},
                "screenshot": envelope.get("screenshot") or {},
                "image_diagnostics": envelope.get("image_diagnostics") or {},
                "ocr_packet": envelope.get("ocr_packet") or {},
                "focused_context": envelope.get("focused_context") or {},
                "consent": envelope.get("consent") or {},
                "requested_preferences": envelope.get("preferences") or {},
                "model_used": settings.get("model"),
                "status": status_name,
                "latency_ms": latency_ms,
                "usage_tokens": usage_tokens,
                "input_hash": input_hash,
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


async def _run_tldr_request(
    *,
    envelope: dict[str, Any],
    screenshot: Optional[UploadFile],
    token_id: str,
) -> dict[str, Any]:
    warnings = list(envelope.get("warnings") or [])
    image_bytes: bytes | None = None
    mime_type = "image/png"
    if screenshot is not None:
        image_bytes = await screenshot.read()
        mime_type = screenshot.content_type or mime_type
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

    if image_bytes is None and envelope.get("input_mode") == "screenshot":
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="screenshot mode requires a screenshot upload",
        )
    if image_bytes is None and not gemini.request_context_text(envelope):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request must include a screenshot or structured context",
        )

    model_envelope = envelope
    storage_envelope = _privacy_safe_envelope(envelope)
    settings = _selected_settings(envelope, warnings)
    input_hash = _request_cache_key(storage_envelope, image_bytes)
    cache = _response_cache()
    cache_key = _request_cache_key(model_envelope, image_bytes) if _cache_allowed(envelope) else None
    if cache.enabled and cache_key is not None:
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
            )
            return _ok_response(cached, envelope["request_id"], cached_warnings)

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: GEMINI_API_KEY is empty",
        )

    client = gemini.create_client(api_key, settings)
    try:
        payload = gemini.generate_tldr_and_suggestions(
            client=client,
            settings=settings,
            prompt_text=_prompt_text(),
            image_bytes=image_bytes,
            mime_type=mime_type,
            context_text=gemini.request_context_text(model_envelope),
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
        screenshot=screenshot,
        token_id=token_id,
    )
    return {
        "tldr": payload["tldr"],
        "suggestions": payload["suggestions"],
        "duration_ms": payload["duration_ms"],
        "model": payload["model"],
    }


@app.post("/v1/tldr")
async def tldr_v1(
    request: str = Form(...),
    screenshot: Optional[UploadFile] = File(default=None),
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any]:
    try:
        payload = json.loads(request)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="request must contain valid JSON",
        ) from exc
    envelope = _normalize_request_envelope(payload)
    return await _run_tldr_request(
        envelope=envelope,
        screenshot=screenshot,
        token_id=token_id,
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
    if _bool_env("TLDR_EVENT_LOGGING", True):
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
    return {"ok": True, "stored": stored}


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
