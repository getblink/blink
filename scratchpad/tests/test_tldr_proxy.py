"""Focused tests for the TLDR proxy client path."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRATCHPAD_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRATCHPAD_DIR.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scratchpad.tldr_reply.gemini import (  # noqa: E402
    DEFAULT_SETTINGS,
    generate_via_proxy,
    proxy_settings_from_env,
)


class ProxyEnvTests(unittest.TestCase):
    def test_proxy_settings_require_both_values(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_PROXY_URL": "http://localhost:8000"}, clear=True):
            with self.assertRaisesRegex(ValueError, "Set both BLINK_PROXY_URL and BLINK_PROXY_TOKEN"):
                proxy_settings_from_env()

    def test_proxy_settings_return_none_when_disabled(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(proxy_settings_from_env())


class GenerateViaProxyTests(unittest.TestCase):
    def test_generate_via_proxy_returns_normalized_payload(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            image_path = Path(tmpdir) / "screen.png"
            image_path.write_bytes(b"fake-image")

            class FakeResponse:
                def __enter__(self) -> "FakeResponse":
                    return self

                def __exit__(self, exc_type, exc, tb) -> None:
                    return None

                def read(self) -> bytes:
                    return (
                        b'{"tldr":"You need to reply.","suggestions":["One","Two","Three"],'
                        b'"duration_ms":222,"model":"gemini-3.1-flash-lite-preview"}'
                    )

            with mock.patch(
                "scratchpad.tldr_reply.gemini.request.urlopen",
                return_value=FakeResponse(),
            ):
                payload = generate_via_proxy(
                    DEFAULT_SETTINGS,
                    image_path,
                    {"url": "http://localhost:8000", "token": "dev-token"},
                )

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["tldr"], "You need to reply.")
        self.assertEqual(payload["suggestions"], ["One", "Two", "Three"])
        self.assertEqual(payload["duration_ms"], 222)
        self.assertEqual(payload["model"], "gemini-3.1-flash-lite-preview")


if __name__ == "__main__":
    unittest.main()
