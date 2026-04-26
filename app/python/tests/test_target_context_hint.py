"""Tests for text-only target field label hints."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from target_context import build_target_ocr_text  # noqa: E402


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


class TargetTextOnlyHintTests(unittest.TestCase):
    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_yc_ocr_payload())
    def test_focused_label_hint_uses_question_above_focus_rect(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        focused_bounds = {"x": 120, "y": 340, "width": 640, "height": 80}
        result = build_target_ocr_text(
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

    @patch("target_context.image_size_pixels", return_value=(1000, 800))
    @patch("target_context.recognize_text", return_value=_yc_ocr_payload())
    def test_missing_geometry_falls_back_without_hint(
        self,
        _mock_recognize,
        _mock_image_size,
    ) -> None:
        result = build_target_ocr_text(
            target_path=Path("/tmp/target.png"),
            target_metadata={
                "focused_role": "TextArea",
                "focused_bounds": {"x": 120, "y": 340, "width": 640, "height": 80},
            },
            geometry={"status": "not_found"},
        )

        self.assertIsNone(result["focused_label_hint"])
        self.assertIn("geometry_unavailable", result["build_log"]["focus_hint_reasons"])


if __name__ == "__main__":
    unittest.main()
