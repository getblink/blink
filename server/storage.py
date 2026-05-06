from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

try:
    import psycopg
except ImportError:  # pragma: no cover - optional dependency for local dev
    psycopg = None  # type: ignore[assignment]


REQUESTS_SCHEMA = """
CREATE TABLE IF NOT EXISTS tldr_requests (
    request_id TEXT PRIMARY KEY,
    token_id TEXT NOT NULL,
    install_id TEXT,
    client JSONB NOT NULL,
    capture_mode TEXT NOT NULL,
    input_mode TEXT NOT NULL,
    frontmost_app JSONB,
    screenshot JSONB,
    image_diagnostics JSONB,
    ocr_packet JSONB,
    focused_context JSONB,
    stateful_context JSONB,
    consent JSONB NOT NULL,
    requested_preferences JSONB NOT NULL,
    model_used TEXT,
    status TEXT NOT NULL,
    latency_ms INTEGER,
    usage_tokens INTEGER,
    input_hash TEXT,
    summary TEXT,
    suggestions JSONB,
    raw_model_output TEXT,
    chosen_index INTEGER,
    outcome TEXT,
    warnings JSONB NOT NULL,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS install_id TEXT;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS stateful_context JSONB;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS summary TEXT;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS suggestions JSONB;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS raw_model_output TEXT;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS chosen_index INTEGER;
ALTER TABLE tldr_requests
    ADD COLUMN IF NOT EXISTS outcome TEXT;
CREATE INDEX IF NOT EXISTS tldr_requests_created_at_idx
    ON tldr_requests (created_at DESC);
CREATE INDEX IF NOT EXISTS tldr_requests_install_id_idx
    ON tldr_requests (install_id);
CREATE INDEX IF NOT EXISTS tldr_requests_input_hash_idx
    ON tldr_requests (input_hash);
"""

DEVICE_TOKENS_SCHEMA = """
CREATE TABLE IF NOT EXISTS device_tokens (
    token_hash TEXT PRIMARY KEY,
    install_id TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS device_tokens_install_id_idx
    ON device_tokens (install_id);
"""

EVENTS_SCHEMA = """
CREATE TABLE IF NOT EXISTS tldr_events (
    request_id TEXT NOT NULL,
    token_id TEXT NOT NULL,
    install_id TEXT,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE tldr_events
    ADD COLUMN IF NOT EXISTS install_id TEXT;
CREATE INDEX IF NOT EXISTS tldr_events_request_id_idx
    ON tldr_events (request_id);
CREATE INDEX IF NOT EXISTS tldr_events_install_id_idx
    ON tldr_events (install_id);
CREATE INDEX IF NOT EXISTS tldr_events_created_at_idx
    ON tldr_events (created_at DESC);
"""


@dataclass
class TelemetryStore:
    database_url: str | None
    enabled: bool
    schema_ready: bool = False

    @classmethod
    def from_env(cls) -> "TelemetryStore":
        database_url = (os.environ.get("DATABASE_URL") or "").strip()
        enabled = bool(database_url and psycopg is not None)
        return cls(database_url=database_url or None, enabled=enabled)

    def _ensure_schema(self) -> None:
        if not self.enabled or self.database_url is None or self.schema_ready:
            return
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(REQUESTS_SCHEMA)
                cur.execute(EVENTS_SCHEMA)
                cur.execute(DEVICE_TOKENS_SCHEMA)
            conn.commit()
        self.schema_ready = True

    def record_request(self, payload: dict[str, Any]) -> None:
        if not self.enabled or self.database_url is None:
            return
        self._ensure_schema()
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO tldr_requests (
                        request_id,
                        token_id,
                        install_id,
                        client,
                        capture_mode,
                        input_mode,
                        frontmost_app,
                        screenshot,
                        image_diagnostics,
                        ocr_packet,
                        focused_context,
                        stateful_context,
                        consent,
                        requested_preferences,
                        model_used,
                        status,
                        latency_ms,
                        usage_tokens,
                        input_hash,
                        summary,
                        suggestions,
                        raw_model_output,
                        chosen_index,
                        outcome,
                        warnings,
                        error
                    ) VALUES (
                        %s, %s, %s, (%s)::jsonb, %s, %s, (%s)::jsonb, (%s)::jsonb, (%s)::jsonb,
                        (%s)::jsonb, (%s)::jsonb, (%s)::jsonb, (%s)::jsonb, (%s)::jsonb,
                        %s, %s, %s, %s, %s, %s, (%s)::jsonb, %s, %s, %s, (%s)::jsonb, %s
                    )
                    ON CONFLICT (request_id) DO UPDATE SET
                        token_id = EXCLUDED.token_id,
                        install_id = EXCLUDED.install_id,
                        client = EXCLUDED.client,
                        capture_mode = EXCLUDED.capture_mode,
                        input_mode = EXCLUDED.input_mode,
                        frontmost_app = EXCLUDED.frontmost_app,
                        screenshot = EXCLUDED.screenshot,
                        image_diagnostics = EXCLUDED.image_diagnostics,
                        ocr_packet = EXCLUDED.ocr_packet,
                        focused_context = EXCLUDED.focused_context,
                        stateful_context = EXCLUDED.stateful_context,
                        consent = EXCLUDED.consent,
                        requested_preferences = EXCLUDED.requested_preferences,
                        model_used = EXCLUDED.model_used,
                        status = EXCLUDED.status,
                        latency_ms = EXCLUDED.latency_ms,
                        usage_tokens = EXCLUDED.usage_tokens,
                        input_hash = EXCLUDED.input_hash,
                        summary = EXCLUDED.summary,
                        suggestions = EXCLUDED.suggestions,
                        raw_model_output = EXCLUDED.raw_model_output,
                        warnings = EXCLUDED.warnings,
                        error = EXCLUDED.error
                    """,
                    (
                        payload["request_id"],
                        payload["token_id"],
                        payload.get("install_id"),
                        json.dumps(payload["client"], ensure_ascii=True),
                        payload["capture_mode"],
                        payload["input_mode"],
                        json.dumps(payload["frontmost_app"], ensure_ascii=True),
                        json.dumps(payload["screenshot"], ensure_ascii=True),
                        json.dumps(payload["image_diagnostics"], ensure_ascii=True),
                        json.dumps(payload["ocr_packet"], ensure_ascii=True),
                        json.dumps(payload["focused_context"], ensure_ascii=True),
                        json.dumps(payload["stateful_context"], ensure_ascii=True),
                        json.dumps(payload["consent"], ensure_ascii=True),
                        json.dumps(payload["requested_preferences"], ensure_ascii=True),
                        payload["model_used"],
                        payload["status"],
                        payload["latency_ms"],
                        payload["usage_tokens"],
                        payload["input_hash"],
                        payload.get("summary"),
                        json.dumps(payload.get("suggestions"), ensure_ascii=True),
                        payload.get("raw_model_output"),
                        payload.get("chosen_index"),
                        payload.get("outcome"),
                        json.dumps(payload["warnings"], ensure_ascii=True),
                        payload["error"],
                    ),
                )
            conn.commit()

    def record_event(self, *, token_id: str, event_type: str, payload: dict[str, Any]) -> bool:
        if not self.enabled or self.database_url is None:
            return False
        self._ensure_schema()
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO tldr_events (
                        request_id,
                        token_id,
                        install_id,
                        event_type,
                        payload
                    ) VALUES (%s, %s, %s, %s, (%s)::jsonb)
                    """,
                    (
                        str(payload.get("request_id") or ""),
                        token_id,
                        payload.get("install_id"),
                        event_type,
                        json.dumps(payload, ensure_ascii=True),
                    ),
                )
            conn.commit()
        return True

    def update_request_outcome(
        self,
        *,
        request_id: str,
        chosen_index: int | None,
        outcome: str,
    ) -> bool:
        if not self.enabled or self.database_url is None:
            return False
        self._ensure_schema()
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE tldr_requests
                    SET chosen_index = %s,
                        outcome = %s
                    WHERE request_id = %s
                    """,
                    (chosen_index, outcome, request_id),
                )
                updated = cur.rowcount > 0
            conn.commit()
        return updated

    def mint_device_token(self, *, install_id: str, token_hash: str) -> None:
        if not self.enabled or self.database_url is None:
            raise RuntimeError("device token storage is not configured")
        self._ensure_schema()
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE device_tokens
                    SET revoked_at = NOW()
                    WHERE install_id = %s
                      AND revoked_at IS NULL
                    """,
                    (install_id,),
                )
                cur.execute(
                    """
                    INSERT INTO device_tokens (
                        token_hash,
                        install_id,
                        revoked_at
                    ) VALUES (%s, %s, NULL)
                    ON CONFLICT (install_id) DO UPDATE SET
                        token_hash = EXCLUDED.token_hash,
                        created_at = NOW(),
                        revoked_at = NULL
                    """,
                    (token_hash, install_id),
                )
            conn.commit()

    def device_token_active(self, token_hash: str) -> bool:
        if not self.enabled or self.database_url is None:
            return False
        self._ensure_schema()
        assert psycopg is not None
        with psycopg.connect(self.database_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT 1
                    FROM device_tokens
                    WHERE token_hash = %s
                      AND revoked_at IS NULL
                    LIMIT 1
                    """,
                    (token_hash,),
                )
                return cur.fetchone() is not None
