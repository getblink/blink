"""Tests for target-context field label hints."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from target_context import build_target_ocr_packet, inflate_rect_vertically, target_mode_from_metadata  # noqa: E402
from tests.fixture_helpers import load_fixture  # noqa: E402


def _yc_ocr_payload() -> dict:
    return {
        "status": "ok",
        "blocks": [
            {
                "text": "What is your company going to make?",
                "bbox_pixels": {"x": 120, "y": 110, "width": 560, "height": 28},
                "confidence": 0.99,
            },
            {
                "text": "Company description answer box",
                "bbox_pixels": {"x": 120, "y": 150, "width": 480, "height": 28},
                "confidence": 0.99,
            },
            {
                "text": "Are you looking for a cofounder?",
                "bbox_pixels": {"x": 120, "y": 300, "width": 420, "height": 28},
                "confidence": 0.99,
            },
            {
                "text": "Founder video URL",
                "bbox_pixels": {"x": 120, "y": 520, "width": 260, "height": 28},
                "confidence": 0.99,
            },
        ],
    }


def _google_docs_ocr_payload() -> dict:
    return {
        "status": "ok",
        "blocks": [
            {
                "text": "Target",
                "bbox_pixels": {"x": 40, "y": 250, "width": 120, "height": 28},
                "confidence": 0.99,
            },
            {
                "text": "Contact name:",
                "bbox_pixels": {"x": 260, "y": 360, "width": 210, "height": 32},
                "confidence": 0.99,
            },
            {
                "text": "Phone:",
                "bbox_pixels": {"x": 260, "y": 460, "width": 90, "height": 32},
                "confidence": 0.99,
            },
        ],
    }


def _google_docs_phone_caret_payload() -> dict:
    return {
        "status": "ok",
        "blocks": [
            {
                "text": "Contact name: Sarah Chen",
                "bbox_pixels": {"x": 790, "y": 730, "width": 330, "height": 32},
                "confidence": 0.99,
            },
            {
                "text": "Phone:|",
                "bbox_pixels": {"x": 790, "y": 842, "width": 120, "height": 32},
                "confidence": 0.99,
            },
            {
                "text": "Email:",
                "bbox_pixels": {"x": 790, "y": 960, "width": 90, "height": 32},
                "confidence": 0.99,
            },
        ],
    }


def _google_docs_conflicting_row_payload() -> dict:
    return {
        "status": "ok",
        "blocks": [
            {
                "text": "Email:",
                "bbox_pixels": {"x": 790, "y": 1032, "width": 90, "height": 32},
                "confidence": 0.99,
            },
            {
                "text": "Follow-up date: |",
                "bbox_pixels": {"x": 790, "y": 1070, "width": 260, "height": 32},
                "confidence": 0.99,
            },
        ],
    }


class TargetContextPacketHintTests(unittest.TestCase):
    def test_thin_caret_line_inflation_expands_downward(self) -> None:
        result = inflate_rect_vertically(
            {"x": 992, "y": 726, "width": 1252, "height": 2},
            image_height=1790,
            target_height=40,
        )

        self.assertEqual(result, {"x": 992, "y": 726, "width": 1252, "height": 40})

    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_yc_ocr_payload())
    def test_focused_label_hint_uses_question_above_focus_rect(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 120, "y": 340, "width": 640, "height": 80}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_role": "TextArea",
                "focused_bounds": focused_bounds,
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 0, "width": 1000, "height": 800},
                "focused_bounds_points": focused_bounds,
            },
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(
            result["focused_label_hint"],
            "Are you looking for a cofounder?",
        )
        self.assertEqual(result["build_log"]["focus_hint_reasons"], [])
        self.assertIn("FOCUSED_FIELD_LABEL: Are you looking for a cofounder?", result["packet_text"])
        self.assertNotIn("TARGET_CONTEXT_KIND", result["packet_text"])
        self.assertNotIn("INSERTION_CONTRACT", result["packet_text"])
        self.assertNotIn("FOCUSED_FIELD_RECT", result["packet_text"])
        self.assertNotIn("LIMITS:", result["packet_text"])
        self.assertNotIn("COMPLETENESS:", result["packet_text"])

    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_yc_ocr_payload())
    def test_missing_geometry_falls_back_without_hint(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_role": "TextArea",
                "focused_bounds": {"x": 120, "y": 340, "width": 640, "height": 80},
            },
            geometry={"status": "not_found"},
        )

        self.assertIsNone(result["focused_label_hint"])
        self.assertEqual(result["packet_text"], "")
        self.assertIn("geometry_unavailable", result["fallback_reasons"])

    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_google_docs_ocr_payload())
    def test_google_docs_degenerate_focus_packet_needs_target_image(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 0, "y": 154, "width": 625, "height": 1}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_app_bundle_id": "com.google.Chrome",
                "focused_label": "Document content",
                "focused_description": "Document content",
                "focused_role": "TextArea",
                "focused_value": "\u200b\u200b",
                "focused_bounds": focused_bounds,
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 33, "width": 1512, "height": 895},
                "focused_bounds_points": focused_bounds,
            },
        )

        self.assertEqual(result["completeness"], "needs_target_image")
        self.assertEqual(result["target_mode"], "document_canvas")
        self.assertIn("google_docs_degenerate_focus_rect", result["fallback_reasons"])
        self.assertIn("TARGET_CONTEXT_KIND: document_canvas", result["packet_text"])
        self.assertIn("INSERTION_CONTRACT:", result["packet_text"])

    def test_target_mode_keeps_normal_fields_strict(self) -> None:
        self.assertEqual(
            target_mode_from_metadata(
                {"focused_label": "Email", "focused_role": "TextField"},
                {"focused_bounds_points": {"x": 10, "y": 20, "width": 240, "height": 30}},
            ),
            "strict_field",
        )

    def test_document_content_degenerate_bounds_becomes_document_canvas(self) -> None:
        self.assertEqual(
            target_mode_from_metadata(
                {
                    "focused_label": "Document content",
                    "focused_description": "Document content",
                },
                {"focused_bounds_points": {"x": 10, "y": 20, "width": 625, "height": 1}},
            ),
            "document_canvas",
        )

    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_google_docs_ocr_payload())
    def test_document_canvas_build_log_records_probe_and_annotation_metadata(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 0, "y": 154, "width": 625, "height": 1}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_label": "Document content",
                "focused_description": "Document content",
                "target_copy_probe": {"status": "empty", "item_count": 0},
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 33, "width": 1512, "height": 895},
                "focused_bounds_points": focused_bounds,
                "annotation_metadata": {
                    "source": "swift_focus_line_canvas_region",
                    "annotated_target": "target_annotated.png",
                },
            },
        )

        self.assertEqual(result["build_log"]["target_copy_probe"]["status"], "empty")
        self.assertEqual(
            result["build_log"]["annotation_metadata"]["source"],
            "swift_focus_line_canvas_region",
        )

    @patch("target_context.image_size_pixels", return_value=(3024, 1790))
    @patch("target_context.recognize_text", return_value=_google_docs_phone_caret_payload())
    def test_google_docs_inside_row_caret_text_becomes_focused_label(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 448, "y": 454, "width": 625, "height": 1}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_app_bundle_id": "com.google.Chrome",
                "focused_role": "Group",
                "focused_bounds": focused_bounds,
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 33, "width": 1512, "height": 895},
                "focused_bounds_points": focused_bounds,
            },
        )

        self.assertEqual(result["focused_label_hint"], "Phone:")
        self.assertEqual(result["completeness"], "sufficient")
        self.assertEqual(result["build_log"]["focus_debug"]["local_line_rect"]["y"], 842)
        self.assertEqual(result["build_log"]["focus_rect_local_pixels"]["y"], 842)
        self.assertIn("FOCUSED_FIELD_LABEL: Phone:", result["packet_text"])
        self.assertNotIn("FOCUSED_ROLE", result["packet_text"])
        self.assertNotIn("TEXT_LEFT_OF_FIELD", result["packet_text"])
        self.assertEqual(len(result["build_log"]["ocr_blocks"]), 3)

    @patch("target_context.image_size_pixels", return_value=(3024, 1790))
    @patch("target_context.recognize_text", return_value=_google_docs_conflicting_row_payload())
    def test_google_docs_conflicting_focused_label_fails_closed(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 501, "y": 570, "width": 626, "height": 1}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_app_bundle_id": "com.google.Chrome",
                "focused_role": "Group",
                "focused_bounds": focused_bounds,
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 33, "width": 1512, "height": 895},
                "focused_bounds_points": focused_bounds,
            },
        )

        self.assertEqual(result["focused_label_hint"], "Follow-up date:")
        self.assertEqual(result["completeness"], "sufficient")
        self.assertNotIn("focused_label_conflicts_inside_row", result["fallback_reasons"])

    @patch("target_context.image_size_pixels", return_value=(3024, 1790))
    @patch(
        "target_context.recognize_text",
        return_value={
            "status": "ok",
            "blocks": [
                {
                    "text": "Email:",
                    "bbox_pixels": {"x": 790, "y": 480, "width": 90, "height": 32},
                    "confidence": 0.99,
                }
            ],
        },
    )
    def test_google_docs_missing_focused_label_fails_closed(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 448, "y": 454, "width": 625, "height": 1}
        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_app_bundle_id": "com.google.Chrome",
                "focused_role": "Group",
                "focused_bounds": focused_bounds,
            },
            geometry={
                "status": "ok",
                "window_bounds_points": {"x": 0, "y": 33, "width": 1512, "height": 895},
                "focused_bounds_points": focused_bounds,
            },
        )

        self.assertIsNone(result["focused_label_hint"])
        self.assertEqual(result["completeness"], "needs_target_image")
        self.assertIn("google_docs_missing_focused_label", result["fallback_reasons"])


class ManualGoogleDocsFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = load_fixture("manual_google_docs_target_20260425_205140.json")
        self.thin_line_fixture = load_fixture("manual_google_docs_target_20260426_150826_thin_line.json")
        size = self.fixture["image_size_pixels"]
        self.image_size = (size["width"], size["height"])
        thin_size = self.thin_line_fixture["image_size_pixels"]
        self.thin_line_image_size = (thin_size["width"], thin_size["height"])

    @patch("target_context.image_size_pixels")
    @patch("target_context.recognize_text")
    def test_manual_fixture_builds_expected_needs_image_packet(
        self,
        mock_recognize,
        mock_image_size,
    ) -> None:
        mock_recognize.return_value = self.fixture["target_ocr_payload"]
        mock_image_size.return_value = self.image_size

        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata=self.fixture["target_metadata"],
            geometry=self.fixture["geometry"],
        )
        expected = self.fixture["target_packet_payload"]

        self.assertEqual(result["completeness"], expected["completeness"])
        self.assertEqual(result["fallback_reasons"], expected["fallback_reasons"])
        self.assertEqual(result["target_mode"], "document_canvas")
        self.assertIn("TARGET_CONTEXT_KIND: document_canvas", result["packet_text"])
        self.assertIsNone(result["build_log"]["focus_rect_local_pixels"])
        self.assertEqual(
            result["build_log"]["focus_debug"]["focus_rect_rejected"],
            "google_docs_degenerate_focus_rect",
        )

    @patch("target_context.image_size_pixels")
    @patch("target_context.recognize_text")
    def test_thin_line_fixture_builds_focused_field_packet(
        self,
        mock_recognize,
        mock_image_size,
    ) -> None:
        mock_recognize.return_value = self.thin_line_fixture["target_ocr_payload"]
        mock_image_size.return_value = self.thin_line_image_size

        result = build_target_ocr_packet(
            target_path=Path("/tmp/target.png"),
            target_metadata=self.thin_line_fixture["target_metadata"],
            geometry=self.thin_line_fixture["geometry"],
        )

        self.assertEqual(result["completeness"], "sufficient")
        self.assertEqual(result["fallback_reasons"], [])
        self.assertEqual(result["focused_label_hint"], "Contact name:")
        self.assertEqual(
            result["build_log"]["focus_rect_local_pixels"],
            self.thin_line_fixture["expected"]["focus_rect_local_pixels"],
        )
        self.assertEqual(
            result["build_log"]["focus_debug"]["focus_rect_source"],
            "google_docs_thin_caret_line",
        )
        self.assertIn("FOCUSED_FIELD_LABEL: Contact name:", result["packet_text"])
        self.assertNotIn("INSERTION_CONTRACT", result["packet_text"])

    @patch("target_context.image_size_pixels")
    @patch("target_context.recognize_text")
    def test_thin_line_fixture_all_field_rows_resolve_by_same_row_label(
        self,
        mock_recognize,
        mock_image_size,
    ) -> None:
        mock_recognize.return_value = self.thin_line_fixture["target_ocr_payload"]
        mock_image_size.return_value = self.thin_line_image_size
        base_metadata = self.thin_line_fixture["target_metadata"]
        base_geometry = self.thin_line_fixture["geometry"]

        for label, focused_y in (
            ("Contact name:", 396),
            ("Phone:", 454),
            ("Email:", 512),
            ("Follow-up date:", 570),
            ("Notes:", 628),
        ):
            with self.subTest(label=label):
                focused_bounds = dict(base_metadata["focused_bounds"])
                focused_bounds["y"] = focused_y
                metadata = {**base_metadata, "focused_bounds": focused_bounds}
                geometry = {
                    **base_geometry,
                    "focused_bounds_points": focused_bounds,
                }
                result = build_target_ocr_packet(
                    target_path=Path("/tmp/target.png"),
                    target_metadata=metadata,
                    geometry=geometry,
                )
                self.assertEqual(result["focused_label_hint"], label)
                self.assertEqual(result["completeness"], "sufficient")


if __name__ == "__main__":
    unittest.main()
