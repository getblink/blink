"""Unit tests for source-packet helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from gemini_runner import plain_data  # noqa: E402
from source_packet import compact_target_metadata, run_source_packet_target_text_only  # noqa: E402


class PlainDataTests(unittest.TestCase):
    def test_bytes_are_summarized(self) -> None:
        self.assertEqual(
            plain_data(b"abc"),
            {"type": "bytes", "length": 3},
        )


class CompactTargetMetadataTests(unittest.TestCase):
    def test_compacts_prompt_shape_for_happy_path(self) -> None:
        payload = {
            "status": "ok",
            "frontmost_app": "Microsoft Edge",
            "focused_app": "Microsoft Edge",
            "focused_role": "TextArea",
            "focused_title": "FOUNDER EXPERIENCE *",
            "focused_label": "",
            "focused_description": "",
            "focused_value_preview": "",
            "warnings": [],
            "_full": {
                "focused_value": "",
            },
        }

        self.assertEqual(
            compact_target_metadata(payload),
            {
                "status": "ok",
                "app": "Microsoft Edge",
                "focused_field": {
                    "role": "TextArea",
                    "title": "FOUNDER EXPERIENCE *",
                    "existing_text": "",
                },
            },
        )

    def test_keeps_debug_fields_when_status_is_not_ok(self) -> None:
        payload = {
            "status": "permission_denied",
            "workspace_frontmost_app": "Google Chrome",
            "permission": {"accessibility_trusted": False},
            "warnings": ["accessibility_not_trusted"],
            "error": "accessibility_not_trusted",
            "error_detail": None,
            "_full": {},
        }

        self.assertEqual(
            compact_target_metadata(payload),
            {
                "status": "permission_denied",
                "app": "Google Chrome",
                "permission": {"accessibility_trusted": False},
                "warnings": ["accessibility_not_trusted"],
                "error": "accessibility_not_trusted",
            },
        )


class TextOnlyPromptAssemblyTests(unittest.TestCase):
    @patch("source_packet.generate_completion")
    def test_focused_label_hint_is_added_to_instruction(self, mock_generate) -> None:
        mock_generate.return_value = {
            "run_log": {"status": "ok"},
            "output_text": "currently a solo founder",
            "assembled_request_text": "",
        }

        run_source_packet_target_text_only(
            settings={},
            prompt_text="prompt",
            source_packet_text="Are you looking for a cofounder? currently a solo founder",
            target_ocr_text="What is your company going to make?\nAre you looking for a cofounder?",
            target_metadata={"status": "ok", "focused_role": "TextArea"},
            runtime={},
            focused_label_hint="Are you looking for a cofounder?",
        )

        content_items = mock_generate.call_args.kwargs["content_items"]
        instruction = content_items[0]["text"]
        self.assertIn("TARGET_FIELD_HINT", instruction)
        self.assertIn("Are you looking for a cofounder?", instruction)
        self.assertEqual(
            mock_generate.call_args.kwargs["request_context"]["focused_label_hint_chars"],
            len("Are you looking for a cofounder?"),
        )


if __name__ == "__main__":
    unittest.main()
