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
    NATIVE_SOURCE_PACKET_KIND,
    SOURCE_TEXT_PARAMETERS,
    build_local_source_text_packet,
    build_native_ocr_source_packet,
    _split_prompt_body_text,
)
from target_context import choose_text_only_target_path  # noqa: E402


class LocalSourceTextPacketTests(unittest.TestCase):
    def test_local_source_text_packet_preserves_multiline_formatting(self) -> None:
        result = build_local_source_text_packet(
            {
                "status": "ok",
                "method": "cmd_c",
                "text": "\r\nFirst paragraph.\r\n\r\n  - indented item\r\n    continued\r\n",
                "text_chars": 56,
                "truncated": False,
                "warnings": [],
            }
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["source_packet_kind"], LOCAL_SOURCE_TEXT_PACKET_KIND)
        self.assertEqual(
            result["packet_text"],
            "First paragraph.\n\n  - indented item\n    continued",
        )

    def test_local_source_text_packet_rejects_invalid_text_chars_without_raising(self) -> None:
        result = build_local_source_text_packet(
            {
                "status": "ok",
                "method": "cmd_c",
                "text": "hello",
                "text_chars": "not-a-number",
                "truncated": False,
            }
        )

        self.assertEqual(result["status"], "error")
        self.assertIn("source_text_chars_invalid", result["build_log"]["errors"])


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

    @patch("source_ocr.recognize_text")
    def test_native_ocr_drops_toolbar_lines_and_splits_prompt_body(self, mock_recognize) -> None:
        long_prompt_body = (
            "What is your company going to make? Please describe your product and what it does "
            "or will do. irun multiple ai agents at once and constantly forget what each thread "
            "is about. blink is a context layer for multi-agent power users."
        )
        mock_recognize.return_value = {
            "status": "ok",
            "image_size_pixels": {"width": 1400, "height": 1000},
            "blocks": [
                {
                    "text": "Tools Gemini Extensions Help",
                    "bbox_pixels": {"x": 120, "y": 60, "width": 320, "height": 24},
                    "confidence": 0.99,
                },
                {
                    "text": "Arial - 11 + BIU :",
                    "bbox_pixels": {"x": 120, "y": 95, "width": 220, "height": 24},
                    "confidence": 0.99,
                },
                {
                    "text": "1 2 3 5",
                    "bbox_pixels": {"x": 124, "y": 130, "width": 90, "height": 22},
                    "confidence": 0.97,
                },
                {
                    "text": "Describe what your company does in 50 characters or less.*",
                    "bbox_pixels": {"x": 120, "y": 250, "width": 520, "height": 26},
                    "confidence": 0.98,
                },
                {
                    "text": "context layer for multi-agent ai power users",
                    "bbox_pixels": {"x": 122, "y": 288, "width": 430, "height": 26},
                    "confidence": 0.98,
                },
                {
                    "text": long_prompt_body,
                    "bbox_pixels": {"x": 120, "y": 380, "width": 1040, "height": 30},
                    "confidence": 0.97,
                },
            ],
        }

        result = build_native_ocr_source_packet(source_path=Path("/tmp/source.png"))

        self.assertEqual(result["status"], "ok")
        self.assertNotIn("Tools Gemini Extensions Help", result["packet_text"])
        self.assertNotIn("Arial - 11 + BIU", result["packet_text"])
        self.assertNotIn("1 2 3 5", result["packet_text"])
        self.assertIn("or will do.\n\nirun multiple ai agents", result["packet_text"])
        self.assertEqual(result["build_log"]["dropped_line_count"], 3)
        self.assertEqual(len(result["build_log"]["split_lines"]), 1)

    def test_prompt_body_splitter_does_not_split_legitimate_prose_question_word(self) -> None:
        text = (
            "What we built. We built a context layer for multi-agent power users that keeps "
            "many AI work threads available without losing the current task, source material, "
            "or intended paste target."
        )

        self.assertEqual(_split_prompt_body_text(text), [text])


class TextOnlyTargetPathTests(unittest.TestCase):
    def test_allowed_role_with_ocr_text_uses_text_only(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={"focused_role": "TextArea"},
            target_ocr_text_payload={"status": "ok", "text": "Founder experience"},
        )

        self.assertEqual(result, {"mode": "text_only"})

    def test_prefixed_role_is_also_accepted(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={"focused_role": "AXTextArea"},
            target_ocr_text_payload={"status": "ok", "text": "Founder experience"},
        )

        self.assertEqual(result, {"mode": "text_only"})

    def test_missing_role_falls_back_to_full_target_image(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={},
            target_ocr_text_payload={"status": "ok", "text": "Founder experience"},
        )

        self.assertEqual(
            result,
            {"mode": "full_target_image", "fallback_reason": "missing_focused_role"},
        )

    def test_disallowed_role_falls_back_to_full_target_image(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={"focused_role": "AXButton"},
            target_ocr_text_payload={"status": "ok", "text": "Submit"},
        )

        self.assertEqual(
            result,
            {"mode": "full_target_image", "fallback_reason": "focused_role_not_allowed"},
        )

    def test_ocr_error_falls_back_to_full_target_image(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={"focused_role": "AXTextField"},
            target_ocr_text_payload={"status": "error", "text": ""},
        )

        self.assertEqual(
            result,
            {"mode": "full_target_image", "fallback_reason": "target_ocr_not_ok"},
        )

    def test_empty_text_falls_back_to_full_target_image(self) -> None:
        result = choose_text_only_target_path(
            target_metadata={"focused_role": "AXSearchField"},
            target_ocr_text_payload={"status": "ok", "text": "   "},
        )

        self.assertEqual(
            result,
            {"mode": "full_target_image", "fallback_reason": "empty_target_ocr_text"},
        )


class LocalOnlyPathCredentialBypassTests(unittest.TestCase):
    @patch("source_ocr.recognize_text")
    @patch("prepare_source.resolve_runtime_settings")
    def test_prepare_source_prefers_source_text_and_skips_runtime_resolution(
        self,
        mock_resolve_runtime_settings,
        mock_recognize,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            source_text_path = temp_path / "source_text.json"
            runtime_path = temp_path / "runtime.json"
            source_path.write_bytes(b"fake")
            source_text_path.write_text(
                json.dumps(
                    {
                        "status": "ok",
                        "method": "cmd_c",
                        "text": "line one\n\n  - line two",
                        "text_chars": 22,
                        "truncated": False,
                        "warnings": [],
                    }
                ),
                encoding="utf-8",
            )
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

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
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

        payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["source_packet_kind"], LOCAL_SOURCE_TEXT_PACKET_KIND)
        self.assertEqual(payload["packet_text"], "line one\n\n  - line two")
        mock_resolve_runtime_settings.assert_not_called()
        mock_recognize.assert_not_called()

    @patch("source_ocr.recognize_text")
    @patch("prepare_source.resolve_runtime_settings")
    def test_prepare_source_empty_source_text_falls_back_to_native_ocr(
        self,
        mock_resolve_runtime_settings,
        mock_recognize,
    ) -> None:
        mock_recognize.return_value = {
            "status": "ok",
            "image_size_pixels": {"width": 800, "height": 600},
            "blocks": [
                {
                    "text": "ocr fallback",
                    "bbox_pixels": {"x": 100, "y": 220, "width": 220, "height": 28},
                    "confidence": 0.99,
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            source_text_path = temp_path / "source_text.json"
            runtime_path = temp_path / "runtime.json"
            source_path.write_bytes(b"fake")
            source_text_path.write_text(
                json.dumps({"status": "no_text", "method": "cmd_c", "text": ""}),
                encoding="utf-8",
            )
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

            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
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

        payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["source_packet_kind"], NATIVE_SOURCE_PACKET_KIND)
        self.assertEqual(payload["packet_text"], "ocr fallback")
        self.assertIn("source_text_attempt", payload["build_log"])
        mock_resolve_runtime_settings.assert_not_called()

    def test_prepared_source_matches_local_source_text_kind(self) -> None:
        source_text_payload = {
            "status": "ok",
            "method": "cmd_c",
            "text": "hello",
            "text_chars": 5,
            "truncated": False,
        }
        source_packet = build_local_source_text_packet(source_text_payload)
        prepared_source = {
            "status": "ok",
            "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
            "packet_text": "hello",
            "runtime_signature": {
                "request_mode": "source_ocr_target_text_or_full_image",
                "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
                "source_text_parameters": dict(SOURCE_TEXT_PARAMETERS),
                "source_text_digest": source_packet["source_text_digest"],
            },
        }

        self.assertTrue(
            run_once._prepared_source_matches(
                prepared_source,
                {"request_mode": "source_ocr_target_text_or_full_image"},
                None,
                source_text_payload,
            )
        )

    def test_prepared_source_rejects_stale_local_source_text_kind(self) -> None:
        stale_packet = build_local_source_text_packet(
            {
                "status": "ok",
                "method": "cmd_c",
                "text": "old source",
                "text_chars": 10,
                "truncated": False,
            }
        )
        prepared_source = {
            "status": "ok",
            "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
            "packet_text": "old source",
            "runtime_signature": {
                "request_mode": "source_ocr_target_text_or_full_image",
                "source_packet_kind": LOCAL_SOURCE_TEXT_PACKET_KIND,
                "source_text_parameters": dict(SOURCE_TEXT_PARAMETERS),
                "source_text_digest": stale_packet["source_text_digest"],
            },
        }

        self.assertFalse(
            run_once._prepared_source_matches(
                prepared_source,
                {"request_mode": "source_ocr_target_text_or_full_image"},
                None,
                {
                    "status": "ok",
                    "method": "cmd_c",
                    "text": "new source",
                    "text_chars": 10,
                    "truncated": False,
                },
            )
        )

    def test_resolve_settings_requires_provider_preset_id(self) -> None:
        with self.assertRaisesRegex(ValueError, "provider_preset.id"):
            run_once._resolve_settings(
                {},
                {
                    "request_mode": "baseline_full_images",
                    "provider_preset": {
                        "provider": "openai",
                        "api_key_env": "OPENAI_API_KEY",
                    },
                    "model": "dummy-model",
                },
            )

    @patch("run_once.run_source_packet_target_text_only")
    @patch("run_once.choose_text_only_target_path")
    @patch("run_once.build_target_ocr_text")
    @patch("run_once.build_source_packet_with_fallback")
    @patch("run_once.resolve_runtime_settings")
    def test_run_once_hybrid_empty_source_text_uses_shared_fallback(
        self,
        mock_resolve_runtime_settings,
        mock_build_source_packet_with_fallback,
        mock_build_target_ocr_text,
        mock_choose_text_only_target_path,
        mock_run_source_packet_target_text_only,
    ) -> None:
        mock_resolve_runtime_settings.return_value = {}
        mock_build_source_packet_with_fallback.return_value = {
            "status": "ok",
            "source_packet_kind": NATIVE_SOURCE_PACKET_KIND,
            "packet_text": "ocr fallback",
            "build_ms": 1.2,
            "build_log": {"status": "ok"},
        }
        mock_build_target_ocr_text.return_value = {
            "status": "ok",
            "text": "Target field",
            "text_chars": 12,
            "build_log": {"status": "ok"},
        }
        mock_choose_text_only_target_path.return_value = {"mode": "text_only"}
        mock_run_source_packet_target_text_only.return_value = {
            "output_text": "generated",
            "assembled_request_text": "request",
            "run_log": {
                "status": "ok",
                "request": {},
                "response": {},
                "timings": {},
            },
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            source_path = temp_path / "source.png"
            target_path = temp_path / "target.png"
            source_text_path = temp_path / "source_text.json"
            runtime_path = temp_path / "runtime.json"
            prompt_path = temp_path / "prompt.txt"
            target_meta_path = temp_path / "target_meta.json"
            out_dir = temp_path / "out"
            source_path.write_bytes(b"fake")
            target_path.write_bytes(b"fake")
            prompt_path.write_text("prompt", encoding="utf-8")
            source_text_path.write_text(
                json.dumps({"status": "no_text", "method": "cmd_c", "text": ""}),
                encoding="utf-8",
            )
            target_meta_path.write_text(
                json.dumps({"status": "ok", "focused_role": "TextArea"}),
                encoding="utf-8",
            )
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
                        "paths": {
                            "source_packet_target_prompt": str(prompt_path),
                            "target_text_only_prompt": str(prompt_path),
                        },
                    }
                ),
                encoding="utf-8",
            )

            with contextlib.redirect_stdout(io.StringIO()) as stdout:
                exit_code = run_once.main(
                    [
                        "--source",
                        str(source_path),
                        "--target",
                        str(target_path),
                        "--target-meta",
                        str(target_meta_path),
                        "--runtime",
                        str(runtime_path),
                        "--source-text",
                        str(source_text_path),
                        "--out-dir",
                        str(out_dir),
                        "--bundle-id",
                        "test-bundle",
                        "--silent-stderr",
                    ]
                )

        self.assertEqual(exit_code, 0)
        self.assertEqual(stdout.getvalue(), "generated")
        mock_build_source_packet_with_fallback.assert_called_once()
        self.assertEqual(
            mock_build_source_packet_with_fallback.call_args.kwargs["source_text_payload"]["status"],
            "no_text",
        )

    @patch("source_ocr.recognize_text")
    @patch("prepare_source.resolve_runtime_settings")
    def test_prepare_source_native_ocr_mode_skips_runtime_resolution(
        self,
        mock_resolve_runtime_settings,
        mock_recognize,
    ) -> None:
        mock_recognize.return_value = {
            "status": "ok",
            "image_size_pixels": {"width": 800, "height": 600},
            "blocks": [
                {
                    "text": "hello",
                    "bbox_pixels": {"x": 100, "y": 220, "width": 120, "height": 28},
                    "confidence": 0.99,
                }
            ],
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
