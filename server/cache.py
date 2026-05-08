from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from typing import Any

try:
    import redis
except ImportError:  # pragma: no cover - optional dependency for local dev
    redis = None  # type: ignore[assignment]

_LOGGER = logging.getLogger("blink.tldr.cache")
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


def _bool_env(name: str, default: bool) -> bool:
    legacy = name.replace("BLINK_", "TLDR_", 1) if name.startswith("BLINK_") else None
    raw = _env(name, legacy)
    if raw is None:
        return default
    return raw.strip().lower() not in {"", "0", "false", "no", "off"}


@dataclass
class ResponseCache:
    client: Any | None
    ttl_seconds: int
    enabled: bool
    key_prefix: str = "tldr:v1:"

    @classmethod
    def from_env(cls) -> "ResponseCache":
        enabled = _bool_env("BLINK_CACHE_RESPONSES", True)
        redis_url = (os.environ.get("REDIS_URL") or "").strip()
        ttl_seconds = int(_env("BLINK_RESPONSE_CACHE_TTL_SECONDS", "TLDR_RESPONSE_CACHE_TTL_SECONDS") or "86400")
        if not enabled or not redis_url or redis is None:
            return cls(client=None, ttl_seconds=ttl_seconds, enabled=False)
        try:
            client = redis.from_url(redis_url, decode_responses=True)
        except Exception:
            return cls(client=None, ttl_seconds=ttl_seconds, enabled=False)
        return cls(client=client, ttl_seconds=ttl_seconds, enabled=True)

    def get(self, key: str) -> dict[str, Any] | None:
        if not self.enabled or self.client is None:
            return None
        try:
            raw = self.client.get(self.key_prefix + key)
        except Exception:
            return None
        if not raw:
            return None
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None

    def set(self, key: str, payload: dict[str, Any]) -> None:
        if not self.enabled or self.client is None:
            return
        try:
            self.client.setex(
                self.key_prefix + key,
                self.ttl_seconds,
                json.dumps(payload, ensure_ascii=True, sort_keys=True),
            )
        except Exception:
            return
