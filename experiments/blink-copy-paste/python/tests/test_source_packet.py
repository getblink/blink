"""Unit tests for source-packet helpers."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from gemini_runner import plain_data  # noqa: E402
from source_packet import (  # noqa: E402
    CARET_CONTEXT_AFTER_CHARS,
    CARET_CONTEXT_BEFORE_CHARS,
    _extract_caret_context,
    compact_target_metadata,
    compact_target_metadata_json,
    run_source_packet_target_full_image,
    run_source_packet_target_ocr_packet,
)
from tests.fixture_helpers import load_fixture  # noqa: E402


class PlainDataTests(unittest.TestCase):
    def test_bytes_are_summarized(self) -> None:
        self.assertEqual(
            plain_data(b"abc"),
            {"type": "bytes", "length": 3},
        )


class CompactTargetMetadataTests(unittest.TestCase):
    def _metadata_with_value(self, value: str) -> dict:
        return {
            "status": "ok",
            "frontmost_app": "Google Chrome",
            "focused_app": "Google Chrome",
            "focused_role": "TextArea",
            "focused_value_preview": value[:120],
            "warnings": [],
            "_full": {
                "focused_value": value,
            },
        }

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

    def test_missing_or_unsupported_caret_falls_back_to_existing_text(self) -> None:
        payload = self._metadata_with_value("Calendar event title:")

        for caret in (None, {"status": "not_found"}, {"status": "unsupported"}):
            with self.subTest(caret=caret):
                self.assertEqual(
                    compact_target_metadata(payload, caret=caret)["focused_field"],
                    {
                        "role": "TextArea",
                        "existing_text": "Calendar event title:",
                    },
                )

    def test_zero_width_only_existing_text_is_rendered_as_empty(self) -> None:
        payload = self._metadata_with_value("\u200b\u200b")

        compact = compact_target_metadata(
            payload,
            caret={"status": "ok", "range": {"location": 1, "length": 0}},
        )

        self.assertEqual(compact["focused_field"]["existing_text"], "")
        self.assertNotIn("text_before_caret", compact["focused_field"])

    def test_extracts_mid_string_caret_context_with_windowing(self) -> None:
        before = "a" * (CARET_CONTEXT_BEFORE_CHARS + 5)
        after = "b" * (CARET_CONTEXT_AFTER_CHARS + 5)
        payload = self._metadata_with_value(before + after)

        context = _extract_caret_context(
            payload,
            {"status": "ok", "range": {"location": len(before), "length": 0}},
        )

        self.assertEqual(context["offset"], len(before))
        self.assertEqual(context["selection_length"], 0)
        self.assertEqual(context["before"], "a" * CARET_CONTEXT_BEFORE_CHARS)
        self.assertEqual(context["after"], "b" * CARET_CONTEXT_AFTER_CHARS)

    def test_extracts_selected_text_context(self) -> None:
        payload = self._metadata_with_value("Hello selected world")

        context = _extract_caret_context(
            payload,
            {"status": "ok", "range": {"location": 6, "length": 8}},
        )

        self.assertEqual(context["before"], "Hello ")
        self.assertEqual(context["selected"], "selected")
        self.assertEqual(context["after"], " world")

    def test_caret_offset_past_end_clamps_defensively(self) -> None:
        payload = self._metadata_with_value("short field")

        context = _extract_caret_context(
            payload,
            {"status": "ok", "range": {"location": 99, "length": 0}},
        )

        self.assertEqual(context["offset"], len("short field"))
        self.assertEqual(context["before"], "short field")
        self.assertEqual(context["after"], "")

    def test_line_only_caret_uses_line_split_context(self) -> None:
        payload = self._metadata_with_value("first line\nsecond line\nthird line")

        context = _extract_caret_context(
            payload,
            {"status": "line_only", "line_number": 1},
        )

        self.assertEqual(context["line_number"], 1)
        self.assertEqual(context["before"], "first line\n")
        self.assertEqual(context["after"], "second line\nthird line")

    def test_rendered_split_caret_replaces_existing_text(self) -> None:
        payload = self._metadata_with_value("Calendar event title:\nSlack to coworker:")

        compact = compact_target_metadata(
            payload,
            caret={"status": "ok", "range": {"location": len("Calendar event title:\n"), "length": 0}},
        )

        self.assertEqual(
            compact["focused_field"],
            {
                "role": "TextArea",
                "caret": {
                    "offset": len("Calendar event title:\n"),
                    "selection_length": 0,
                },
                "text_before_caret": "Calendar event title:\n",
                "text_after_caret": "Slack to coworker:",
            },
        )
        self.assertNotIn("existing_text", compact["focused_field"])

    def test_rendered_split_caret_includes_selected_text(self) -> None:
        payload = self._metadata_with_value("Replace this please")

        compact = compact_target_metadata(
            payload,
            caret={"status": "ok", "range": {"location": 8, "length": 4}},
        )

        self.assertEqual(compact["focused_field"]["text_selected"], "this")
        self.assertEqual(compact["focused_field"]["text_before_caret"], "Replace ")
        self.assertEqual(compact["focused_field"]["text_after_caret"], " please")

    def test_google_docs_shaped_metadata_json_snapshots_caret_block(self) -> None:
        payload = self._metadata_with_value(
            "Source:\nCall with Maya tomorrow at 3pm.\n\n"
            "Target:\nCalendar event title:\nSlack to coworker:\n"
        )
        caret_offset = payload["_full"]["focused_value"].index("Slack to coworker:")

        metadata_json = compact_target_metadata_json(
            payload,
            caret={"status": "ok", "range": {"location": caret_offset, "length": 0}},
        )
        compact = json.loads(metadata_json)

        self.assertEqual(compact["app"], "Google Chrome")
        self.assertEqual(
            compact["focused_field"]["caret"],
            {"offset": caret_offset, "selection_length": 0},
        )
        self.assertTrue(compact["focused_field"]["text_before_caret"].endswith("Calendar event title:\n"))
        self.assertEqual(compact["focused_field"]["text_after_caret"], "Slack to coworker:\n")
        self.assertNotIn("existing_text", compact["focused_field"])

    def test_manual_google_docs_fixture_matches_recorded_prompt_metadata(self) -> None:
        fixture = load_fixture("manual_google_docs_target_20260425_205140.json")

        compact = compact_target_metadata(
            fixture["target_metadata"],
            caret=fixture["caret"],
        )

        self.assertEqual(compact, fixture["expected"]["prompt_metadata"])


class PromptAssemblyTests(unittest.TestCase):
    @patch("source_packet.generate_completion")
    def test_ocr_packet_prompt_includes_source_packet_kind(self, mock_generate) -> None:
        mock_generate.return_value = {
            "run_log": {"status": "ok"},
            "output_text": "Sarah Chen",
            "assembled_request_text": "",
        }

        run_source_packet_target_ocr_packet(
            settings={},
            prompt_text="prompt",
            source_packet_text="Sarah Chen\nsarah@example.com",
            source_packet_kind="native_ocr_paragraphs",
            target_packet_text="FOCUSED_FIELD_LABEL: Contact name",
            target_metadata={"status": "ok", "focused_role": "TextArea"},
            runtime={},
        )

        content_items = mock_generate.call_args.kwargs["content_items"]
        instruction = content_items[0]["text"]
        self.assertIn("SOURCE_PACKET_KIND:\nnative_ocr_paragraphs", instruction)
        self.assertEqual(
            mock_generate.call_args.kwargs["request_context"]["source_packet_kind"],
            "native_ocr_paragraphs",
        )

    @patch("source_packet.generate_completion")
    def test_full_image_prompt_includes_source_packet_kind(self, mock_generate) -> None:
        mock_generate.return_value = {
            "run_log": {"status": "ok"},
            "output_text": "Sarah Chen",
            "assembled_request_text": "",
        }

        run_source_packet_target_full_image(
            settings={},
            prompt_text="prompt",
            source_packet_text="EXACT_TEXT:\nSarah Chen",
            source_packet_kind="model_extracted_text",
            target_path=Path("/tmp/target.png"),
            target_metadata={"status": "ok", "focused_role": "TextArea"},
            runtime={},
        )

        content_items = mock_generate.call_args.kwargs["content_items"]
        instruction = content_items[0]["text"]
        self.assertIn("SOURCE_PACKET_KIND:\nmodel_extracted_text", instruction)
        self.assertEqual(
            mock_generate.call_args.kwargs["request_context"]["source_packet_kind"],
            "model_extracted_text",
        )


if __name__ == "__main__":
    unittest.main()
