from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "tldr_app" / "python"))

import tldr_once
from server import gemini


SHARED_LIMIT_CONSTANTS = (
    "PREFERENCE_EXAMPLE_LIMIT",
    "PREFERENCE_REJECTED_SUGGESTION_LIMIT",
    "VOICE_SAMPLE_MAX_CHARS",
    "SURFACE_TEXT_MAX_CHARS",
    "PREFERENCE_TEXT_MAX_CHARS",
)


class PromptParityTests(unittest.TestCase):
    def test_server_and_app_prompt_files_match_byte_for_byte(self) -> None:
        self.assertEqual(
            (REPO_ROOT / "server" / "prompt.txt").read_bytes(),
            (REPO_ROOT / "tldr_app" / "Resources" / "prompt.txt").read_bytes(),
        )

    def test_shared_model_content_text_matches(self) -> None:
        self.assertEqual(tldr_once.MODEL_CONTENT_TEXT, gemini.MODEL_CONTENT_TEXT)

    def test_shared_limit_constants_match(self) -> None:
        for name in SHARED_LIMIT_CONSTANTS:
            with self.subTest(constant=name):
                self.assertEqual(getattr(tldr_once, name), getattr(gemini, name))

    def test_prompt_with_stateful_context_returns_input_when_empty(self) -> None:
        for stateful in (None, {}, {"voice_samples": [], "preference_examples": [], "recent_surface_history": []}):
            with self.subTest(stateful=stateful):
                self.assertEqual(
                    tldr_once.prompt_with_stateful_context("BASE PROMPT", stateful),
                    gemini.prompt_with_stateful_context("BASE PROMPT", stateful),
                )

    def test_prompt_with_stateful_context_matches_for_populated_fixture(self) -> None:
        fixture = {
            "voice_samples": [
                {"text": "Sounds good, I'll take a look."},
                {"text": "Can you share the link?"},
            ],
            "preference_examples": [
                {
                    "screen_takeaway": "Sarah is asking when the doc lands.",
                    "user_typed": "Pushing it to Friday — pulled into the migration.",
                    "rejected_suggestions": [
                        "Sounds good!",
                        "Will get to it soon.",
                        "On it.",
                    ],
                }
            ],
            "recent_surface_history": [
                {
                    "tldr": "Sarah confirmed the 4pm sync.",
                    "chosen_text": "See you at 4.",
                    "chosen_action": "sent",
                    "chosen_index": 0,
                },
                {
                    "tldr": "Earlier thread about the migration estimate.",
                    "custom_reply_text": "Pushing it to Friday — pulled into the migration.",
                },
            ],
        }
        self.assertEqual(
            tldr_once.prompt_with_stateful_context("BASE PROMPT", fixture),
            gemini.prompt_with_stateful_context("BASE PROMPT", fixture),
        )


if __name__ == "__main__":
    unittest.main()
