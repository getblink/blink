"""Unit tests for the hybrid OCR request mode helpers."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

import prepare_source  # noqa: E402
import run_once  # noqa: E402
from source_ocr import (  # noqa: E402
    LOCAL_SOURCE_TEXT_PACKET_KIND,
    NATIVE_SOURCE_OCR_REQUEST_MODE,
    SOURCE_TEXT_PARAMETERS,
    build_local_source_text_packet,
    build_native_ocr_source_packet,
)


class NativeSourcePacketTests(unittest.TestCase):
    @patch("source_ocr.recognize_text")
    def test_build_native_ocr_source_packet_uses_main_band_paragraphs(self, mock_recognize) -> None:
        mock_recognize.return_value = {
            "status": "ok",
            "image_size_pixels": {"width": 1000, "height": 800},
            "blocks": [
                {
                    "text": "description",
                    "bbox_pixels": {"x": 120, "y": 100, "width": 160, "height": 28},
                    "confidence": 0.99,
                },
                {
                    "text": "blink helps me keep multiple agent threads straight",
                    "bbox_pixels": {"x": 118, "y": 134, "width": 520, "height": 30},
                    "confidence": 0.98,
                },
                {
                    "text": "solo founder with prior agent tooling experience",
                    "bbox_pixels": {"x": 122, "y": 230, "width": 460, "height": 30},
                    "confidence": 0.97,
                },
                {
                    "text": "sidebar chrome",
                    "bbox_pixels": {"x": 830, "y": 130, "width": 120, "height": 24},
                    "confidence": 0.96,
                },
            ],
        }

        result = build_native_ocr_source_packet(source_path=Path("/tmp/source.png"))

        self.assertEqual(result["status"], "ok")
        self.assertEqual(
            result["packet_text"],
            "description blink helps me keep multiple agent threads straight\n\n"
            "solo founder with prior agent tooling experience",
        )
        self.assertEqual(result["source_packet_kind"], "native_ocr_paragraphs")
        self.assertEqual(result["build_log"]["raw_block_count"], 4)
        self.assertEqual(result["build_log"]["filtered_block_count"], 3)
        self.assertEqual(result["build_log"]["paragraph_count"], 2)
        self.assertEqual(result["build_log"]["raw_line_count"], 3)
        self.assertEqual(result["build_log"]["dropped_line_count"], 0)
        self.assertEqual(len(result["build_log"]["ocr_blocks"]), 4)
        self.assertEqual(result["build_log"]["filtered_block_ranks"], [1, 3, 4])
        self.assertEqual([line["text"] for line in result["build_log"]["kept_lines"]], [
            "description",
            "blink helps me keep multiple agent threads straight",
            "solo founder with prior agent tooling experience",
        ])

    @patch("source_ocr.recognize_text")
    def test_build_native_ocr_source_packet_can_skip_band_and_chrome_filters(
        self,
        mock_recognize,
    ) -> None:
        mock_recognize.return_value = {
            "status": "ok",
            "image_size_pixels": {"width": 1000, "height": 800},
            "blocks": [
                {
                    "text": "main thread",
                    "bbox_pixels": {"x": 120, "y": 140, "width": 160, "height": 28},
                    "confidence": 0.99,
                },
                {
                    "text": "sidebar reminder",
                    "bbox_pixels": {"x": 830, "y": 145, "width": 120, "height": 24},
                    "confidence": 0.96,
                },
            ],
        }

        result = build_native_ocr_source_packet(
            source_path=Path("/tmp/source.png"),
            apply_band_filter=False,
            apply_chrome_filter=False,
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["packet_variant"], "raw_lines_no_band_or_chrome_filter")
        self.assertIn("main thread", result["packet_text"])
        self.assertIn("sidebar reminder", result["packet_text"])
        self.assertIsNone(result["build_log"]["dominant_band"])
        self.assertFalse(result["build_log"]["apply_band_filter"])
        self.assertFalse(result["build_log"]["apply_chrome_filter"])


class SourceTextPacketTests(unittest.TestCase):
    def test_local_source_text_packet_preserves_multiline_formatting(self) -> None:
        result = build_local_source_text_packet(
            {
                "status": "ok",
                "method": "ax_selected_text",
                "text": "\nFounder notes\n\n- shipped prototype\n- dogfooding now\n",
                "text_chars": 50,
                "truncated": False,
                "warnings": [],
            }
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["source_packet_kind"], LOCAL_SOURCE_TEXT_PACKET_KIND)
        self.assertEqual(
            result["packet_text"],
            "Founder notes\n\n- shipped prototype\n- dogfooding now",
        )
        self.assertIsNotNone(result["source_text_digest"])
        self.assertEqual(result["build_log"]["parameters"], SOURCE_TEXT_PARAMETERS)

    def test_local_source_text_packet_rejects_invalid_text_chars_without_raising(self) -> None:
        result = build_local_source_text_packet(
            {
                "status": "ok",
                "method": "cmd_c",
                "text": "hello",
                "text_chars": "not-a-number",
            }
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("source_text_chars_invalid", result["build_log"]["errors"])

    def test_prepared_source_matches_local_source_text_digest(self) -> None:
        source_text_payload = {
            "status": "ok",
            "method": "cmd_c",
            "text": "A\n\nB",
            "text_chars": 4,
        }
        source_packet = build_local_source_text_packet(source_text_payload)
        prepared = {
            "status": "ok",
            "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
            "packet_text": source_packet["packet_text"],
            "runtime_signature": {
                "request_mode": NATIVE_SOURCE_OCR_REQUEST_MODE,
                "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
                "source_text_parameters": dict(SOURCE_TEXT_PARAMETERS),
                "source_text_digest": source_packet["source_text_digest"],
            },
        }

        self.assertTrue(
            run_once._prepared_source_matches(
                prepared,
                {"request_mode": NATIVE_SOURCE_OCR_REQUEST_MODE},
                None,
                source_text_payload,
            )
        )
        self.assertFalse(
            run_once._prepared_source_matches(
                prepared,
                {"request_mode": NATIVE_SOURCE_OCR_REQUEST_MODE},
                None,
                {"status": "ok", "method": "cmd_c", "text": "changed", "text_chars": 7},
            )
        )

    def test_warm_worker_request_threads_source_text_argument(self) -> None:
        self.assertEqual(
            run_once._argv_from_request({"source_text": "/tmp/source_text.json"}),
            ["--source-text", "/tmp/source_text.json"],
        )


class LocalOnlyPathCredentialBypassTests(unittest.TestCase):
    @patch("prepare_source.build_source_packet_with_fallback")
    @patch("prepare_source.resolve_runtime_settings")
    def test_prepare_source_native_ocr_mode_skips_runtime_resolution(
        self,
        mock_resolve_runtime_settings,
        mock_build_source_packet_with_fallback,
    ) -> None:
        mock_build_source_packet_with_fallback.return_value = {
            "status": "ok",
            "source_packet_kind": "native_ocr_paragraphs",
            "packet_text": "hello",
            "build_log": {"status": "ok"},
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            source_text_path = temp_path / "source_text.json"
            source_path.write_bytes(b"fake")
            source_text_path.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "method": "cmd_c",
                        "text": "hello",
                        "text_chars": 5,
                    }
                ),
                encoding="utf-8",
            )
            runtime_path = temp_path / "runtime.json"
            runtime_path.write_text(
                json.dumps(
                    {
                        "request_mode": "source_ocr_target_text_or_full_image",
                        "provider_preset": {
                            "id": "dummy",
                            "provider": "openai",
                            "api_key_env": "MISSING_KEY",
                        },
                        "model": "dummy-model",
                        "paths": {},
                    }
                ),
                encoding="utf-8",
            )

            with contextlib.redirect_stdout(io.StringIO()):
                exit_code = prepare_source.main(
                    [
                        "--source",
                        str(source_path),
                        "--runtime",
                        str(runtime_path),
                        "--source-text",
                        str(source_text_path),
                        "--silent-stderr",
                    ]
                )

        self.assertEqual(exit_code, 0)
        mock_resolve_runtime_settings.assert_not_called()
        self.assertEqual(
            mock_build_source_packet_with_fallback.call_args.kwargs["source_text_payload"]["method"],
            "cmd_c",
        )

    @patch("run_once.resolve_runtime_settings")
    def test_run_once_skip_gemini_skips_runtime_resolution(self, mock_resolve_runtime_settings) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            target_path = temp_path / "target.png"
            out_dir = temp_path / "out"
            runtime_path = temp_path / "runtime.json"
            source_path.write_bytes(b"fake")
            target_path.write_bytes(b"fake")
            runtime_path.write_text(
                json.dumps(
                    {
                        "request_mode": "baseline_full_images",
                        "provider_preset": {
                            "id": "dummy",
                            "provider": "openai",
                            "api_key_env": "MISSING_KEY",
                        },
                        "model": "dummy-model",
                        "paths": {},
                    }
                ),
                encoding="utf-8",
            )

            with contextlib.redirect_stdout(io.StringIO()):
                exit_code = run_once.main(
                    [
                        "--source",
                        str(source_path),
                        "--target",
                        str(target_path),
                        "--runtime",
                        str(runtime_path),
                        "--out-dir",
                        str(out_dir),
                        "--skip-gemini",
                        "--bundle-id",
                        "test-bundle",
                        "--silent-stderr",
                    ]
                )

        self.assertEqual(exit_code, 0)
        mock_resolve_runtime_settings.assert_not_called()


if __name__ == "__main__":
    unittest.main()
