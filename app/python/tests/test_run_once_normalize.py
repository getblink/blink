"""Unit tests for tester-loop paste normalization helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from run_once import _caret_pos_from_capture, normalize_for_paste  # noqa: E402


class NormalizeForPasteTests(unittest.TestCase):
    def test_well_behaved_continuation_no_overlap(self) -> None:
        self.assertEqual(normalize_for_paste("Smith", "John ", 5), "Smith")

    def test_defensive_overlap_trim_when_model_repeats_prefix(self) -> None:
        self.assertEqual(normalize_for_paste("John Smith", "John ", 5), "Smith")

    def test_mid_word_boundary_inserts_space(self) -> None:
        self.assertEqual(normalize_for_paste("Smith", "John", 4), " Smith")

    def test_double_space_is_avoided_after_whitespace_boundary(self) -> None:
        self.assertEqual(normalize_for_paste(" Smith", "John ", 5), "Smith")

    def test_empty_existing_text_passes_through(self) -> None:
        self.assertEqual(normalize_for_paste("anything", None, None), "anything")
        self.assertEqual(normalize_for_paste("anything", "", 0), "anything")

    def test_strips_only_trailing_newline_on_empty_field(self) -> None:
        self.assertEqual(normalize_for_paste("hello\n", None, None), "hello")

    def test_caret_at_start_of_non_empty_field(self) -> None:
        self.assertEqual(normalize_for_paste("Smith", "John", 0), "Smith")

    def test_caret_beyond_existing_length_does_not_crash(self) -> None:
        self.assertEqual(normalize_for_paste("Smith", "John", 99), " Smith")

    def test_overlap_at_whitespace_boundary(self) -> None:
        self.assertEqual(normalize_for_paste(" Smith", "John ", 5), "Smith")

    def test_newline_boundary_lstrips_leading_spaces(self) -> None:
        self.assertEqual(normalize_for_paste("  continued", "line\n", 5), "continued")

    def test_overlap_without_trailing_whitespace_keeps_internal_space(self) -> None:
        self.assertEqual(normalize_for_paste("John Smith", "John", 4), " Smith")

    def test_trailing_newline_stripped_on_non_empty_field(self) -> None:
        self.assertEqual(normalize_for_paste("Smith\n", "John ", 5), "Smith")


class CaretPosFromCaptureTests(unittest.TestCase):
    def test_ok_status_with_range_returns_location(self) -> None:
        caret = {"status": "ok", "range": {"location": 12, "length": 0}}
        self.assertEqual(_caret_pos_from_capture(caret), 12)

    def test_missing_returns_none(self) -> None:
        self.assertIsNone(_caret_pos_from_capture(None))
        self.assertIsNone(_caret_pos_from_capture({"status": "not_found"}))
        self.assertIsNone(_caret_pos_from_capture({"status": "line_only", "line_number": 3}))
        self.assertIsNone(_caret_pos_from_capture({"status": "ok"}))


if __name__ == "__main__":
    unittest.main()
