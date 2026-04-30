from __future__ import annotations

import hashlib
import os
from typing import Optional

from fastapi import Header, HTTPException, status


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
        return validate_token(token.strip())
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
        ) from exc
