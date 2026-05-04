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

        self.assertIsNone(context)

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
                            "finished_at": "2026-05-03T12:00:05+00:00",
                            "custom_reply_text": "sounds good, i'll take a look",
                            "custom_reply_at": "2026-05-03T12:00:06+00:00",
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
