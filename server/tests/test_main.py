from __future__ import annotations

import os
import unittest
from unittest import mock

from fastapi.testclient import TestClient

from server.main import app


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_API_TOKENS": "dev-token",
                "GEMINI_API_KEY": "test-key",
            },
        )
        self.env.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.env.stop()

    def test_healthz_returns_ok(self) -> None:
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_tldr_success(self, create_client: mock.Mock, generate: mock.Mock) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're reviewing a plan.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 321,
            "usage": {"total_token_count": 42},
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "tldr": "You're reviewing a plan.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 321,
                "model": "gemini-3.1-flash-lite-preview",
            },
        )

    def test_tldr_rejects_oversized_screenshot(self) -> None:
        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={
                "screenshot": (
                    "screen.png",
                    b"x" * ((10 * 1024 * 1024) + 1),
                    "image/png",
                )
            },
        )

        self.assertEqual(response.status_code, 413)

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_tldr_maps_parse_error_to_503(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "parse_error",
            "tldr": "Gemini returned non-JSON output.",
            "suggestions": ["oops"],
            "duration_ms": 111,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 503)
        self.assertIn("parse_error", response.json()["detail"])

    def test_tldr_rejects_bad_token(self) -> None:
        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer nope"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 401)


if __name__ == "__main__":
    unittest.main()
