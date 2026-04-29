from __future__ import annotations

import os
import unittest
from typing import Any
from unittest import mock

import httpx
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

    def test_proxy_rejects_bad_token(self) -> None:
        response = self.client.post(
            "/v1beta/models/gemini:generateContent",
            headers={"Authorization": "Bearer nope"},
            json={"contents": []},
        )
        self.assertEqual(response.status_code, 401)

    def test_proxy_500_when_server_missing_gemini_key(self) -> None:
        with mock.patch.dict(os.environ, {"GEMINI_API_KEY": ""}):
            response = self.client.post(
                "/v1beta/models/gemini:generateContent",
                headers={"Authorization": "Bearer dev-token"},
                json={"contents": []},
            )
        self.assertEqual(response.status_code, 500)

    def test_proxy_forwards_body_and_swaps_api_key(self) -> None:
        captured: dict[str, Any] = {}

        async def fake_send(self_client: httpx.AsyncClient, req: httpx.Request, stream: bool = False, **_: Any) -> Any:
            captured["url"] = str(req.url)
            captured["headers"] = {k.lower(): v for k, v in req.headers.items()}
            captured["body"] = req.read()
            response = mock.Mock()
            response.status_code = 200
            response.headers = {"content-type": "application/json"}

            async def aiter_raw() -> Any:
                yield b'{"ok":true}'

            async def aclose() -> None:
                return None

            response.aiter_raw = aiter_raw
            response.aclose = aclose
            return response

        with mock.patch.object(httpx.AsyncClient, "send", fake_send):
            response = self.client.post(
                "/v1beta/models/gemini:generateContent",
                headers={
                    "Authorization": "Bearer dev-token",
                    "x-goog-api-key": "client-side-leftover",
                    "Content-Type": "application/json",
                },
                content=b'{"contents":[{"parts":[{"text":"hi"}]}]}',
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b'{"ok":true}')
        # Client's bearer + x-goog-api-key are stripped; server-side key swapped in.
        self.assertEqual(captured["headers"].get("x-goog-api-key"), "test-key")
        self.assertNotIn("authorization", captured["headers"])
        self.assertEqual(
            captured["url"],
            "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent",
        )
        self.assertEqual(captured["body"], b'{"contents":[{"parts":[{"text":"hi"}]}]}')


if __name__ == "__main__":
    unittest.main()
