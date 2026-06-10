from __future__ import annotations

import pytest

from server import storage


@pytest.fixture(autouse=True)
def _reset_shared_telemetry_store():
    """Isolate tests from the process-wide TelemetryStore singleton.

    TelemetryStore.shared() memoizes the first from_env() result (including
    its DATABASE_URL and schema_ready state). Without this reset, a test that
    touches the singleton under a patched environment would leak that store
    into every later test in the session.
    """
    with storage._SHARED_STORE_LOCK:
        storage._SHARED_STORE = None
    yield
    with storage._SHARED_STORE_LOCK:
        storage._SHARED_STORE = None
