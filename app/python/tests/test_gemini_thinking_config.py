"""Tests for Gemini generation-config compatibility helpers."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from gemini_runner import (  # noqa: E402
    _gemini_thinking_kwargs,
    normalized_model_name,
    thinking_config_kwargs,
)


class GeminiThinkingConfigTests(unittest.TestCase):
    def test_gemini_3_uses_thinking_level(self) -> None:
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-3.1-flash-lite-preview", "MINIMAL"),
            {"include_thoughts": False, "thinking_level": "MINIMAL"},
        )

    def test_gemini_25_flash_lite_uses_minimal_budget(self) -> None:
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-2.5-flash-lite", "MINIMAL"),
            {"include_thoughts": False, "thinking_budget": 0},
        )

    def test_gemini_25_flash_uses_minimal_budget(self) -> None:
        # Pins the broader 2.5 branch — 'gemini-2.5-flash' has no '-lite' or
        # '-pro' suffix and must still hit the 2.5 budget=0 path.
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-2.5-flash", "MINIMAL"),
            {"include_thoughts": False, "thinking_budget": 0},
        )

    def test_gemini_25_pro_latest_matches_pro_branch(self) -> None:
        # Suffix variants like '-latest' must still hit the pro branch,
        # otherwise they'd fall into the broader 2.5 branch (budget=0)
        # which the live probe showed pro rejects.
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-2.5-pro-latest", "MINIMAL"),
            {"include_thoughts": False, "thinking_budget": 128},
        )

    def test_gemini_25_pro_maps_low_to_budget(self) -> None:
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-2.5-pro", "LOW"),
            {"include_thoughts": False, "thinking_budget": 256},
        )

    def test_gemini_25_pro_minimal_uses_lowest_valid_budget(self) -> None:
        self.assertEqual(
            _gemini_thinking_kwargs("gemini-2.5-pro", "MINIMAL"),
            {"include_thoughts": False, "thinking_budget": 128},
        )

    def test_none_level_omits_thinking_config(self) -> None:
        self.assertIsNone(_gemini_thinking_kwargs("gemini-2.5-flash", None))

    def test_older_gemini_omits_thinking_config(self) -> None:
        self.assertIsNone(_gemini_thinking_kwargs("gemini-1.5-pro", "MINIMAL"))

    def test_flash_lite_models_prefix_is_normalized(self) -> None:
        self.assertEqual(
            normalized_model_name("models/gemini-2.5-flash-lite"),
            "gemini-2.5-flash-lite",
        )

    def test_settings_wrapper_uses_model_family_dispatch(self) -> None:
        kwargs = thinking_config_kwargs(
            {"model": "gemini-3.1-flash-lite-preview", "thinking_level": "MINIMAL"},
        )

        self.assertEqual(kwargs, {"include_thoughts": False, "thinking_level": "MINIMAL"})


if __name__ == "__main__":
    unittest.main()
