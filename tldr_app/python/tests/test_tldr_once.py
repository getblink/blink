from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import tldr_once


class TldrOnceTests(unittest.TestCase):
    def test_default_prompt_includes_no_prefix_and_agent_steering_rules(self) -> None:
        self.assertIn("Do not repeat the existing draft prefix", tldr_once.DEFAULT_PROMPT)
        self.assertIn("On AI-agent or coding-agent surfaces", tldr_once.DEFAULT_PROMPT)
        self.assertIn("steer the agent", tldr_once.DEFAULT_PROMPT)
        self.assertIn("requests or directions to the agent", tldr_once.DEFAULT_PROMPT)
        self.assertIn("Avoid \"I agree...\"", tldr_once.DEFAULT_PROMPT)

    def test_parse_json_response_accepts_plain_json(self) -> None:
        parsed, error = tldr_once.parse_json_response(
            '{"tldr":"You are replying.","suggestions":["a","b","c"]}'
        )
        self.assertIsNone(error)
        self.assertEqual(parsed["tldr"], "You are replying.")

    def test_parse_json_response_extracts_object(self) -> None:
        parsed, error = tldr_once.parse_json_response(
            '```json\n{"tldr":"You are replying.","suggestions":["a","b","c"]}\n```'
        )
        self.assertIsNone(error)
        self.assertEqual(parsed["suggestions"], ["a", "b", "c"])

    def test_normalize_payload_trims_and_limits_suggestions(self) -> None:
        tldr, suggestions = tldr_once.normalize_payload(
            {"tldr": "  hi  ", "suggestions": [" a ", "", " b ", " c ", " d "]}
        )
        self.assertEqual(tldr, "hi")
        self.assertEqual(suggestions, ["a", "b", "c"])

    def test_build_generate_config_passes_through_and_adds_thinking_when_needed(self) -> None:
        captured_config: dict[str, Any] = {}
        captured_thinking: dict[str, Any] = {}

        class FakeThinkingConfig:
            def __init__(self, **kwargs: Any) -> None:
                captured_thinking.update(kwargs)

        class FakeGenerateContentConfig:
            def __init__(self, **kwargs: Any) -> None:
                captured_config.update(kwargs)

        class FakeTypes:
            ThinkingConfig = FakeThinkingConfig
            GenerateContentConfig = FakeGenerateContentConfig

        base_settings = {
            "model": "gemini-3.1-flash-lite-preview",
            "temperature": 0.2,
            "max_output_tokens": 512,
            "media_resolution": "MEDIA_RESOLUTION_LOW",
        }
        with mock.patch.object(tldr_once, "response_schema", return_value={"schema": "ok"}):
            tldr_once.build_generate_config(FakeTypes, "PROMPT", base_settings)
        self.assertEqual(captured_config["system_instruction"], "PROMPT")
        self.assertEqual(captured_config["temperature"], 0.2)
        self.assertEqual(captured_config["max_output_tokens"], 512)
        self.assertEqual(captured_config["media_resolution"], "MEDIA_RESOLUTION_LOW")
        self.assertEqual(captured_config["response_mime_type"], "application/json")
        self.assertIn("response_schema", captured_config)
        self.assertNotIn("thinking_config", captured_config)
        self.assertEqual(captured_thinking, {})

        self.assertEqual(captured_config["max_output_tokens"], 512)

        captured_config.clear()
        captured_thinking.clear()
        thinking_settings = dict(base_settings, model="gemini-3.1-pro-preview")
        with mock.patch.object(tldr_once, "response_schema", return_value={"schema": "ok"}):
            tldr_once.build_generate_config(FakeTypes, "PROMPT", thinking_settings)
        self.assertIn("thinking_config", captured_config)
        self.assertEqual(captured_thinking, {"thinking_level": "low"})
        self.assertNotIn("thinking_budget", captured_thinking)
        self.assertEqual(captured_config["max_output_tokens"], 2048)

    def test_max_output_tokens_for_model(self) -> None:
        self.assertEqual(tldr_once.max_output_tokens_for_model("gemini-3.1-pro-preview"), 2048)
        self.assertEqual(tldr_once.max_output_tokens_for_model("gemini-3-flash-preview"), 2048)
        self.assertIsNone(tldr_once.max_output_tokens_for_model("gemini-3.1-flash-lite-preview"))
        self.assertIsNone(tldr_once.max_output_tokens_for_model("gemma-4-26b-a4b-it"))
        self.assertIsNone(tldr_once.max_output_tokens_for_model(""))

    def test_thinking_level_for_model(self) -> None:
        self.assertEqual(tldr_once.thinking_level_for_model("gemini-3.1-pro-preview"), "low")
        self.assertEqual(tldr_once.thinking_level_for_model("Gemini-3-Pro"), "low")
        self.assertEqual(tldr_once.thinking_level_for_model("gemini-3-flash-preview"), "low")
        self.assertIsNone(tldr_once.thinking_level_for_model("gemini-3.1-flash-lite-preview"))
        self.assertIsNone(tldr_once.thinking_level_for_model("gemma-4-26b-a4b-it"))
        self.assertIsNone(tldr_once.thinking_level_for_model("gemini-2.5-flash"))
        self.assertIsNone(tldr_once.thinking_level_for_model(""))

    def test_extract_partial_suggestions(self) -> None:
        self.assertEqual(tldr_once.extract_partial_suggestions(""), [])
        self.assertEqual(
            tldr_once.extract_partial_suggestions('{"tldr":"hi"'),
            [],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions('{"tldr":"hi","suggestions":['),
            [],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions('{"tldr":"hi","suggestions":["one"'),
            ["one"],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions('{"tldr":"hi","suggestions":["one", "tw'),
            ["one", "tw"],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions(
                '{"tldr":"hi","suggestions":["one","two","three"]}'
            ),
            ["one", "two", "three"],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions(
                '{"suggestions":["he said \\"hi\\"","next"'
            ),
            ['he said "hi"', "next"],
        )
        self.assertEqual(
            tldr_once.extract_partial_suggestions('{"suggestions":["line one\\nline two"'),
            ["line one\nline two"],
        )

    def test_extract_partial_tldr_handles_incomplete_json_and_escapes(self) -> None:
        self.assertIsNone(tldr_once.extract_partial_tldr('{"status":"thinking"'))
        self.assertEqual(
            tldr_once.extract_partial_tldr('{"tldr":"Sarah said \\"yes\\"'),
            'Sarah said "yes"',
        )
        self.assertEqual(
            tldr_once.extract_partial_tldr('{"tldr":"Line one\\nLine two","suggestions":['),
            "Line one\nLine two",
        )

    def test_non_object_json_is_schema_mismatch(self) -> None:
        payload = tldr_once.build_response_payload(
            raw_text='["not", "an", "object"]',
            usage=None,
            duration_ms=0,
        )
        self.assertEqual(payload["status"], "schema_mismatch")

    def test_missing_credentials_writes_error_artifacts(self) -> None:
        old_key = os.environ.pop("GEMINI_API_KEY", None)
        old_runtime_dir = os.environ.get("TLDR_RUNTIME_DIR")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                os.environ["TLDR_RUNTIME_DIR"] = str(root / "runtime-home")
                screenshot = root / "screenshot.png"
                screenshot.write_bytes(b"fake-png")
                runtime = root / "runtime.json"
                runtime.write_text(
                    json.dumps(
                        {
                            "version": 1,
                            "auto_paste": True,
                            "model": "gemini-3.1-flash-lite-preview",
                        }
                    ),
                    encoding="utf-8",
                )
                out_dir = root / "runs"
                stderr = StringIO()
                with redirect_stderr(stderr), self.assertRaises(RuntimeError):
                    tldr_once.main(
                        [
                            "--screenshot",
                            str(screenshot),
                            "--runtime",
                            str(runtime),
                            "--out-dir",
                            str(out_dir),
                        ]
                    )
                bundles = list(out_dir.iterdir())
                self.assertEqual(len(bundles), 1)
                self.assertTrue((bundles[0] / "stderr.log").exists())
                run = json.loads((bundles[0] / "run.json").read_text(encoding="utf-8"))
                self.assertEqual(run["status"], "error")
                self.assertIn("GEMINI_API_KEY", run["error"])
        finally:
            if old_key is not None:
                os.environ["GEMINI_API_KEY"] = old_key
            if old_runtime_dir is None:
                os.environ.pop("TLDR_RUNTIME_DIR", None)
            else:
                os.environ["TLDR_RUNTIME_DIR"] = old_runtime_dir

    def test_skip_gemini_writes_artifacts_and_stdout_payload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screenshot.png"
            screenshot.write_bytes(b"fake-png")
            runtime = root / "runtime.json"
            runtime.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "auto_paste": True,
                        "model": "gemini-3.1-flash-lite-preview",
                    }
                ),
                encoding="utf-8",
            )
            out_dir = root / "runs"
            stdout = StringIO()
            with redirect_stdout(stdout):
                code = tldr_once.main(
                    [
                        "--screenshot",
                        str(screenshot),
                        "--runtime",
                        str(runtime),
                        "--out-dir",
                        str(out_dir),
                        "--skip-gemini",
                    ]
                )
            self.assertEqual(code, 0)
            payload = json.loads(stdout.getvalue())
            self.assertEqual(payload["status"], "ok")
            bundles = list(out_dir.iterdir())
            self.assertEqual(len(bundles), 1)
            self.assertTrue((bundles[0] / "screenshot.png").exists())
            self.assertTrue((bundles[0] / "response.json").exists())
            self.assertTrue((bundles[0] / "run.json").exists())
            self.assertTrue((bundles[0] / "host_profile.json").exists())
            self.assertTrue((bundles[0] / "stderr.log").exists())
            model_input = (bundles[0] / "model_input.txt").read_text(encoding="utf-8")
            self.assertIn("generation_path: skip_gemini", model_input)
            self.assertIn("system_instruction:", model_input)
            model_context = json.loads((bundles[0] / "model_context.json").read_text(encoding="utf-8"))
            self.assertEqual(model_context["generation_path"], "skip_gemini")
            self.assertEqual(model_context["model_input_scope"], "actual_local_gemini_input")

    def test_stream_events_skip_gemini_emits_ndjson_final(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screenshot.png"
            screenshot.write_bytes(b"fake-png")
            runtime = root / "runtime.json"
            runtime.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "auto_paste": True,
                        "model": "gemini-3.1-flash-lite-preview",
                    }
                ),
                encoding="utf-8",
            )
            out_dir = root / "runs"
            stdout = StringIO()
            with redirect_stdout(stdout):
                code = tldr_once.main(
                    [
                        "--screenshot",
                        str(screenshot),
                        "--runtime",
                        str(runtime),
                        "--out-dir",
                        str(out_dir),
                        "--skip-gemini",
                        "--stream-events",
                    ]
                )
            self.assertEqual(code, 0)
            events = [json.loads(line) for line in stdout.getvalue().splitlines()]
            self.assertEqual(events[0]["event"], "phase")
            self.assertTrue(any(event["event"] == "partial_tldr" for event in events))
            self.assertEqual(events[-1]["event"], "final")
            self.assertEqual(events[-1]["status"], "ok")
            self.assertEqual(len(events[-1]["suggestions"]), 3)
            bundles = list(out_dir.iterdir())
            self.assertEqual(len(bundles), 1)
            self.assertTrue((bundles[0] / "run.json").exists())

    def test_build_stateful_context_uses_custom_replies_and_same_surface_history(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            old = runs / "20260503-120000-000"
            old.mkdir(parents=True)
            (old / "request.json").write_text(
                json.dumps(
                    {
                        "frontmost_app": {"bundle_id": "com.example.chat", "app_name": "Chat"},
                        "focused_context": {"title": "Sarah"},
                    }
                ),
                encoding="utf-8",
            )
            (old / "run.json").write_text(
                json.dumps(
                    {
                        "started_at": "2026-05-03T12:00:00+00:00",
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "chosen_action": "user_typed",
                        "custom_reply_text": "yep, i can send that over after lunch",
                        "custom_reply_at": "2026-05-03T12:00:06+00:00",
                        "response": {"tldr": "Sarah needs the doc today."},
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {
                    "frontmost_app": {"bundle_id": "com.example.chat"},
                    "focused_context": {"title": "Sarah"},
                },
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["voice_samples"][0]["text"], "yep, i can send that over after lunch")
        self.assertEqual(context["recent_surface_history"][0]["tldr"], "Sarah needs the doc today.")
        self.assertEqual(
            context["recent_surface_history"][0]["custom_reply_text"],
            "yep, i can send that over after lunch",
        )
        self.assertEqual(context["surface_match_debug"]["match_mode"], "title_match")
        self.assertEqual(context["matched_history_count"], 1)
        self.assertEqual(context["voice_sample_count"], 1)

    def test_build_stateful_context_relaxes_empty_title_same_role_for_conductor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            for index in range(3):
                old = runs / f"20260503-12000{index}-000"
                old.mkdir(parents=True)
                (old / "request.json").write_text(
                    json.dumps(
                        {
                            "frontmost_app": {"bundle_id": "com.conductor.app", "app_name": "Conductor"},
                            "focused_context": {"title": "", "role": "AXTextArea"},
                        }
                    ),
                    encoding="utf-8",
                )
                (old / "run.json").write_text(
                    json.dumps(
                        {
                            "finished_at": f"2026-05-03T12:0{index}:05+00:00",
                            "custom_reply_text": f"reply {index}",
                            "response": {"tldr": f"Conductor run {index}."},
                        }
                    ),
                    encoding="utf-8",
                )

            context = tldr_once.build_stateful_context(
                runs,
                {
                    "frontmost_app": {"bundle_id": "com.conductor.app"},
                    "focused_context": {"title": "", "role": "AXTextArea"},
                },
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["surface_match_debug"]["match_mode"], "relaxed_same_app_role")
        self.assertEqual(len(context["recent_surface_history"]), 2)
        self.assertEqual([sample["text"] for sample in context["voice_samples"]], ["reply 2", "reply 1", "reply 0"])

    def test_build_stateful_context_keeps_scanning_for_voice_after_history_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            rows = [
                ("20260503-120400-000", "2026-05-03T12:04:05+00:00", None, "Newest run.", ["a", "b", "c"]),
                ("20260503-120300-000", "2026-05-03T12:03:05+00:00", None, "Second newest run.", ["d", "e", "f"]),
                (
                    "20260503-120200-000",
                    "2026-05-03T12:02:05+00:00",
                    "older custom reply",
                    "Older run.",
                    ["Sounds good.", "I agree.", "Let's proceed."],
                ),
            ]
            for dirname, finished_at, custom_reply_text, tldr, suggestions in rows:
                old = runs / dirname
                old.mkdir(parents=True)
                (old / "request.json").write_text(
                    json.dumps(
                        {
                            "frontmost_app": {"bundle_id": "com.conductor.app", "app_name": "Conductor"},
                            "focused_context": {"title": "", "role": "AXTextArea"},
                        }
                    ),
                    encoding="utf-8",
                )
                run_log = {
                    "finished_at": finished_at,
                    "response": {"tldr": tldr, "suggestions": suggestions},
                }
                if custom_reply_text:
                    run_log["custom_reply_text"] = custom_reply_text
                (old / "run.json").write_text(json.dumps(run_log), encoding="utf-8")

            context = tldr_once.build_stateful_context(
                runs,
                {
                    "frontmost_app": {"bundle_id": "com.conductor.app"},
                    "focused_context": {"title": "", "role": "AXTextArea"},
                },
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual([item["tldr"] for item in context["recent_surface_history"]], ["Newest run.", "Second newest run."])
        self.assertEqual([sample["text"] for sample in context["voice_samples"]], ["older custom reply"])
        self.assertEqual(context["preference_examples"][0]["user_typed"], "older custom reply")
        self.assertEqual(context["preference_examples"][0]["rejected_suggestions"], ["Sounds good.", "I agree.", "Let's proceed."])
        self.assertEqual(context["matched_history_count"], 2)
        self.assertEqual(context["voice_sample_count"], 1)
        self.assertEqual(context["preference_example_count"], 1)

    def test_prompt_with_stateful_context_renders_preference_examples_without_duplicate_voice_or_outcome(self) -> None:
        prompt = tldr_once.prompt_with_stateful_context(
            "Base prompt.",
            {
                "voice_samples": [{"text": "please inspect the logs first"}],
                "preference_examples": [
                    {
                        "screen_takeaway": "The agent suggested a low-risk plan.",
                        "rejected_suggestions": ["Sounds good.", "I agree.", "Let's proceed."],
                        "user_typed": "please inspect the logs first",
                    }
                ],
                "recent_surface_history": [
                    {
                        "tldr": "The agent suggested a low-risk plan.",
                        "custom_reply_text": "please inspect the logs first",
                    }
                ],
            },
        )

        self.assertIn("User preference examples from this same surface", prompt)
        self.assertIn("Model suggestions the user did not use", prompt)
        self.assertIn("- Sounds good.", prompt)
        self.assertIn("User typed instead: please inspect the logs first", prompt)
        self.assertIn("Prior outcome: user typed a custom reply instead of using the suggestions.", prompt)
        self.assertNotIn("User voice examples:", prompt)

    def test_prompt_with_stateful_context_does_not_render_model_authored_chosen_text(self) -> None:
        prompt = tldr_once.prompt_with_stateful_context(
            "Base prompt.",
            {
                "recent_surface_history": [
                    {
                        "tldr": "The agent implemented the prompt change.",
                        "chosen_action": "inserted",
                        "chosen_index": 1,
                        "chosen_text": "This looks good. Let's test this new prompt structure.",
                    }
                ],
            },
        )

        self.assertIn("Prior outcome: user inserted model suggestion #2", prompt)
        self.assertIn("do not copy that prior model-authored wording", prompt)
        self.assertNotIn("This looks good. Let's test this new prompt structure.", prompt)

    def test_build_stateful_context_excludes_old_relaxed_empty_title_runs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            old = runs / "20260503-114000-000"
            old.mkdir(parents=True)
            (old / "request.json").write_text(
                json.dumps(
                    {
                        "frontmost_app": {"bundle_id": "com.conductor.app"},
                        "focused_context": {"title": "", "role": "AXTextArea"},
                    }
                ),
                encoding="utf-8",
            )
            (old / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T11:40:05+00:00",
                        "custom_reply_text": "too old",
                        "response": {"tldr": "Old run."},
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {
                    "frontmost_app": {"bundle_id": "com.conductor.app"},
                    "focused_context": {"title": "", "role": "AXTextArea"},
                },
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["recent_surface_history"], [])
        self.assertEqual(context["voice_samples"], [])
        self.assertEqual(context["surface_match_debug"]["match_mode"], "no_match")
        self.assertEqual(context["surface_match_debug"]["skipped_reasons"]["relaxed_same_app_role_too_old"], 1)

    def test_build_stateful_context_does_not_use_chosen_suggestions_as_voice(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            old = runs / "20260503-120000-000"
            old.mkdir(parents=True)
            (old / "request.json").write_text(
                json.dumps({"frontmost_app": {"bundle_id": "com.example.chat"}}),
                encoding="utf-8",
            )
            (old / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "chosen_action": "copied",
                        "chosen_text": "Model-authored text",
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {"frontmost_app": {"bundle_id": "com.example.chat"}},
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["voice_samples"], [])
        self.assertEqual(context["recent_surface_history"], [])
        self.assertEqual(context["surface_match_debug"]["skipped_reasons"]["empty_title_missing_role"], 1)

    def test_build_stateful_context_excludes_global_custom_replies_from_other_surfaces(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            old = runs / "20260503-120000-000"
            old.mkdir(parents=True)
            (old / "request.json").write_text(
                json.dumps(
                    {
                        "frontmost_app": {"bundle_id": "com.example.other"},
                        "focused_context": {"title": "Other"},
                    }
                ),
                encoding="utf-8",
            )
            (old / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "custom_reply_text": "do not use this voice",
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {
                    "frontmost_app": {"bundle_id": "com.example.chat"},
                    "focused_context": {"title": "Sarah"},
                },
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["voice_samples"], [])
        self.assertEqual(context["recent_surface_history"], [])
        self.assertEqual(context["surface_match_debug"]["skipped_reasons"]["bundle_id_mismatch"], 1)

    def test_disable_proxy_env_ignores_proxy_credentials(self) -> None:
        old_proxy_url = os.environ.get("BLINK_PROXY_URL")
        old_proxy_token = os.environ.get("BLINK_PROXY_TOKEN")
        old_disable = os.environ.get("TLDR_DISABLE_PROXY")
        try:
            os.environ["BLINK_PROXY_URL"] = "https://proxy.example"
            os.environ["BLINK_PROXY_TOKEN"] = "token"
            os.environ["TLDR_DISABLE_PROXY"] = "1"

            self.assertIsNone(tldr_once.proxy_settings_from_env())
        finally:
            if old_proxy_url is None:
                os.environ.pop("BLINK_PROXY_URL", None)
            else:
                os.environ["BLINK_PROXY_URL"] = old_proxy_url
            if old_proxy_token is None:
                os.environ.pop("BLINK_PROXY_TOKEN", None)
            else:
                os.environ["BLINK_PROXY_TOKEN"] = old_proxy_token
            if old_disable is None:
                os.environ.pop("TLDR_DISABLE_PROXY", None)
            else:
                os.environ["TLDR_DISABLE_PROXY"] = old_disable

    def test_main_enriches_proxy_request_with_stateful_context(self) -> None:
        old_proxy_url = os.environ.get("BLINK_PROXY_URL")
        old_proxy_token = os.environ.get("BLINK_PROXY_TOKEN")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                screenshot = root / "screenshot.png"
                screenshot.write_bytes(b"fake-png")
                runtime = root / "runtime.json"
                runtime.write_text(
                    json.dumps(
                        {
                            "version": 1,
                            "auto_paste": True,
                            "model": "gemini-3.1-flash-lite-preview",
                        }
                    ),
                    encoding="utf-8",
                )
                request_json = root / "request.json"
                request_json.write_text(
                    json.dumps(
                        {
                            "request_id": "req-current",
                            "frontmost_app": {"bundle_id": "com.example.chat"},
                            "focused_context": {"title": "Sarah"},
                        }
                    ),
                    encoding="utf-8",
                )
                out_dir = root / "runs"
                old = out_dir / "20260503-120000-000"
                old.mkdir(parents=True)
                (old / "request.json").write_text(
                    json.dumps(
                        {
                            "frontmost_app": {"bundle_id": "com.example.chat"},
                            "focused_context": {"title": "Sarah"},
                        }
                    ),
                    encoding="utf-8",
                )
                (old / "run.json").write_text(
                    json.dumps(
                        {
                            "finished_at": tldr_once.now_iso(),
                            "custom_reply_text": "sounds good, i'll take a look",
                            "custom_reply_at": tldr_once.now_iso(),
                            "response": {"tldr": "Sarah asked for a review."},
                        }
                    ),
                    encoding="utf-8",
                )
                os.environ["BLINK_PROXY_URL"] = "https://proxy.example"
                os.environ["BLINK_PROXY_TOKEN"] = "token"

                def fake_proxy(
                    request_payload: dict[str, object],
                    settings: dict[str, object],
                    proxy_settings: dict[str, str],
                    image_path: Path | None,
                ) -> dict[str, object]:
                    self.assertIn("stateful_context", request_payload)
                    return {
                        "status": "ok",
                        "tldr": "Done.",
                        "suggestions": ["One", "Two", "Three"],
                        "raw": "",
                        "usage": None,
                        "duration_ms": 1,
                        "parse_error": None,
                        "warnings": [],
                        "request_id": request_payload["request_id"],
                        "model": settings["model"],
                    }

                stdout = StringIO()
                with mock.patch.object(tldr_once, "generate_via_proxy", side_effect=fake_proxy), redirect_stdout(stdout):
                    code = tldr_once.main(
                        [
                            "--screenshot",
                            str(screenshot),
                            "--runtime",
                            str(runtime),
                            "--request-json",
                            str(request_json),
                            "--out-dir",
                            str(out_dir),
                        ]
                    )

                self.assertEqual(code, 0)
                bundle = [path for path in out_dir.iterdir() if path.name != "20260503-120000-000"][0]
                saved_request = json.loads((bundle / "request.json").read_text(encoding="utf-8"))
                self.assertEqual(saved_request["stateful_context"]["voice_samples"][0]["text"], "sounds good, i'll take a look")
                model_input = (bundle / "model_input.txt").read_text(encoding="utf-8")
                self.assertIn("generation_path: proxy", model_input)
                self.assertIn("Client-side diagnostic preview for the proxy request", model_input)
                self.assertIn("submitted_proxy_request_json:", model_input)
                model_context = json.loads((bundle / "model_context.json").read_text(encoding="utf-8"))
                self.assertEqual(model_context["generation_path"], "proxy")
                self.assertEqual(
                    model_context["model_input_scope"],
                    "client_proxy_payload_with_server_rendering_preview",
                )
                self.assertIn("stateful_context", model_context["submitted_request"])
                self.assertIn("stateful_context", model_context["proxy_server_preview"]["context_text"])
        finally:
            if old_proxy_url is None:
                os.environ.pop("BLINK_PROXY_URL", None)
            else:
                os.environ["BLINK_PROXY_URL"] = old_proxy_url
            if old_proxy_token is None:
                os.environ.pop("BLINK_PROXY_TOKEN", None)
            else:
                os.environ["BLINK_PROXY_TOKEN"] = old_proxy_token


if __name__ == "__main__":
    unittest.main()
