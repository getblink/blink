from __future__ import annotations

import hashlib
import os
import threading
import time
from dataclasses import dataclass
from typing import Optional

from fastapi import Header, HTTPException, status

try:
    import redis
except ImportError:  # pragma: no cover - optional dependency for local dev
    redis = None  # type: ignore[assignment]


@dataclass
class _TokenBucket:
    window_started_at: float
    count: int


_RATE_LIMIT_LOCK = threading.Lock()
_RATE_LIMIT_BUCKETS: dict[str, _TokenBucket] = {}
_RATE_LIMIT_REDIS_CLIENT: object | None = None
_RATE_LIMIT_REDIS_URL: str | None = None


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value


def token_id_for(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def configured_tokens() -> set[str]:
    raw = os.environ.get("BLINK_API_TOKENS", "")
    return {token.strip() for token in raw.split(",") if token.strip()}


def validate_token(token: str) -> str:
    if not token:
        raise ValueError("missing bearer token")
    if token not in configured_tokens():
        raise ValueError("invalid bearer token")
    return token_id_for(token)


def _rate_limit_redis_client() -> object | None:
    global _RATE_LIMIT_REDIS_CLIENT, _RATE_LIMIT_REDIS_URL
    redis_url = (
        os.environ.get("TLDR_RATE_LIMIT_REDIS_URL")
        or os.environ.get("REDIS_URL")
        or ""
    ).strip()
    if not redis_url or redis is None:
        return None
    if _RATE_LIMIT_REDIS_CLIENT is not None and _RATE_LIMIT_REDIS_URL == redis_url:
        return _RATE_LIMIT_REDIS_CLIENT
    try:
        _RATE_LIMIT_REDIS_CLIENT = redis.from_url(redis_url, decode_responses=True)
    except Exception:
        _RATE_LIMIT_REDIS_CLIENT = None
    _RATE_LIMIT_REDIS_URL = redis_url
    return _RATE_LIMIT_REDIS_CLIENT


def _check_redis_rate_limit(token_id: str, limit: int) -> bool:
    client = _rate_limit_redis_client()
    if client is None:
        return False
    key = f"tldr:v1:rate:{token_id}:{int(time.time() // 60)}"
    try:
        count = int(client.incr(key))  # type: ignore[attr-defined]
        if count == 1:
            client.expire(key, 120)  # type: ignore[attr-defined]
    except Exception:
        return False
    if count > limit:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="token rate limit exceeded",
        )
    return True


def check_token_rate_limit(token_id: str, now: float | None = None) -> None:
    limit = _int_env("TLDR_TOKEN_RATE_LIMIT_PER_MINUTE", 60)
    if limit <= 0:
        return
    if now is None and _check_redis_rate_limit(token_id, limit):
        return
    current_time = time.monotonic() if now is None else now
    with _RATE_LIMIT_LOCK:
        bucket = _RATE_LIMIT_BUCKETS.get(token_id)
        if bucket is None or current_time - bucket.window_started_at >= 60:
            _RATE_LIMIT_BUCKETS[token_id] = _TokenBucket(
                window_started_at=current_time,
                count=1,
            )
            return
        if bucket.count >= limit:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="token rate limit exceeded",
            )
        bucket.count += 1


def require_bearer_token(authorization: Optional[str] = Header(default=None)) -> str:
    if not configured_tokens():
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: BLINK_API_TOKENS is empty",
        )
    if authorization is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing bearer token",
        )
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid bearer token",
        )
    try:
        token_id = validate_token(token.strip())
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc
    check_token_rate_limit(token_id)
    return token_id
