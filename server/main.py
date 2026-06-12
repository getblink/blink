from __future__ import annotations

import asyncio
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
        check_signup_stats_rate_limit,
        client_ip_for,
        generate_device_token,
        require_bearer_token,
        token_hash_for,
    )
    from .cache import ResponseCache, ThreadCache
    from .env_loader import load_workspace_env
    from .storage import TelemetryStore
    from .tldr_reflow import reflow_tldr
except ImportError:
    import gemini  # type: ignore[no-redef]
    from auth import (  # type: ignore[no-redef]
        check_signup_rate_limit,
        check_signup_stats_rate_limit,
        client_ip_for,
        generate_device_token,
        require_bearer_token,
        token_hash_for,
    )
    from cache import ResponseCache, ThreadCache  # type: ignore[no-redef]
    from env_loader import load_workspace_env  # type: ignore[no-redef]
    from storage import TelemetryStore  # type: ignore[no-redef]
    from tldr_reflow import reflow_tldr  # type: ignore[no-redef]


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
    # posthog-python 6.x made distinct_id keyword-only and moved event to the
    # first positional. The legacy `capture(distinct_id, event, ...)` form
    # raises TypeError ("takes 2 positional arguments but 3 were given"),
    # which posthog's internal wrapper swallows — so requests still 200, but
    # every event is silently dropped. requirements.txt pins posthog to a 6.x
    # version so the signature stays consistent with this call site.
    if properties is None:
        _posthog_client.capture(event, distinct_id=distinct_id)
    else:
        _posthog_client.capture(event, distinct_id=distinct_id, properties=properties)

MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024
MAX_SCREENSHOT_FRAMES = 8
# /v1/describe-file upload cap. Generous (user-chosen attachments can be
# large PDFs) but bounded: the PDF path slices to 3 pages / 2MB before Gemini
# anyway, and an unbounded read is an OOM vector on a 512Mi container.
MAX_DESCRIBE_FILE_BYTES = 20 * 1024 * 1024
REPO_ROOT = Path(__file__).resolve().parents[1]
PROMPT_PATH = Path(__file__).resolve().with_name("prompt.txt")
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
SIGNUP_ID_RE = re.compile(r"^[0-9a-f]{32}$")

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
# Route blink.tldr.* INFO logs to stderr so Cloud Run / Railway capture them.
# Uvicorn configures its own access logger but does not touch the root logger
# or our application loggers, so `logger.info(...)` was being silently dropped.
logging.basicConfig(
    level=os.environ.get("BLINK_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    force=True,
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
    "about_me",
    "follow_up_instruction",
}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class BetaSignupRequest(BaseModel):
    email: str = Field(min_length=1, max_length=320)
    source: Optional[str] = Field(default=None, max_length=120)
    hp: Optional[str] = Field(default=None, max_length=500)
    ref: Optional[str] = Field(default=None, max_length=64)

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


def _telemetry_store() -> TelemetryStore:
    # Same process-wide instance auth.validate_device_token uses, so the
    # startup warmup's _ensure_schema() covers the auth path too. No
    # lru_cache here: TelemetryStore.shared() is already the singleton, and
    # an extra cache layer would make cache_clear() silently a no-op.
    return TelemetryStore.shared()


@app.on_event("startup")
def _warmup_dependencies() -> None:
    """Pay cold-start costs during container boot, not on the first user request.

    The Cloud Run startup probe gates traffic on this function returning, so
    anything we do here runs before any /v1/tldr hits the service. Measured
    in dogfood (revision 00009-jwx, ttft_ms=9266 on first request vs ~2500
    warm), the dominant cold cost is the first httpx TLS session to
    generativelanguage.googleapis.com plus Google's frontend session affinity
    needing to warm — both move off the user path with one throwaway call.

    All steps are wrapped in try/except: a transient network blip should not
    block the container from starting. Each failure logs but does not raise,
    so the container still serves traffic (just with a slightly cold first
    request, same as before this hook existed).
    """
    # Postgres: open the shared psycopg_pool connection and run schema
    # migrations now so the first request doesn't pay schema-init cost
    # (~1-1.5s on Neon cold compute).
    try:
        store = _telemetry_store()
        if store.enabled:
            store._ensure_schema()
            logger.info("warmup: postgres pool + schema ready")
    except Exception as exc:  # noqa: BLE001 - non-fatal, container should still start
        logger.warning("warmup: postgres failed: %s", exc)

    # Gemini: list models to force one round-trip to
    # generativelanguage.googleapis.com. This establishes the TLS session
    # cache and primes Google's frontend session affinity. Costs no tokens.
    # Note: this warms the metadata endpoint, which is on the same edge as
    # the inference endpoint, so the TLS session ticket carries over.
    try:
        api_key = os.environ.get("GEMINI_API_KEY")
        if api_key:
            client = gemini.create_client(api_key)
            # Force at least one HTTPS round-trip; the pager is lazy otherwise.
            for _ in client.models.list():
                break
            logger.info("warmup: gemini client ready")
    except Exception as exc:  # noqa: BLE001 - non-fatal
        logger.warning("warmup: gemini failed: %s", exc)


async def _notify_discord_signup(
    *,
    email_original: str,
    source: str | None,
    signup_id: str,
    referrer_email: str | None = None,
    referrer_signup_id: str | None = None,
) -> None:
    webhook_url = (os.environ.get("BLINK_DISCORD_SIGNUP_WEBHOOK_URL") or "").strip()
    if not webhook_url:
        return
    fields: list[dict[str, Any]] = [
        {"name": "source", "value": source or "—", "inline": True},
        {"name": "signup_id", "value": signup_id, "inline": True},
    ]
    if referrer_signup_id:
        fields.append(
            {
                "name": "referrer",
                "value": f"{referrer_email or '—'} (`{referrer_signup_id}`)",
                "inline": False,
            }
        )
    payload = {
        "username": "blink-signups",
        "content": f"new beta signup: `{email_original}`",
        "embeds": [
            {
                "title": email_original,
                "color": 0x58A6FF,
                "fields": fields,
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
    ttft_ms: Any = None,
    stream_ms: Any = None,
    cached_tokens: Any = None,
) -> None:
    # ttft_ms/stream_ms only populated on streaming success paths; cached
    # hits, validation errors, and the non-streaming /tldr fallback log
    # them as None. ttft_ms is Gemini's input-processing time (time to
    # first chunk); stream_ms is duration_ms - ttft_ms (output streaming).
    # cached_tokens is Gemini's cached_content_token_count — nonzero means
    # implicit (or explicit) prefix-cache hit on this request.
    logger.info(
        "tldr_request token_id=%s status=%s duration_ms=%s ttft_ms=%s stream_ms=%s cached_tokens=%s usage_tokens=%s",
        token_id,
        status_name,
        duration_ms,
        ttft_ms,
        stream_ms,
        cached_tokens,
        usage_tokens,
    )


def _dict_or_none(value: Any) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _list_or_empty(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _slice_pdf(raw_bytes: bytes, max_pages: int = 3, max_bytes: int = 2 * 1024 * 1024) -> bytes:
    """Return raw_bytes truncated to at most max_pages pages or max_bytes, whichever is smaller."""
    try:
        import io
        from pypdf import PdfReader, PdfWriter

        reader = PdfReader(io.BytesIO(raw_bytes))
        total = len(reader.pages)
        pages_to_take = min(total, max_pages)
        if pages_to_take >= total:
            # Already within page limit — enforce byte cap only
            if len(raw_bytes) <= max_bytes:
                return raw_bytes
            # Still need to truncate bytes; fall through to writer path
            pages_to_take = total

        writer = PdfWriter()
        for i in range(pages_to_take):
            writer.add_page(reader.pages[i])
        buf = io.BytesIO()
        writer.write(buf)
        sliced = buf.getvalue()
        # Enforce byte cap after slicing
        if len(sliced) > max_bytes:
            return sliced[:max_bytes]
        return sliced
    except Exception:
        # Fallback: hard-truncate bytes
        return raw_bytes[:max_bytes]


def _build_selection_block(selection: Any) -> str:
    """Build the <selection> block for injection into the prompt.

    Selection text is the user's explicitly-highlighted input at the
    moment of capture (AX `kAXSelectedTextAttribute` or a gated synthetic
    Cmd+C fallback). When content retention is off the payload carries
    `text_redacted=True` instead of `text`; emit a self-closing tag so
    the model sees the signal without inventing contents.
    """
    if not isinstance(selection, dict):
        return ""
    source = str(selection.get("source") or "").strip()
    char_count = selection.get("char_count")
    truncated = bool(selection.get("truncated"))
    attrs: list[str] = []
    if source:
        attrs.append(f"source={_xml_attr(source)}")
    if isinstance(char_count, int) and char_count >= 0:
        attrs.append(f"char_count={_xml_attr(str(char_count))}")
    attrs.append(f"truncated={_xml_attr('true' if truncated else 'false')}")
    if selection.get("text_redacted"):
        attrs.append(f"text_redacted={_xml_attr('true')}")
        return f"<selection {' '.join(attrs)}/>\n"
    text = selection.get("text")
    if not isinstance(text, str) or not text.strip():
        return ""
    lines = [
        f"<selection {' '.join(attrs)}>",
        text.rstrip(),
        "</selection>",
    ]
    return "\n".join(lines) + "\n"


def _build_ax_tree_block(ax_text: Any) -> str:
    """Build the <ax_tree> block for the user-role capture turn.

    The accessibility tree carries the active window's full structure —
    including content above and below the visible viewport — so it's the
    capture path that gives the model scrolling context the viewport-bound
    screenshot can't. The client already clamps the walk (node + per-node
    value caps); here we apply the server-owned character budget
    (`AX_TREE_MAX_CHARS`) and mark the block truncated when it trips so the
    model knows to fall back on the screenshot for the cut region. Self-
    describing header keeps the hybrid instruction out of the byte-parity-
    locked system prompt for now.
    """
    if not isinstance(ax_text, str):
        return ""
    text = ax_text.strip()
    if not text:
        return ""
    truncated = False
    if len(text) > gemini.AX_TREE_MAX_CHARS:
        text = text[: gemini.AX_TREE_MAX_CHARS].rstrip()
        truncated = True
    header = (
        "Accessibility tree of the active window, including content above "
        "and below the visible viewport. The screenshot shows only what is "
        "currently on screen; use this tree for off-screen context and exact "
        "text, and the screenshot for layout and visual salience."
    )
    attrs = f" truncated={_xml_attr('true' if truncated else 'false')}"
    return f"<ax_tree{attrs}>\n{header}\n\n{text}\n</ax_tree>\n"


def _build_catalog_block(catalog: list[dict[str, Any]]) -> str:
    """Build the attachments catalog block for injection into the prompt.

    Emits XML to match the surrounding prompt's <identity>/<rule_*>/<focus_signal>
    style, so the model has one consistent structure to parse. Text entries
    carry their (client-capped) content inline under <content> for the
    `<rule_6_text_inlining>` path.
    """
    if not catalog:
        return ""
    lines = ["<available_attachments>"]
    for item in catalog:
        item_id = str(item.get("id") or "").strip()
        name = str(item.get("displayName") or "").strip()
        description = str(item.get("description") or "").strip()
        kind = str(item.get("kind") or "other").strip()
        body = str(item.get("body") or "")
        if not item_id or not name:
            continue
        # Empty text entries have nothing to inline AND aren't a real
        # attachment per rule 6 — exclude them so the model doesn't
        # improvise filler content from the description.
        if kind == "text" and not body:
            continue
        attrs = [
            f'id={_xml_attr(item_id)}',
            f'name={_xml_attr(name)}',
            f'kind={_xml_attr(kind)}',
        ]
        if description:
            attrs.append(f'description={_xml_attr(description)}')
        if kind == "text" and body:
            lines.append(f"<attachment {' '.join(attrs)}>")
            lines.append("<content>")
            lines.append(body.rstrip())
            lines.append("</content>")
            lines.append("</attachment>")
        else:
            lines.append(f"<attachment {' '.join(attrs)}/>")
    if len(lines) == 1:
        return ""
    lines.append("</available_attachments>")
    return "\n".join(lines) + "\n"


def _xml_attr(value: str) -> str:
    """Quote a string for use as an XML attribute value."""
    escaped = (
        value.replace("&", "&amp;")
        .replace('"', "&quot;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )
    return f'"{escaped}"'


def _normalize_reroll_context(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="reroll_context must be a JSON object",
        )
    raw_source = value.get("source_request_id")
    source_request_id = str(raw_source or "").strip()
    if (
        not source_request_id
        or len(source_request_id) > 64
        or UUID_RE.fullmatch(source_request_id) is None
    ):
        # Diagnostic: capture what the client actually sent (truncated to
        # 80 chars) so we can debug client-side reroll bugs from logs.
        # Without this the 422 surfaces in the app but the bad value is lost.
        logger.warning(
            "reroll_context.source_request_id rejected: type=%s repr=%r",
            type(raw_source).__name__,
            (source_request_id[:80] if source_request_id else raw_source),
        )
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
    normalized: dict[str, Any] = {
        "schema_version": schema_version,
        "source_request_id": source_request_id,
    }
    follow_up_instruction = str(value.get("follow_up_instruction") or "").strip()
    if follow_up_instruction:
        normalized["follow_up_instruction"] = follow_up_instruction[: gemini.FOLLOW_UP_INSTRUCTION_MAX_CHARS]
    raw_history = value.get("follow_up_history")
    if isinstance(raw_history, list) and raw_history:
        bounded_history = []
        for turn in raw_history:
            if not isinstance(turn, dict):
                continue
            instruction = str(turn.get("instruction") or "").strip()[:gemini.FOLLOW_UP_INSTRUCTION_MAX_CHARS]
            tldr = str(turn.get("tldr") or "").strip()[:gemini.FOLLOW_UP_HISTORY_TLDR_MAX_CHARS]
            raw_suggs = turn.get("suggestions")
            suggestions = []
            if isinstance(raw_suggs, list):
                for item in raw_suggs:
                    text = str(item or "").strip()[:gemini.FOLLOW_UP_HISTORY_SUGGESTION_MAX_CHARS]
                    if text:
                        suggestions.append(text)
                    if len(suggestions) >= 3:
                        break
            turn_entry: dict[str, Any] = {}
            if instruction:
                turn_entry["instruction"] = instruction
            if tldr:
                turn_entry["tldr"] = tldr
            if suggestions:
                turn_entry["suggestions"] = suggestions
            if turn_entry:
                bounded_history.append(turn_entry)
        if bounded_history:
            normalized["follow_up_history"] = bounded_history
    return normalized


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
    # NOTE: `ax_tree` is intentionally NOT redacted here because it is never
    # persisted — `_record_request` does not read it, so the only copy lives in
    # the live envelope the model sees. It is the most content-rich field in the
    # request (the full off-screen window text). If you ever start storing it,
    # redact it here when retention is off, the same as focused_context/selection.
    # The selection text is the user's *explicit* input — it's always sent
    # to the model. Only redact from telemetry storage when retention is
    # off, mirroring how focused_context.value is handled.
    selection = envelope.get("selection")
    if isinstance(selection, dict) and "text" in selection:
        redacted_selection = dict(selection)
        redacted_selection.pop("text", None)
        redacted_selection["text_redacted"] = True
        sanitized["selection"] = redacted_selection
    selections = envelope.get("selections")
    if isinstance(selections, list):
        sanitized["selections"] = [
            (
                {**{k: v for k, v in item.items() if k != "text"}, "text_redacted": True}
                if isinstance(item, dict) and "text" in item
                else item
            )
            for item in selections
        ]
    sanitized["preferences"] = _sanitize_content_payload(
        envelope.get("preferences"),
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
    sanitized["style"] = _sanitize_content_payload(
        envelope.get("style"),
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
    preferences = _dict_or_none(payload.get("preferences")) or {}
    attachments_catalog = _list_or_empty(preferences.get("attachments_catalog"))
    supports_attachments = bool(preferences.get("supports_attachments", False))
    return {
        "schema_version": int(payload.get("schema_version") or 1),
        "request_id": request_id,
        "client": client,
        "install_id": install_id,
        "capture_mode": str(payload.get("capture_mode") or "frontmost_window").strip().lower(),
        "preferences": preferences,
        "frontmost_app": _dict_or_none(payload.get("frontmost_app")) or {},
        "input_mode": input_mode,
        "screenshot": _dict_or_none(payload.get("screenshot")),
        "frames": _list_or_empty(payload.get("frames")),
        "image_diagnostics": _dict_or_none(payload.get("image_diagnostics")),
        "ocr_packet": _dict_or_none(payload.get("ocr_packet")),
        "focused_context": _dict_or_none(payload.get("focused_context")),
        "ax_tree": (str(payload["ax_tree"]) if isinstance(payload.get("ax_tree"), str) else None),
        "ax_tree_nodes": (payload["ax_tree_nodes"] if isinstance(payload.get("ax_tree_nodes"), int) else None),
        "ax_tree_truncated": bool(payload.get("ax_tree_truncated")),
        "selection": _dict_or_none(payload.get("selection")),
        "stateful_context": _dict_or_none(payload.get("stateful_context")),
        "reroll_context": _normalize_reroll_context(payload.get("reroll_context")),
        "style": _dict_or_none(payload.get("style")),
        "consent": {
            "allow_event_logging": bool(consent_dict.get("allow_event_logging", True)),
            "allow_content_retention": bool(consent_dict.get("allow_content_retention", False)),
        },
        "warnings": _list_or_empty(payload.get("warnings")),
        "attachments_catalog": attachments_catalog,
        "supports_attachments": supports_attachments,
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
        "ax_tree": None,
        "ax_tree_nodes": None,
        "ax_tree_truncated": False,
        "selection": None,
        "stateful_context": None,
        "reroll_context": None,
        "style": None,
        "consent": {
            "allow_event_logging": False,
            "allow_content_retention": False,
        },
        "warnings": ["legacy_contract"],
    }


_ALLOWED_THINKING_LEVELS = {"low", "medium", "high", "off"}
_ALLOWED_OUTPUT_FORMATS = {"json", "tags"}


def _selected_settings(envelope: dict[str, Any], warnings: list[str]) -> dict[str, Any]:
    settings = gemini.DEFAULT_SETTINGS.copy()
    preferences = envelope.get("preferences") or {}
    requested_model = str(preferences.get("model") or "").strip()
    if requested_model:
        if requested_model in _allowed_models():
            settings["model"] = requested_model
        else:
            warnings.append("requested_model_disallowed")
    # thinking_level is the one sampling knob the client controls: the macOS
    # "Reasoning" picker maps directly to Gemini's thinking budget. temperature
    # and max_output_tokens stay server-owned so an arbitrary client can't
    # destabilize output shape or blow the budget.
    requested_thinking = str(preferences.get("thinking_level") or "").strip().lower()
    if requested_thinking:
        if requested_thinking in _ALLOWED_THINKING_LEVELS:
            settings["thinking_level"] = requested_thinking
        else:
            warnings.append("requested_thinking_level_disallowed")
    # output_format: experimental knob to swap JSON-mode generation for
    # tag-delimited text. Default stays "json" so this is opt-in; setting
    # `preferences.output_format = "tags"` flips to the tag-mode prompt + parser.
    requested_format = str(preferences.get("output_format") or "").strip().lower()
    if requested_format:
        if requested_format in _ALLOWED_OUTPUT_FORMATS:
            settings["output_format"] = requested_format
        else:
            warnings.append("requested_output_format_disallowed")
    settings["supports_attachments"] = envelope.get("supports_attachments", False)
    settings["attachments_catalog"] = envelope.get("attachments_catalog", [])
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
        "ax_tree": envelope.get("ax_tree"),
        "selection": envelope.get("selection"),
        "stateful_context": envelope.get("stateful_context"),
        "reroll_context": envelope.get("reroll_context"),
        "style": envelope.get("style"),
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
        # Presentational: collapse an announced inline enumeration ("four
        # options: a, b, c, or d") into a scannable vertical list. No-op for
        # everything else. Applied at the client boundary only; stored raw
        # model output is untouched.
        "tldr": reflow_tldr(str(payload.get("tldr") or "")),
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


def _reroll_thread_turn(request_id: str, follow_up_instruction: Any = None) -> dict[str, Any]:
    instruction = str(follow_up_instruction or "").strip()[: gemini.FOLLOW_UP_INSTRUCTION_MAX_CHARS]
    turn = {
        "role": "user",
        "kind": "reroll",
        "request_id": request_id,
        "text": gemini.reroll_content_text(instruction),
    }
    if instruction:
        turn["follow_up_instruction"] = instruction
    return turn


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
            turn_count = len(_valid_thread_turns(thread))
            logger.warning(
                "reroll_thread_cache_hit token_id=%s source_request_id=%s root_request_id=%s turn_count=%s",
                token_id,
                source_request_id,
                str(thread.get("root_request_id") or root_request_id),
                turn_count,
            )
            warnings.append("reroll_thread_cache_hit")
            return {
                "root_request_id": str(thread.get("root_request_id") or root_request_id),
                "source_request_id": source_request_id,
                "thread": thread,
            }
        logger.warning(
            "reroll_thread_cache_miss token_id=%s source_request_id=%s root_request_id=%s",
            token_id,
            source_request_id,
            root_request_id,
        )
        warnings.append("reroll_thread_cache_miss")
    else:
        logger.warning(
            "reroll_thread_cache_disabled token_id=%s source_request_id=%s",
            token_id,
            source_request_id,
        )

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
    follow_up_instruction: Any = None,
) -> list[dict[str, Any]] | None:
    if thread_context is None:
        return None
    turns = _valid_thread_turns(thread_context.get("thread"))
    if not turns:
        return None
    return turns + [_reroll_thread_turn(request_id, follow_up_instruction)]


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
    # When suggestions are unchanged, backfill from the most recent prior model
    # turn so the thread history never stores an empty suggestions entry, which
    # would corrupt Gemini's multi-turn conversation context on the next reroll.
    if payload.get("suggestions_unchanged") and thread_context is not None:
        prior_turns = _valid_thread_turns(thread_context.get("thread") or {})
        for turn in reversed(prior_turns):
            if turn.get("role") == "model" and turn.get("suggestions"):
                payload = dict(payload)
                payload["suggestions"] = turn["suggestions"]
                payload["suggestion_details"] = turn.get("suggestion_details") or [
                    {"text": s, "tags": []} for s in turn["suggestions"]
                ]
                break
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
                _reroll_thread_turn(
                    request_id,
                    (envelope.get("reroll_context") or {}).get("follow_up_instruction")
                    if isinstance(envelope.get("reroll_context"), dict)
                    else None,
                ),
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
    if thread_context is not None:
        logger.warning(
            "reroll_thread_appended token_id=%s source_request_id=%s root_request_id=%s request_id=%s turn_count=%s",
            token_id,
            str(thread_context.get("source_request_id") or ""),
            root_request_id,
            request_id,
            len(_valid_thread_turns(thread)),
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
                "style": envelope.get("style") or {},
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


@app.get("/v1/healthz")
def healthz() -> dict[str, Any]:
    # The bare path /healthz is reserved by Google Frontend on Cloud Run
    # (returns a Google-branded 404 before reaching the container), so the
    # health route is namespaced under /v1/.
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
        await asyncio.to_thread(
            _telemetry_store().mint_device_token,
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
    # Sync Redis/Postgres lookups (thread cache + store fallback) — keep them
    # off the event loop so one slow dependency doesn't stall every other
    # in-flight request on this worker. Only hop for actual rerolls: the
    # helper returns None immediately otherwise, and the default executor is
    # small (~5 threads at 1 vCPU) and shared with up-to-120s Gemini calls,
    # so a no-op hop on every request would queue the hot path behind them.
    thread_context: dict[str, Any] | None = None
    if isinstance(reroll_context, dict):
        thread_context = await asyncio.to_thread(
            _thread_context_for_request,
            envelope=envelope,
            token_id=token_id,
            warnings=warnings,
        )
    conversation_turns = _conversation_turns_for_request(
        thread_context,
        str(envelope["request_id"]),
        reroll_context.get("follow_up_instruction") if isinstance(reroll_context, dict) else None,
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
        cached = await asyncio.to_thread(cache.get, cache_key)
        if cached is not None:
            cached_warnings = warnings + ["cache_hit"]
            _log_request(
                token_id=token_id,
                status_name="ok_cached",
                duration_ms=cached.get("duration_ms"),
                usage_tokens=None,
            )
            await asyncio.to_thread(
                _record_request,
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
            await asyncio.to_thread(
                _store_thread_success,
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
    base_prompt = _prompt_text()
    catalog_block = _build_catalog_block(settings.get("attachments_catalog") or [])
    if catalog_block:
        base_prompt = base_prompt.rstrip() + "\n\n" + catalog_block
    # The <selection> block carries the user's explicit, per-request
    # input — it belongs in the user-role turn alongside the screenshot,
    # not in the stable system instruction. The <selection_signal> rules
    # in prompt.txt teach the model how to interpret it.
    selection_block = _build_selection_block(envelope.get("selection")).rstrip()
    # Capture-turn text part: AX tree first (window context, incl. off-screen),
    # then the user's explicit <selection> last so the instruction keeps recency.
    ax_tree_block = _build_ax_tree_block(envelope.get("ax_tree")).rstrip()
    capture_suffix = "\n\n".join(
        part for part in (ax_tree_block, selection_block) if part
    )
    # Observability for the AX-tree rollout: a correlated line (same token_id /
    # request_id as the tldr_request line) carrying the raw capture size and
    # whether the server budget clamp tripped. Lets us measure AX size → token
    # cost without threading a new field through every _log_request call site.
    _ax_tree_raw = envelope.get("ax_tree")
    _ax_tree_chars = len(_ax_tree_raw) if isinstance(_ax_tree_raw, str) else 0
    # nodes = client walk size; walk_truncated = client hit the node cap (vs
    # clamped = server hit the char budget). Together they tell us which limit
    # binds first on a massive page.
    logger.info(
        "tldr_ax_tree token_id=%s request_id=%s ax_tree_chars=%s ax_tree_nodes=%s walk_truncated=%s clamped=%s",
        token_id,
        envelope.get("request_id"),
        _ax_tree_chars,
        envelope.get("ax_tree_nodes"),
        bool(envelope.get("ax_tree_truncated")),
        _ax_tree_chars > gemini.AX_TREE_MAX_CHARS,
    )
    prompt_text = gemini.prompt_with_context(
        base_prompt,
        model_envelope.get("stateful_context"),
        None if conversation_turns is not None else model_envelope.get("reroll_context"),
        model_envelope.get("style"),
    )
    # Tag-mode experiment: swap the prompt's <output_format> block for tag-style
    # instructions, then call the tag streaming function below. Otherwise the
    # canonical JSON path applies.
    use_tags = settings.get("output_format") == "tags"
    if use_tags:
        prompt_text = gemini.substitute_output_format_for_tags(prompt_text)
        streaming_fn = gemini.generate_tldr_and_suggestions_streaming_tags
    else:
        streaming_fn = gemini.generate_tldr_and_suggestions_streaming
    if stream:
        def stream_events() -> Any:
            try:
                for event in streaming_fn(
                    client=client,
                    settings=settings,
                    prompt_text=prompt_text,
                    images=images,
                    conversation_turns=conversation_turns,
                    user_message_suffix=capture_suffix,
                    is_followup=isinstance(envelope.get("reroll_context"), dict),
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
                                ttft_ms=data.get("ttft_ms"),
                                stream_ms=data.get("stream_ms"),
                                cached_tokens=data.get("cached_tokens"),
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
                                ttft_ms=data.get("ttft_ms"),
                                stream_ms=data.get("stream_ms"),
                                cached_tokens=data.get("cached_tokens"),
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
        # The Gemini SDK call is synchronous and can take up to ~120s; run it
        # in a worker thread so it doesn't block the event loop (uvicorn runs
        # a single loop — a blocking call here stalls every request,
        # including /v1/healthz). The SSE path escapes via Starlette's
        # sync-generator threadpool; this is the non-stream equivalent.
        payload = await asyncio.to_thread(
            gemini.generate_tldr_and_suggestions,
            client=client,
            settings=settings,
            prompt_text=prompt_text,
            images=images,
            conversation_turns=conversation_turns,
            supports_attachments=settings.get("supports_attachments", False),
            user_message_suffix=capture_suffix,
            is_followup=isinstance(envelope.get("reroll_context"), dict),
        )
    except Exception as exc:
        detail = f"Gemini upstream error: {_sanitized_error_message(exc)}"
        _log_request(
            token_id=token_id,
            status_name="upstream_error",
            duration_ms=None,
            usage_tokens=None,
        )
        await asyncio.to_thread(
            _record_request,
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

    # Strip hallucinated attachment IDs
    if settings.get("supports_attachments"):
        valid_ids = {str(item.get("id") or "") for item in settings.get("attachments_catalog", []) if item.get("id")}
        for suggestion in payload.get("suggestion_details") or []:
            raw_attachments = suggestion.get("attachments") or []
            filtered = []
            stripped_count = 0
            for att in raw_attachments:
                att_id = str(att.get("id") or "").strip()
                if att_id in valid_ids:
                    att["reason"] = str(att.get("reason") or "")[:80]  # belt-and-suspenders
                    filtered.append(att)
                else:
                    stripped_count += 1
            if stripped_count:
                logger.warning("stripped_hallucinated_attachments count=%d", stripped_count)
            suggestion["attachments"] = filtered

    usage_tokens = gemini.usage_token_count(payload.get("usage"))
    _log_request(
        token_id=token_id,
        status_name=str(payload.get("status")),
        duration_ms=payload.get("duration_ms"),
        usage_tokens=usage_tokens,
        ttft_ms=payload.get("ttft_ms"),
        stream_ms=payload.get("stream_ms"),
        cached_tokens=payload.get("cached_tokens"),
    )

    if payload.get("status") == "ok":
        if cache.enabled and cache_key is not None:
            await asyncio.to_thread(
                cache.set,
                cache_key,
                {
                    "tldr": payload["tldr"],
                    "suggestions": payload["suggestions"],
                    "suggestion_details": payload.get("suggestion_details"),
                    "duration_ms": payload["duration_ms"],
                    "model": payload["model"],
                },
            )
        await asyncio.to_thread(
            _record_request,
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
        await asyncio.to_thread(
            _store_thread_success,
            token_id=token_id,
            envelope=envelope,
            image_bytes_list=image_bytes_list,
            payload=payload,
            thread_context=thread_context,
        )
        return _ok_response(payload, envelope["request_id"], warnings)

    if payload.get("status") == "parse_error":
        detail = "parse_error: Gemini returned non-JSON output"
        await asyncio.to_thread(
            _record_request,
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
    await asyncio.to_thread(
        _record_request,
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


@app.post("/v1/describe-file")
async def describe_file(
    file: UploadFile = File(...),
    kind: str = Form("other"),
    _token_data: dict[str, Any] = Depends(require_bearer_token),
) -> dict[str, Any]:
    """Auto-generate a one-line description for a staged attachment.

    Only image and pdf hit Gemini here. Text and opaque-binary entries are
    described client-side (cheap, deterministic, doesn't burn tokens) and
    never reach this endpoint in a healthy client.
    """
    if kind not in {"image", "pdf"}:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="kind must be image or pdf (text and other are described client-side)",
        )
    # Read at most cap+1 bytes so an oversized upload 413s early. (The
    # multipart parser has already spooled the body to a temp file by the
    # time we get here; this cap avoids the second in-heap copy and the
    # Gemini round-trip, and Cloud Run's 32MB request cap bounds the spool.)
    raw_bytes = await file.read(MAX_DESCRIBE_FILE_BYTES + 1)
    if len(raw_bytes) > MAX_DESCRIBE_FILE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail="file exceeds 20MB limit",
        )
    mime_type = file.content_type or "application/octet-stream"

    # PDF: slice to first 3 pages or 2 MB, whichever smaller. pypdf parsing
    # is CPU-bound sync work — keep it off the event loop.
    if kind == "pdf":
        raw_bytes = await asyncio.to_thread(
            _slice_pdf, raw_bytes, max_pages=3, max_bytes=2 * 1024 * 1024
        )
        mime_type = "application/pdf"

    # Image: the raw bytes go to Gemini directly (client already downscaled)
    if kind == "image":
        if not mime_type.startswith("image/"):
            mime_type = "image/jpeg"

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: GEMINI_API_KEY is empty",
        )
    client = gemini.create_client(api_key=api_key)
    # Sync SDK call — same event-loop-blocking hazard as the tldr path.
    description = await asyncio.to_thread(
        gemini.generate_file_description, client, raw_bytes, mime_type, kind
    )
    return {"description": description}


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
            stored = await asyncio.to_thread(
                _telemetry_store().record_event,
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
    # Redis-backed when REDIS_URL is set — sync I/O, keep it off the loop.
    await asyncio.to_thread(check_signup_rate_limit, ip_hash)

    store = _telemetry_store()

    referrer_signup_id: str | None = None
    referrer_email: str | None = None
    ref_candidate = (payload.ref or "").strip().lower()
    if ref_candidate and SIGNUP_ID_RE.match(ref_candidate):
        try:
            referrer = await asyncio.to_thread(
                store.get_beta_signup_by_id, ref_candidate
            )
        except Exception as exc:
            logger.warning(
                "beta_signup_referrer_lookup_failed error=%s",
                _sanitized_error_message(exc),
            )
            referrer = None
        if referrer is not None:
            # Self-referral guard: drop ref only when the new signup shares
            # the referrer's normalized email. We deliberately do not check
            # ip_hash — shared IPs (households, offices, campus Wi-Fi) are
            # common enough that gating on IP would false-negative real
            # referrals more often than it caught self-referral abuse.
            same_email = referrer.get("email_normalized") == email_normalized
            if not same_email:
                referrer_signup_id = ref_candidate

    signup_id = uuid4().hex
    try:
        inserted = await asyncio.to_thread(
            store.record_beta_signup,
            signup_id=signup_id,
            email_normalized=email_normalized,
            email_original=email_original,
            source=source,
            user_agent=request.headers.get("user-agent"),
            ip_hash=ip_hash,
            referrer_signup_id=referrer_signup_id,
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
            properties={"source": source, "referred": bool(referrer_signup_id)},
        )
        if referrer_signup_id:
            try:
                referrer_row = await asyncio.to_thread(
                    store.get_beta_signup_by_id, referrer_signup_id
                )
            except Exception:
                referrer_row = None
            # We only surface the referrer's original email in Discord. The
            # row stored only the normalized form on lookup; fetch original
            # via a second query if needed. For now we keep the Discord field
            # to the signup_id alone if we don't have the original email.
            if referrer_row:
                referrer_email = (
                    referrer_row.get("email_original")
                    or referrer_row.get("email_normalized")
                )
        background_tasks.add_task(
            _notify_discord_signup,
            email_original=email_original,
            source=source,
            signup_id=signup_id,
            referrer_email=referrer_email,
            referrer_signup_id=referrer_signup_id,
        )
        return {
            "ok": True,
            "signup_id": signup_id,
            "already_signed_up": False,
        }

    # Duplicate path: surface the existing signup_id only when the request
    # plausibly comes from the original signer — same IP hash. This stops a
    # third party from harvesting someone else's referral link by guessing
    # their email. Same-IP browsers (mobile after desktop, an incognito
    # retry) still get the share row.
    existing_id: str | None = None
    try:
        existing = await asyncio.to_thread(
            lambda: store.get_beta_signup_by_id(
                store.get_beta_signup_id_for_email(email_normalized) or ""
            )
        )
    except Exception as exc:
        logger.warning(
            "beta_signup_duplicate_lookup_failed error=%s",
            _sanitized_error_message(exc),
        )
        existing = None
    if (
        existing is not None
        and existing.get("ip_hash")
        and existing.get("ip_hash") == ip_hash
    ):
        existing_id = existing.get("id")
    _posthog_capture(
        f"hash:{ip_hash[:16]}",
        "beta_signup_duplicate",
        properties={"source": source},
    )
    response: dict[str, Any] = {"ok": True, "already_signed_up": True}
    if existing_id:
        response["signup_id"] = existing_id
    return response


@app.get("/v1/beta-signup/{signup_id}/stats")
async def beta_signup_stats(
    signup_id: str,
    request: Request,
) -> dict[str, Any]:
    if not SIGNUP_ID_RE.match(signup_id):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="signup not found",
        )
    ip_hash = _ip_hash_for(client_ip_for(request))
    check_signup_stats_rate_limit(ip_hash)
    store = _telemetry_store()
    try:
        row = await asyncio.to_thread(store.get_beta_signup_by_id, signup_id)
    except Exception as exc:
        logger.warning(
            "beta_signup_stats_lookup_failed error=%s",
            _sanitized_error_message(exc),
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="beta signup storage unavailable",
        ) from exc
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="signup not found",
        )
    try:
        referrals = await asyncio.to_thread(store.count_beta_referrals, signup_id)
    except Exception as exc:
        logger.warning(
            "beta_signup_stats_count_failed error=%s",
            _sanitized_error_message(exc),
        )
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="beta signup storage unavailable",
        ) from exc
    return {"ok": True, "referrals": referrals}


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
