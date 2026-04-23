"""Unit tests for the paste-boundary post-processing.

Run from the scratchpad directory:

    ./.venv/bin/python -m unittest tests.test_normalize_for_paste -v
"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

SCRATCHPAD_DIR = Path(__file__).resolve().parent.parent
if str(SCRATCHPAD_DIR) not in sys.path:
    sys.path.insert(0, str(SCRATCHPAD_DIR))

os.environ.setdefault("BLINK_SKIP_VENV_REEXEC", "1")

from run_gemini_trial import _caret_pos_from_capture, normalize_for_paste  # noqa: E402


class NormalizeForPasteTests(unittest.TestCase):
    def test_well_behaved_continuation_no_overlap(self) -> None:
        # Model emitted only the continuation, boundary has a trailing space
        # on the existing text so nothing gets injected in front.
        self.assertEqual(normalize_for_paste("Smith", "John ", 5), "Smith")

    def test_defensive_overlap_trim_when_model_repeats_prefix(self) -> None:
        # Model misbehaved and repeated the field prefix. The overlap
        # search strips the repeated "John " before clipboard hand-off.
        self.assertEqual(normalize_for_paste("John Smith", "John ", 5), "Smith")

    def test_mid_word_boundary_inserts_space(self) -> None:
        # Caret is flush against "John" (no trailing space), so we need
        # a space between the existing text and the continuation.
        self.assertEqual(normalize_for_paste("Smith", "John", 4), " Smith")

    def test_double_space_is_avoided_after_whitespace_boundary(self) -> None:
        # Existing text ends in a space AND the model prepended a space;
        # left-strip keeps us from writing "John  Smith".
        self.assertEqual(normalize_for_paste(" Smith", "John ", 5), "Smith")

    def test_empty_existing_text_passes_through(self) -> None:
        self.assertEqual(normalize_for_paste("anything", None, None), "anything")
        self.assertEqual(normalize_for_paste("anything", "", 0), "anything")

    def test_strips_only_trailing_newline_on_empty_field(self) -> None:
        # When the field is empty, clipboard gets the raw text minus any
        # terminating newline so cmd+V doesn't leave a phantom blank line.
        self.assertEqual(normalize_for_paste("hello\n", None, None), "hello")

    def test_caret_at_start_of_non_empty_field(self) -> None:
        # before_caret is "", so no overlap check, no whitespace injection.
        self.assertEqual(normalize_for_paste("Smith", "John", 0), "Smith")

    def test_caret_beyond_existing_length_does_not_crash(self) -> None:
        # Guard: slicing past the end still works; behaves as if caret were
        # at the final character.
        self.assertEqual(normalize_for_paste("Smith", "John", 99), " Smith")

    def test_overlap_at_whitespace_boundary(self) -> None:
        # Model repeated a trailing space before its continuation. Overlap
        # strip removes the duplicated space and the lstrip path keeps the
        # rest of the word intact.
        self.assertEqual(normalize_for_paste(" Smith", "John ", 5), "Smith")

    def test_newline_boundary_lstrips_leading_spaces(self) -> None:
        # When the prior line ends and model adds indentation, we normalize
        # the leading spaces away (lstrip strips " \t" only).
        self.assertEqual(normalize_for_paste("  continued", "line\n", 5), "continued")

    def test_overlap_without_trailing_whitespace_keeps_internal_space(self) -> None:
        # Model emitted the full "John Smith" against a non-space boundary.
        # Overlap strip takes off "John"; the leading space that's left is
        # the actual separator before the continuation, so we keep it.
        self.assertEqual(normalize_for_paste("John Smith", "John", 4), " Smith")

    def test_trailing_newline_stripped_on_non_empty_field(self) -> None:
        # The prompt tells the model not to worry about boundary whitespace;
        # strip trailing newlines in the non-empty-field path too.
        self.assertEqual(normalize_for_paste("Smith\n", "John ", 5), "Smith")


class CaretPosFromCaptureTests(unittest.TestCase):
    def test_ok_status_with_range_returns_location(self) -> None:
        caret = {"status": "ok", "range": {"location": 12, "length": 0}}
        self.assertEqual(_caret_pos_from_capture(caret), 12)

    def test_missing_returns_none(self) -> None:
        self.assertIsNone(_caret_pos_from_capture(None))
        self.assertIsNone(_caret_pos_from_capture({"status": "not_found"}))
        self.assertIsNone(_caret_pos_from_capture({"status": "line_only", "line_number": 3}))
        self.assertIsNone(_caret_pos_from_capture({"status": "ok"}))  # missing range


if __name__ == "__main__":
    unittest.main()
