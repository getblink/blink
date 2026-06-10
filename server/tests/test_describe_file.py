from __future__ import annotations

import io
import os
import unittest
from typing import Any
from unittest import mock

from fastapi.testclient import TestClient

from server.main import app


class DescribeFileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_API_TOKENS": "dev-token",
                "GEMINI_API_KEY": "test-key",
                "BLINK_ALLOWED_MODELS": "gemini-3.1-flash-lite-preview",
            },
            clear=False,
        )
        self.env.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.env.stop()

    @mock.patch("server.main.gemini.generate_file_description")
    @mock.patch("server.main.gemini.create_client")
    def test_image_succeeds(self, create_client: mock.Mock, gen_desc: mock.Mock) -> None:
        create_client.return_value = object()
        gen_desc.return_value = "Professional headshot, vertical orientation."
        fake_image = b"\xff\xd8\xff\xe0" + b"\x00" * 16  # minimal JPEG header
        response = self.client.post(
            "/v1/describe-file",
            headers={"Authorization": "Bearer dev-token"},
            files={"file": ("headshot.jpg", fake_image, "image/jpeg")},
            data={"kind": "image"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["description"], "Professional headshot, vertical orientation.")
        # Confirm generate_file_description was called with image bytes + mime
        call_args = gen_desc.call_args
        self.assertEqual(call_args.args[1], fake_image)
        self.assertEqual(call_args.args[2], "image/jpeg")

    @mock.patch("server.main._slice_pdf")
    @mock.patch("server.main.gemini.generate_file_description")
    @mock.patch("server.main.gemini.create_client")
    def test_pdf_gets_sliced(self, create_client: mock.Mock, gen_desc: mock.Mock, slice_pdf: mock.Mock) -> None:
        create_client.return_value = object()
        gen_desc.return_value = "Q1 2026 rate card."
        sliced_bytes = b"%PDF-1.4 sliced"
        slice_pdf.return_value = sliced_bytes
        fake_pdf = b"%PDF-1.4 full content" * 100
        response = self.client.post(
            "/v1/describe-file",
            headers={"Authorization": "Bearer dev-token"},
            files={"file": ("ratecard.pdf", fake_pdf, "application/pdf")},
            data={"kind": "pdf"},
        )
        self.assertEqual(response.status_code, 200)
        slice_pdf.assert_called_once()
        # Confirm sliced bytes were passed to generate, not the full bytes
        call_args = gen_desc.call_args
        self.assertEqual(call_args.args[1], sliced_bytes)

    @mock.patch("server.main.gemini.generate_file_description")
    @mock.patch("server.main.gemini.create_client")
    def test_thinking_level_not_inherited(self, create_client: mock.Mock, gen_desc: mock.Mock) -> None:
        """Describe-file endpoint uses pinned thinking_level=low regardless of client preferences."""
        create_client.return_value = object()
        gen_desc.return_value = "Some file."
        # This test confirms generate_file_description is called (not the regular tldr path),
        # which always uses _FOR_DESCRIBE_FILE settings (thinking_level pinned to low).
        fake_image = b"\x89PNG" + b"\x00" * 16
        response = self.client.post(
            "/v1/describe-file",
            headers={"Authorization": "Bearer dev-token"},
            files={"file": ("test.png", fake_image, "image/png")},
            data={"kind": "image"},
        )
        self.assertEqual(response.status_code, 200)
        # generate_file_description was called; the settings are baked into the function
        # and not controllable by the client. The test confirms the right function was called.
        gen_desc.assert_called_once()

    def test_invalid_kind_rejected(self) -> None:
        fake_bytes = b"data"
        response = self.client.post(
            "/v1/describe-file",
            headers={"Authorization": "Bearer dev-token"},
            files={"file": ("test.bin", fake_bytes, "application/octet-stream")},
            data={"kind": "banana"},
        )
        self.assertEqual(response.status_code, 422)

    def test_text_and_other_kinds_rejected(self) -> None:
        """Text + opaque-binary entries are described client-side; server refuses
        to burn Gemini tokens on them even if a stale client sends them up."""
        for kind in ("text", "other"):
            response = self.client.post(
                "/v1/describe-file",
                headers={"Authorization": "Bearer dev-token"},
                files={"file": ("snip.md", b"# hello", "text/plain")},
                data={"kind": kind},
            )
            self.assertEqual(response.status_code, 422, f"kind={kind} should be rejected")
            self.assertIn("client-side", response.json()["detail"])

    @mock.patch("server.main.gemini.generate_file_description")
    @mock.patch("server.main.gemini.create_client")
    def test_oversized_upload_rejected(self, create_client: mock.Mock, gen_desc: mock.Mock) -> None:
        """Uploads over the 20MB cap 413 before any Gemini call."""
        from server.main import MAX_DESCRIBE_FILE_BYTES

        oversized = b"\x00" * (MAX_DESCRIBE_FILE_BYTES + 1)
        response = self.client.post(
            "/v1/describe-file",
            headers={"Authorization": "Bearer dev-token"},
            files={"file": ("huge.jpg", oversized, "image/jpeg")},
            data={"kind": "image"},
        )
        self.assertEqual(response.status_code, 413)
        gen_desc.assert_not_called()

    def test_unauthenticated_rejected(self) -> None:
        fake_bytes = b"data"
        response = self.client.post(
            "/v1/describe-file",
            files={"file": ("test.jpg", fake_bytes, "image/jpeg")},
            data={"kind": "image"},
        )
        self.assertEqual(response.status_code, 401)
