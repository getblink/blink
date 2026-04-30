from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
