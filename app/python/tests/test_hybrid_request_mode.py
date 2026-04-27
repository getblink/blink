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
from source_ocr import build_native_ocr_source_packet  # noqa: E402


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
        self.assertEqual(len(result["build_log"]["ocr_blocks"]), 4)
        self.assertEqual(result["build_log"]["filtered_block_ranks"], [1, 3, 4])


class LocalOnlyPathCredentialBypassTests(unittest.TestCase):
    @patch("prepare_source.build_native_ocr_source_packet")
    @patch("prepare_source.resolve_runtime_settings")
    def test_prepare_source_native_ocr_mode_skips_runtime_resolution(
        self,
        mock_resolve_runtime_settings,
        mock_build_native_ocr_source_packet,
    ) -> None:
        mock_build_native_ocr_source_packet.return_value = {
            "status": "ok",
            "source_packet_kind": "native_ocr_paragraphs",
            "packet_text": "hello",
            "build_log": {"status": "ok"},
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            source_path.write_bytes(b"fake")
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
                        "--silent-stderr",
                    ]
                )

        self.assertEqual(exit_code, 0)
        mock_resolve_runtime_settings.assert_not_called()

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
