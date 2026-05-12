from __future__ import annotations

import hashlib
import logging
import os
import secrets
import threading
import time
from dataclasses import dataclass
from typing import Optional

from fastapi import Header, HTTPException, Request, status

try:
    from .storage import TelemetryStore
except ImportError:
    from storage import TelemetryStore  # type: ignore[no-redef]

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
_MINT_RATE_LIMIT_BUCKETS: dict[str, _TokenBucket] = {}
_SIGNUP_RATE_LIMIT_MINUTE_BUCKETS: dict[str, _TokenBucket] = {}
_SIGNUP_RATE_LIMIT_DAY_BUCKETS: dict[str, _TokenBucket] = {}
_SIGNUP_STATS_RATE_LIMIT_MINUTE_BUCKETS: dict[str, _TokenBucket] = {}
_LOGGER = logging.getLogger("blink.tldr.auth")
_DEPRECATION_WARNED: set[str] = set()


def _env(name: str, deprecated: str | None = None) -> str | None:
    value = os.environ.get(name)
    if value is not None:
        return value
    if deprecated is None:
        return None
    value = os.environ.get(deprecated)
    if value is not None and deprecated not in _DEPRECATION_WARNED:
        _DEPRECATION_WARNED.add(deprecated)
        _LOGGER.warning("%s is deprecated, use %s", deprecated, name)
    return value


def _int_env(name: str, default: int) -> int:
    legacy = name.replace("BLINK_", "TLDR_", 1) if name.startswith("BLINK_") else None
    raw = _env(name, legacy)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value


def token_id_for(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:8]


def token_hash_for(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def generate_device_token() -> str:
    return "tldr_dt_" + secrets.token_urlsafe(32)


def configured_tokens() -> set[str]:
    raw = os.environ.get("BLINK_API_TOKENS", "")
    return {token.strip() for token in raw.split(",") if token.strip()}


def bootstrap_token() -> str | None:
    token = (os.environ.get("BLINK_BOOTSTRAP_TOKEN") or "").strip()
    return token or None


def legacy_tokens_allowed() -> bool:
    raw = os.environ.get("BLINK_LEGACY_TOKEN_ALLOWED")
    if raw is None:
        return True
    return raw.strip().lower() not in {"", "0", "false", "no", "off"}


def validate_token(token: str) -> str:
    if not token:
        raise ValueError("missing bearer token")
    if token not in configured_tokens():
        raise ValueError("invalid bearer token")
    return token_id_for(token)


class BootstrapMisconfigured(RuntimeError):
    """Raised when BLINK_BOOTSTRAP_TOKEN is empty so callers can return 500."""


def validate_bootstrap_token(token: str) -> str:
    expected = bootstrap_token()
    if not expected:
        raise BootstrapMisconfigured(
            "server misconfigured: BLINK_BOOTSTRAP_TOKEN is empty"
        )
    if not token or not secrets.compare_digest(token, expected):
        raise ValueError("invalid bootstrap token")
    return token_id_for(token)


def is_bootstrap_token(token: str) -> bool:
    expected = bootstrap_token()
    if not expected or not token:
        return False
    return secrets.compare_digest(token, expected)


def trust_proxy_headers() -> bool:
    raw = _env("BLINK_TRUST_PROXY_HEADERS", "TLDR_TRUST_PROXY_HEADERS")
    if raw is None:
        return False
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def client_ip_for(request: Request) -> str:
    if trust_proxy_headers():
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            first = forwarded.split(",", 1)[0].strip()
            if first:
                return first
    if request.client and request.client.host:
        return request.client.host
    return "unknown"


def validate_device_token(token: str) -> str:
    if not token.startswith("tldr_dt_"):
        raise ValueError("invalid device token")
    token_hash = token_hash_for(token)
    if not TelemetryStore.from_env().device_token_active(token_hash):
        raise ValueError("invalid device token")
    return token_id_for(token)


def _rate_limit_redis_client() -> object | None:
    global _RATE_LIMIT_REDIS_CLIENT, _RATE_LIMIT_REDIS_URL
    redis_url = (
        _env("BLINK_RATE_LIMIT_REDIS_URL", "TLDR_RATE_LIMIT_REDIS_URL")
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


def _check_redis_signup_rate_limit(ip_hash: str, *, minute_limit: int, day_limit: int) -> bool:
    client = _rate_limit_redis_client()
    if client is None:
        return False
    now = int(time.time())
    checks = [
        (f"tldr:v1:signup_rate:minute:{ip_hash}:{now // 60}", minute_limit, 120, "signup rate limit exceeded"),
        (f"tldr:v1:signup_rate:day:{ip_hash}:{now // 86400}", day_limit, 172800, "signup daily limit exceeded"),
    ]
    try:
        for key, limit, ttl, detail in checks:
            if limit <= 0:
                continue
            count = int(client.incr(key))  # type: ignore[attr-defined]
            if count == 1:
                client.expire(key, ttl)  # type: ignore[attr-defined]
            if count > limit:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=detail,
                )
    except HTTPException:
        raise
    except Exception:
        return False
    return True


def check_token_rate_limit(token_id: str, now: float | None = None) -> None:
    limit = _int_env("BLINK_TOKEN_RATE_LIMIT_PER_MINUTE", 60)
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


def check_mint_rate_limit(client_id: str, now: float | None = None) -> None:
    limit = _int_env("BLINK_MINT_RATE_LIMIT_PER_MINUTE", 5)
    if limit <= 0:
        return
    current_time = time.monotonic() if now is None else now
    key = client_id or "unknown"
    with _RATE_LIMIT_LOCK:
        bucket = _MINT_RATE_LIMIT_BUCKETS.get(key)
        if bucket is None or current_time - bucket.window_started_at >= 60:
            _MINT_RATE_LIMIT_BUCKETS[key] = _TokenBucket(
                window_started_at=current_time,
                count=1,
            )
            return
        if bucket.count >= limit:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="mint rate limit exceeded",
            )
        bucket.count += 1


def _check_bucket(
    buckets: dict[str, _TokenBucket],
    *,
    key: str,
    limit: int,
    window_seconds: int,
    detail: str,
    now: float,
) -> None:
    if limit <= 0:
        return
    bucket = buckets.get(key)
    if bucket is None or now - bucket.window_started_at >= window_seconds:
        buckets[key] = _TokenBucket(window_started_at=now, count=1)
        return
    if bucket.count >= limit:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=detail,
        )
    bucket.count += 1


def check_signup_stats_rate_limit(ip_hash: str, now: float | None = None) -> None:
    limit = _int_env("BLINK_SIGNUP_STATS_RATE_LIMIT_PER_MINUTE", 60)
    if limit <= 0:
        return
    current_time = time.monotonic() if now is None else now
    key = ip_hash or "unknown"
    with _RATE_LIMIT_LOCK:
        _check_bucket(
            _SIGNUP_STATS_RATE_LIMIT_MINUTE_BUCKETS,
            key=key,
            limit=limit,
            window_seconds=60,
            detail="signup stats rate limit exceeded",
            now=current_time,
        )


def check_signup_rate_limit(ip_hash: str, now: float | None = None) -> None:
    minute_limit = _int_env("BLINK_SIGNUP_RATE_LIMIT_PER_MINUTE", 5)
    day_limit = _int_env("BLINK_SIGNUP_RATE_LIMIT_PER_DAY", 50)
    if minute_limit <= 0 and day_limit <= 0:
        return
    if now is None and _check_redis_signup_rate_limit(
        ip_hash,
        minute_limit=minute_limit,
        day_limit=day_limit,
    ):
        return
    current_time = time.monotonic() if now is None else now
    key = ip_hash or "unknown"
    with _RATE_LIMIT_LOCK:
        _check_bucket(
            _SIGNUP_RATE_LIMIT_MINUTE_BUCKETS,
            key=key,
            limit=minute_limit,
            window_seconds=60,
            detail="signup rate limit exceeded",
            now=current_time,
        )
        _check_bucket(
            _SIGNUP_RATE_LIMIT_DAY_BUCKETS,
            key=key,
            limit=day_limit,
            window_seconds=86400,
            detail="signup daily limit exceeded",
            now=current_time,
        )


def _extract_bearer_token(authorization: Optional[str]) -> str:
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
    return token.strip()


def require_bearer_token(
    request: Request,
    authorization: Optional[str] = Header(default=None),
) -> str:
    token = _extract_bearer_token(authorization)
    if request.url.path == "/v1/auth/mint":
        try:
            token_id = validate_bootstrap_token(token)
        except BootstrapMisconfigured as exc:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=str(exc),
            ) from exc
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=str(exc),
            ) from exc
        check_mint_rate_limit(client_ip_for(request))
        return token_id

    # Try device token first (preferred path for clients that have minted).
    try:
        token_id: str | None = validate_device_token(token)
    except ValueError:
        token_id = None

    if token_id is None and is_bootstrap_token(token):
        # During the upgrade window, accept the bundled bootstrap on
        # non-mint endpoints so a fresh install isn't bricked between
        # launch and a successful mint. Gated on legacy_tokens_allowed
        # so we can flip it off cleanly later.
        if legacy_tokens_allowed():
            token_id = token_id_for(token)
        else:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="bootstrap token is only valid for minting device tokens",
            )

    if token_id is None:
        if not legacy_tokens_allowed():
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="invalid device token",
            )
        if not configured_tokens():
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="server misconfigured: BLINK_API_TOKENS is empty",
            )
        try:
            token_id = validate_token(token)
        except ValueError as exc:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail=str(exc),
            ) from exc

    check_token_rate_limit(token_id)
    return token_id


def legacy_require_bearer_token(authorization: Optional[str] = Header(default=None)) -> str:
    if not configured_tokens():
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="server misconfigured: BLINK_API_TOKENS is empty",
        )
    token = _extract_bearer_token(authorization)
    try:
        token_id = validate_token(token)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc
    check_token_rate_limit(token_id)
    return token_id
