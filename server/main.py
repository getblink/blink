from __future__ import annotations

import logging
import os
import subprocess
from functools import lru_cache
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, File, HTTPException, UploadFile, status

try:
    from . import gemini
    from .auth import require_bearer_token
    from .env_loader import load_workspace_env
except ImportError:
    import gemini  # type: ignore[no-redef]
    from auth import require_bearer_token  # type: ignore[no-redef]
    from env_loader import load_workspace_env  # type: ignore[no-redef]


load_workspace_env()

MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024
REPO_ROOT = Path(__file__).resolve().parents[1]
PROMPT_PATH = Path(__file__).resolve().with_name("prompt.txt")

app = FastAPI(title="Blink TLDR Server")
logger = logging.getLogger("blink.tldr.server")


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


def _sanitized_error_message(exc: Exception) -> str:
    message = " ".join(str(exc).split())
    if not message:
        return "Gemini upstream error"
    return message[:240]


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


def _ok_response(payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "tldr": payload["tldr"],
        "suggestions": payload["suggestions"],
        "duration_ms": payload["duration_ms"],
        "model": payload["model"],
    }


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    return {"ok": True, "version": _version()}


@app.post("/tldr")
async def tldr(
    screenshot: UploadFile = File(...),
    token_id: str = Depends(require_bearer_token),
) -> dict[str, Any]:
    image_bytes = await screenshot.read()
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

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: GEMINI_API_KEY is empty",
        )

    settings = gemini.DEFAULT_SETTINGS.copy()
    client = gemini.create_client(api_key, settings)

    try:
        payload = gemini.generate_tldr_and_suggestions(
            client=client,
            settings=settings,
            prompt_text=_prompt_text(),
            image_bytes=image_bytes,
            mime_type=screenshot.content_type or "image/png",
        )
    except Exception as exc:
        _log_request(
            token_id=token_id,
            status_name="upstream_error",
            duration_ms=None,
            usage_tokens=None,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Gemini upstream error: {_sanitized_error_message(exc)}",
        ) from exc

    usage_tokens = gemini.usage_token_count(payload.get("usage"))
    _log_request(
        token_id=token_id,
        status_name=str(payload.get("status")),
        duration_ms=payload.get("duration_ms"),
        usage_tokens=usage_tokens,
    )

    if payload.get("status") == "ok":
        return _ok_response(payload)
    if payload.get("status") == "parse_error":
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="parse_error: Gemini returned non-JSON output",
        )
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="schema_mismatch: Gemini returned an incomplete response",
    )
