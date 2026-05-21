from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / "app" / "python"))

import blink_once
from server import gemini


SHARED_LIMIT_CONSTANTS = (
    "PREFERENCE_EXAMPLE_LIMIT",
    "PREFERENCE_REJECTED_SUGGESTION_LIMIT",
    "VOICE_SAMPLE_MAX_CHARS",
    "SURFACE_TEXT_MAX_CHARS",
    "PREFERENCE_TEXT_MAX_CHARS",
    "FOLLOW_UP_INSTRUCTION_MAX_CHARS",
    "FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT",
    "FOLLOW_UP_INSTRUCTION_HISTORY_WINDOW_SECONDS",
    "RESPONSE_SCHEMA_VERSION",
    "SUGGESTION_TAG_LIMIT",
    "SUGGESTION_TAG_MAX_CHARS",
    "STYLE_ABOUT_ME_MAX_CHARS",
)


class PromptParityTests(unittest.TestCase):
    def test_server_and_app_prompt_files_match_byte_for_byte(self) -> None:
        self.assertEqual(
            (REPO_ROOT / "server" / "prompt.txt").read_bytes(),
            (REPO_ROOT / "app" / "Resources" / "prompt.txt").read_bytes(),
        )

    def test_shared_model_content_text_matches(self) -> None:
        self.assertEqual(blink_once.MODEL_CONTENT_TEXT, gemini.MODEL_CONTENT_TEXT)

    def test_shared_limit_constants_match(self) -> None:
        for name in SHARED_LIMIT_CONSTANTS:
            with self.subTest(constant=name):
                self.assertEqual(getattr(blink_once, name), getattr(gemini, name))

    def test_style_knob_metadata_matches(self) -> None:
        self.assertEqual(blink_once.STYLE_KNOB_ORDER, gemini.STYLE_KNOB_ORDER)
        self.assertEqual(blink_once.STYLE_KNOB_INSTRUCTIONS, gemini.STYLE_KNOB_INSTRUCTIONS)

    def test_prompt_with_stateful_context_returns_input_when_empty(self) -> None:
        for stateful in (None, {}, {"voice_samples": [], "preference_examples": [], "recent_surface_history": []}):
            with self.subTest(stateful=stateful):
                self.assertEqual(
                    blink_once.prompt_with_stateful_context("BASE PROMPT", stateful),
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
            blink_once.prompt_with_stateful_context("BASE PROMPT", fixture),
            gemini.prompt_with_stateful_context("BASE PROMPT", fixture),
        )

    def test_style_block_default_is_empty_and_does_not_alter_prompt(self) -> None:
        default_style = {
            "initiative": "balanced",
            "tone": "balanced",
            "length": "balanced",
            "directness": "balanced",
            "voice_mirror": "balanced",
            "about_me": "",
        }
        self.assertEqual(blink_once.style_block(default_style), "")
        self.assertEqual(gemini.style_block(default_style), "")
        # Style with all defaults plus no other context must not append anything.
        self.assertEqual(
            blink_once.prompt_with_context("BASE PROMPT", None, None, default_style),
            "BASE PROMPT",
        )
        self.assertEqual(
            gemini.prompt_with_context("BASE PROMPT", None, None, default_style),
            "BASE PROMPT",
        )

    def test_follow_up_instruction_matches_and_extends_reroll_prompt(self) -> None:
        reroll_context = {
            "schema_version": 1,
            "previous_suggestions": ["Sounds good.", "I'll take a look."],
            "follow_up_instruction": "make this warmer and ask for friday",
        }
        rendered = blink_once.prompt_with_context(
            "BASE PROMPT",
            None,
            reroll_context,
        )
        self.assertEqual(
            rendered,
            gemini.prompt_with_context(
                "BASE PROMPT",
                None,
                reroll_context,
            ),
        )
        self.assertIn(
            "<follow_up_instruction>make this warmer and ask for friday</follow_up_instruction>",
            rendered,
        )
        self.assertIn("<reroll_instructions>", rendered)
        self.assertIn("avoid repeating these previous suggestions", rendered)
        self.assertNotIn("<stateful_context>", rendered)

    def test_follow_up_instruction_is_truncated(self) -> None:
        long_text = "x" * (blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS + 50)
        reroll_context = {"schema_version": 1, "follow_up_instruction": long_text}
        rendered = blink_once.prompt_with_context("BASE PROMPT", None, reroll_context)
        self.assertIn("x" * blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS, rendered)
        self.assertNotIn("x" * (blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS + 1), rendered)
        self.assertEqual(
            rendered,
            gemini.prompt_with_context("BASE PROMPT", None, reroll_context),
        )

    def test_style_block_matches_for_populated_style(self) -> None:
        style = {
            "initiative": "agentic",
            "tone": "balanced",
            "length": "terse",
            "directness": "direct",
            "voice_mirror": "balanced",
            "about_me": "I'm a backend engineer; prefer technical language.",
        }
        self.assertEqual(blink_once.style_block(style), gemini.style_block(style))
        rendered = blink_once.prompt_with_context("BASE PROMPT", None, None, style)
        self.assertEqual(
            rendered,
            gemini.prompt_with_context("BASE PROMPT", None, None, style),
        )
        self.assertIn("<style_preferences>", rendered)
        self.assertIn("</style_preferences>", rendered)
        self.assertIn("Initiative: take the lead", rendered)
        self.assertIn("Length: keep each suggestion", rendered)
        self.assertIn("Directness: be direct", rendered)
        self.assertIn("About the user: I'm a backend engineer", rendered)
        # Balanced knobs must not emit instructions.
        self.assertNotIn("Tone:", rendered)
        self.assertNotIn("Voice mirror:", rendered)

    def test_style_block_about_me_is_truncated(self) -> None:
        long_text = "x" * (blink_once.STYLE_ABOUT_ME_MAX_CHARS + 50)
        style = {"about_me": long_text}
        rendered = blink_once.style_block(style)
        self.assertIn("About the user: " + ("x" * blink_once.STYLE_ABOUT_ME_MAX_CHARS), rendered)
        self.assertNotIn("x" * (blink_once.STYLE_ABOUT_ME_MAX_CHARS + 1), rendered)
        self.assertEqual(rendered, gemini.style_block(style))

    def test_style_block_combines_with_stateful_context(self) -> None:
        style = {"initiative": "agentic", "about_me": "hi"}
        stateful = {
            "voice_samples": [{"text": "yo"}],
            "preference_examples": [],
            "recent_surface_history": [],
        }
        rendered = blink_once.prompt_with_context("BASE PROMPT", stateful, None, style)
        self.assertEqual(
            rendered,
            gemini.prompt_with_context("BASE PROMPT", stateful, None, style),
        )
        self.assertIn("<style_preferences>", rendered)
        self.assertIn("<stateful_context>", rendered)
        # Style block should appear before the stateful context block.
        self.assertLess(
            rendered.index("<style_preferences>"),
            rendered.index("<stateful_context>"),
        )

    def test_follow_up_history_renders_standing_guidance_block(self) -> None:
        stateful = {
            "voice_samples": [],
            "preference_examples": [],
            "recent_surface_history": [],
            "recent_follow_up_instructions": [
                {
                    "instruction": "use proper email format with a greeting and sign-off",
                    "age_seconds": 312,
                    "app_bundle_id": "com.apple.mail",
                    "app_name": "Mail",
                    "match_mode": "window_match",
                },
                {
                    "instruction": "keep it under 3 sentences",
                    "age_seconds": 3600 + 120,
                    "app_bundle_id": "com.apple.mail",
                    "app_name": "Mail",
                    "match_mode": "bundle_match",
                },
            ],
        }
        rendered = blink_once.prompt_with_context("BASE PROMPT", stateful)
        self.assertEqual(
            rendered,
            gemini.prompt_with_context("BASE PROMPT", stateful),
        )
        self.assertIn("<recent_follow_up_guidance>", rendered)
        self.assertIn("</recent_follow_up_guidance>", rendered)
        self.assertIn(
            '- 5m ago, in Mail: "use proper email format with a greeting and sign-off"',
            rendered,
        )
        self.assertIn('- 1h ago, in Mail: "keep it under 3 sentences"', rendered)
        # The block must not introduce a <stateful_context> heading when
        # there is no voice/preference/surface signal alongside it.
        self.assertNotIn("<stateful_context>", rendered)

    def test_follow_up_history_empty_keeps_prompt_unchanged(self) -> None:
        for value in (
            None,
            [],
            [{"instruction": "", "age_seconds": 0}],
            [{"age_seconds": 60, "app_name": "Mail"}],  # missing instruction
            "not-a-list",
        ):
            stateful = {
                "voice_samples": [],
                "preference_examples": [],
                "recent_surface_history": [],
                "recent_follow_up_instructions": value,
            }
            with self.subTest(value=value):
                self.assertEqual(
                    blink_once.prompt_with_context("BASE PROMPT", stateful),
                    "BASE PROMPT",
                )
                self.assertEqual(
                    gemini.prompt_with_context("BASE PROMPT", stateful),
                    "BASE PROMPT",
                )

    def test_follow_up_history_truncates_long_instructions(self) -> None:
        long_text = "y" * (blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS + 50)
        stateful = {
            "recent_follow_up_instructions": [
                {"instruction": long_text, "age_seconds": 60, "app_name": "Mail"},
            ],
        }
        rendered = blink_once.prompt_with_context("BASE PROMPT", stateful)
        self.assertEqual(rendered, gemini.prompt_with_context("BASE PROMPT", stateful))
        self.assertIn("y" * blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS, rendered)
        self.assertNotIn("y" * (blink_once.FOLLOW_UP_INSTRUCTION_MAX_CHARS + 1), rendered)

    def test_follow_up_history_caps_at_limit(self) -> None:
        entries = [
            {
                "instruction": f"instruction number {index}",
                "age_seconds": 60 * (index + 1),
                "app_name": "Mail",
            }
            for index in range(blink_once.FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT + 2)
        ]
        stateful = {"recent_follow_up_instructions": entries}
        rendered = blink_once.prompt_with_context("BASE PROMPT", stateful)
        self.assertEqual(rendered, gemini.prompt_with_context("BASE PROMPT", stateful))
        for index in range(blink_once.FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT):
            self.assertIn(f"instruction number {index}", rendered)
        for index in (
            blink_once.FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT,
            blink_once.FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT + 1,
        ):
            self.assertNotIn(f"instruction number {index}", rendered)

    def test_prompt_with_context_matches_for_reroll_fixture(self) -> None:
        reroll_context = {
            "schema_version": 1,
            "previous_suggestions": [
                "Sounds good, I'll take a look.",
                "Can you send the doc?",
                "Let's revisit this tomorrow.",
            ],
        }

        self.assertEqual(
            blink_once.prompt_with_context("BASE PROMPT", None, reroll_context),
            gemini.prompt_with_context("BASE PROMPT", None, reroll_context),
        )
        self.assertIn(
            "avoid repeating these previous suggestions",
            blink_once.prompt_with_context("BASE PROMPT", None, reroll_context),
        )
        self.assertIn(
            "<reroll_instructions>",
            blink_once.prompt_with_context("BASE PROMPT", None, reroll_context),
        )
        self.assertNotIn(
            "<stateful_context>",
            blink_once.prompt_with_context("BASE PROMPT", None, reroll_context),
        )


if __name__ == "__main__":
    unittest.main()
