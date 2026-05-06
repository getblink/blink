from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
import zlib
from contextlib import redirect_stderr, redirect_stdout
from io import BytesIO, StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import tldr_once
from image_prep import prepare_request_image


def write_test_png(path: Path, *, width: int = 96, height: int = 96) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(((x * 3) % 256, (y * 5) % 256, ((x + y) * 7) % 256))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), level=0))
        + chunk(b"IEND", b"")
    )


class TldrOnceTests(unittest.TestCase):
    def test_default_prompt_includes_no_prefix_and_agent_steering_rules(self) -> None:
        self.assertIn("Do not repeat the existing draft prefix", tldr_once.DEFAULT_PROMPT)
        self.assertIn("On AI-agent or coding-agent surfaces", tldr_once.DEFAULT_PROMPT)
        self.assertIn("steer the agent", tldr_once.DEFAULT_PROMPT)
        self.assertIn("requests or directions to the agent", tldr_once.DEFAULT_PROMPT)
        self.assertIn("Avoid \"I agree...\"", tldr_once.DEFAULT_PROMPT)
        self.assertIn("multiple screenshots", tldr_once.DEFAULT_PROMPT)

    def test_args_screenshot_repeatable(self) -> None:
        args = tldr_once.parse_args(
            [
                "--screenshot",
                "one.png",
                "--screenshot",
                "two.png",
                "--runtime",
                "runtime.json",
                "--out-dir",
                "runs",
            ]
        )
        self.assertEqual(args.screenshot, [Path("one.png"), Path("two.png")])

    def test_encode_multipart_request_multiple_images(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first.png"
            second = root / "second.png"
            first.write_bytes(b"one")
            second.write_bytes(b"two")

            body, _ = tldr_once._encode_multipart_request(
                {"request_id": "req"},
                [first, second],
            )

        self.assertEqual(body.count(b'Content-Disposition: form-data; name="screenshot'), 2)
        self.assertIn(b'name="screenshot"', body)
        self.assertIn(b'name="screenshot_1"', body)
        self.assertIn(b"one", body)
        self.assertIn(b"two", body)

    def test_proxy_preferences_are_encoded_in_multipart_request(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screen.png"
            screenshot.write_bytes(b"fake")
            payload = {
                "request_id": "req-prefs",
                "schema_version": 1,
                "input_mode": "screenshot",
                "preferences": {
                    "model": "gemini-3-flash-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                },
            }

            body, _ = tldr_once._encode_multipart_request(payload, [screenshot])

        self.assertIn(b'"preferences"', body)
        self.assertIn(b'"model": "gemini-3-flash-preview"', body)

    def test_proxy_sse_parser_emits_partials_and_returns_final(self) -> None:
        class FakeResponse:
            def __init__(self) -> None:
                self.lines = iter(
                    [
                        b"event: partial_tldr\n",
                        b'data: {"tldr":"Sarah needs a reply."}\n',
                        b"\n",
                        b"event: partial_suggestions\n",
                        b'data: {"suggestions":["One","Two"]}\n',
                        b"\n",
                        b"event: final\n",
                        b'data: {"request_id":"req-sse","status":"ok","tldr":"Sarah needs a reply.","suggestions":["One","Two","Three"],"duration_ms":12,"model":"gemini-3-flash-preview","warnings":[]}\n',
                        b"\n",
                    ]
                )

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *_: object) -> None:
                return None

            def readline(self) -> bytes:
                return next(self.lines, b"")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screen.png"
            screenshot.write_bytes(b"fake")
            stdout = StringIO()
            with mock.patch.object(tldr_once.request, "urlopen", return_value=FakeResponse()), redirect_stdout(stdout):
                payload = tldr_once.generate_via_proxy(
                    request_payload={"request_id": "req-sse"},
                    settings={
                        "model": "gemini-3-flash-preview",
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "media_resolution": "MEDIA_RESOLUTION_LOW",
                        "timeout_seconds": 120,
                    },
                    proxy_settings={"url": "https://proxy.example", "token": "token"},
                    image_paths=[screenshot],
                    stream_events=True,
                )

        events = [json.loads(line) for line in stdout.getvalue().splitlines()]
        self.assertEqual([event["event"] for event in events], ["partial_tldr", "partial_suggestions"])
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["request_id"], "req-sse")
        self.assertEqual(payload["model"], "gemini-3-flash-preview")
        self.assertEqual(payload["proxy_diagnostics"]["host"], "proxy.example")
        self.assertEqual(payload["proxy_diagnostics"]["request_path"], "/v1/tldr")
        self.assertEqual(payload["proxy_diagnostics"]["accept"], "text/event-stream")
        self.assertTrue(payload["proxy_diagnostics"]["stream_events"])

    def test_proxy_http_error_records_non_secret_diagnostics(self) -> None:
        def raise_http_error(*_: object, **__: object) -> object:
            raise tldr_once.error.HTTPError(
                "https://proxy.example/v1/tldr",
                404,
                "Not Found",
                {"content-type": "application/json"},
                BytesIO(b'{"detail":"Not Found"}'),
            )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screen.png"
            screenshot.write_bytes(b"fake")
            with mock.patch.object(tldr_once.request, "urlopen", side_effect=raise_http_error):
                payload = tldr_once.generate_via_proxy(
                    request_payload={"request_id": "req-http"},
                    settings={
                        "model": "gemini-3-flash-preview",
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "media_resolution": "MEDIA_RESOLUTION_LOW",
                        "timeout_seconds": 120,
                    },
                    proxy_settings={"url": "https://proxy.example", "token": "token"},
                    image_paths=[screenshot],
                    stream_events=True,
                )

        self.assertEqual(payload["status"], "error")
        self.assertEqual(payload["suggestions"], ["Not Found"])
        self.assertEqual(
            payload["proxy_diagnostics"],
            {
                "scheme": "https",
                "host": "proxy.example",
                "base_path": "/",
                "request_path": "/v1/tldr",
                "accept": "text/event-stream",
                "stream_events": True,
                "http_status": 404,
                "content_type": "application/json",
                "error_type": "http_error",
            },
        )

    def test_proxy_stream_non_sse_response_records_diagnostics(self) -> None:
        class FakeResponse:
            status = 200
            headers = {"content-type": "application/json"}

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *_: object) -> None:
                return None

            def read(self) -> bytes:
                return b'{"detail":"Not Found"}'

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screen.png"
            screenshot.write_bytes(b"fake")
            with mock.patch.object(tldr_once.request, "urlopen", return_value=FakeResponse()):
                payload = tldr_once.generate_via_proxy(
                    request_payload={"request_id": "req-non-sse"},
                    settings={
                        "model": "gemini-3-flash-preview",
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "media_resolution": "MEDIA_RESOLUTION_LOW",
                        "timeout_seconds": 120,
                    },
                    proxy_settings={"url": "https://proxy.example", "token": "token"},
                    image_paths=[screenshot],
                    stream_events=True,
                )

        self.assertEqual(payload["status"], "error")
        self.assertEqual(payload["suggestions"], ["Not Found"])
        self.assertEqual(payload["proxy_diagnostics"]["host"], "proxy.example")
        self.assertEqual(payload["proxy_diagnostics"]["http_status"], 200)
        self.assertEqual(payload["proxy_diagnostics"]["content_type"], "application/json")
        self.assertEqual(payload["proxy_diagnostics"]["error_type"], "non_sse_response")

    def test_proxy_stream_accepts_json_final_response_fallback(self) -> None:
        class FakeResponse:
            status = 200
            headers = {"content-type": "application/json"}

            def __enter__(self) -> "FakeResponse":
                return self

            def __exit__(self, *_: object) -> None:
                return None

            def read(self) -> bytes:
                return json.dumps(
                    {
                        "request_id": "req-json-fallback",
                        "status": "ok",
                        "tldr": "Sarah needs a reply.",
                        "suggestions": ["One", "Two", "Three"],
                        "duration_ms": 12,
                        "model": "gemini-3-flash-preview",
                        "warnings": [],
                    }
                ).encode("utf-8")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screen.png"
            screenshot.write_bytes(b"fake")
            with mock.patch.object(tldr_once.request, "urlopen", return_value=FakeResponse()):
                payload = tldr_once.generate_via_proxy(
                    request_payload={"request_id": "req-json-fallback"},
                    settings={
                        "model": "gemini-3-flash-preview",
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "media_resolution": "MEDIA_RESOLUTION_LOW",
                        "timeout_seconds": 120,
                    },
                    proxy_settings={"url": "https://proxy.example", "token": "token"},
                    image_paths=[screenshot],
                    stream_events=True,
                )

        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["request_id"], "req-json-fallback")
        self.assertEqual(payload["suggestions"], ["One", "Two", "Three"])
        self.assertEqual(payload["proxy_diagnostics"]["fallback"], "json_response")
        self.assertNotIn("error_type", payload["proxy_diagnostics"])

    def test_args_screenshot_cap(self) -> None:
        with self.assertRaisesRegex(ValueError, "At most 8 screenshots"):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                screenshots = []
                for index in range(9):
                    screenshot = root / f"screen-{index}.png"
                    screenshot.write_bytes(b"fake-png")
                    screenshots.extend(["--screenshot", str(screenshot)])
                runtime = root / "runtime.json"
                runtime.write_text('{"version":1}', encoding="utf-8")
                tldr_once.main(
                    screenshots
                    + [
                        "--runtime",
                        str(runtime),
                        "--out-dir",
                        str(root / "runs"),
                        "--skip-gemini",
                    ]
                )

    def test_generate_appends_image_parts_in_order(self) -> None:
        captured: dict[str, Any] = {}

        class FakePart:
            def __init__(self, data: bytes, mime_type: str) -> None:
                self.data = data
                self.mime_type = mime_type

            @classmethod
            def from_bytes(cls, *, data: bytes, mime_type: str) -> "FakePart":
                return cls(data, mime_type)

        class FakeTypes:
            class HttpOptions:
                def __init__(self, **_: Any) -> None:
                    pass

            Part = FakePart

        class FakeResponse:
            text = '{"tldr":"Frame two matters.","suggestions":["One","Two","Three"]}'
            usage_metadata = {"total_token_count": 1}

        class FakeModels:
            def generate_content(self, **kwargs: Any) -> FakeResponse:
                captured.update(kwargs)
                return FakeResponse()

        class FakeClient:
            models = FakeModels()

        class FakeGenAI:
            Client = mock.Mock(return_value=FakeClient())

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first.png"
            second = root / "second.png"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            with mock.patch.dict(
                sys.modules,
                {
                    "google": mock.Mock(genai=FakeGenAI),
                    "google.genai": mock.Mock(types=FakeTypes),
                },
            ), mock.patch.object(
                tldr_once,
                "prepare_screenshot_part",
                side_effect=[
                    (FakePart(b"one", "image/png"), {"image_bytes_original": 1, "image_bytes_compressed": 1, "image_prepare_ms": 0}),
                    (FakePart(b"two", "image/png"), {"image_bytes_original": 1, "image_bytes_compressed": 1, "image_prepare_ms": 0}),
                ],
            ), mock.patch.object(
                tldr_once,
                "build_generate_config",
                return_value={"config": True},
            ):
                tldr_once.generate(
                    [first, second],
                    "PROMPT",
                    {
                        "model": "gemini-3.1-flash-lite-preview",
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "media_resolution": "MEDIA_RESOLUTION_LOW",
                        "timeout_seconds": 120,
                    },
                )

        contents = captured["contents"]
        self.assertEqual([part.data for part in contents[:2]], [b"one", b"two"])
        self.assertEqual(contents[2], tldr_once.MODEL_CONTENT_TEXT)

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

        captured_config.clear()
        flash_preview_settings = dict(base_settings, model="gemini-3-flash-preview")
        with mock.patch.object(tldr_once, "response_schema", return_value={"schema": "ok"}):
            tldr_once.build_generate_config(FakeTypes, "PROMPT", flash_preview_settings)
        self.assertEqual(captured_config["media_resolution"], "MEDIA_RESOLUTION_MEDIUM")

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

    def test_media_resolution_guard_forces_medium_on_flash_preview(self) -> None:
        self.assertEqual(
            tldr_once.media_resolution_for_model(
                "gemini-3-flash-preview",
                "MEDIA_RESOLUTION_LOW",
            ),
            "MEDIA_RESOLUTION_MEDIUM",
        )

    def test_media_resolution_guard_passthrough_for_lite(self) -> None:
        self.assertEqual(
            tldr_once.media_resolution_for_model(
                "gemini-3.1-flash-lite-preview",
                "MEDIA_RESOLUTION_LOW",
            ),
            "MEDIA_RESOLUTION_LOW",
        )

    def test_image_prep_falls_back_to_png_when_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screenshot.png"
            write_test_png(screenshot)

            prepared = prepare_request_image(
                screenshot,
                {"preprocess_request_images": False},
                dest_dir=root,
            )

            self.assertEqual(prepared["bytes_data"], screenshot.read_bytes())
            self.assertEqual(prepared["mime_type"], "image/png")
            self.assertEqual(prepared["original_bytes"], prepared["request_bytes"])
            self.assertEqual(prepared["log"]["status"], "original")

    def test_image_prep_emits_jpeg_when_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            screenshot = root / "screenshot.png"
            write_test_png(screenshot, width=1600, height=1200)

            prepared = prepare_request_image(
                screenshot,
                {
                    "preprocess_request_images": True,
                    "request_image_format": "jpeg",
                    "request_image_max_dimension": 1600,
                    "request_image_jpeg_quality": 70,
                },
                dest_dir=root,
            )

        self.assertEqual(prepared["mime_type"], "image/jpeg")
        self.assertLess(prepared["request_bytes"], prepared["original_bytes"])
        self.assertEqual(prepared["log"]["status"], "processed")

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

    def test_run_json_records_image_diagnostics(self) -> None:
        old_key = os.environ.get("GEMINI_API_KEY")
        try:
            os.environ["GEMINI_API_KEY"] = "test-key"
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
                fake_response = {
                    "status": "ok",
                    "tldr": "Sarah needs a reply.",
                    "suggestions": ["One", "Two", "Three"],
                    "raw": "{}",
                    "usage": None,
                    "duration_ms": 12,
                    "parse_error": None,
                    "warnings": [],
                    "request_id": None,
                    "model": "gemini-3.1-flash-lite-preview",
                    "image_bytes_original": 1000,
                    "image_bytes_compressed": 420,
                    "image_prepare_ms": 7,
                    "media_resolution_resolved": "MEDIA_RESOLUTION_LOW",
                }
                with mock.patch.object(tldr_once, "generate", return_value=fake_response):
                    with redirect_stdout(stdout):
                        code = tldr_once.main(
                            [
                                "--screenshot",
                                str(screenshot),
                                "--runtime",
                                str(runtime),
                                "--out-dir",
                                str(out_dir),
                            ]
                        )

                self.assertEqual(code, 0)
                bundle = next(out_dir.iterdir())
                run = json.loads((bundle / "run.json").read_text(encoding="utf-8"))
                self.assertEqual(run["image_bytes_original"], 1000)
                self.assertEqual(run["image_bytes_compressed"], 420)
                self.assertEqual(run["image_prepare_ms"], 7)
                self.assertEqual(run["media_resolution_resolved"], "MEDIA_RESOLUTION_LOW")
                self.assertEqual(run["response"]["media_resolution_resolved"], "MEDIA_RESOLUTION_LOW")
        finally:
            if old_key is None:
                os.environ.pop("GEMINI_API_KEY", None)
            else:
                os.environ["GEMINI_API_KEY"] = old_key

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
        self.assertEqual(context["surface_match_debug"]["match_mode"], "bundle_match")
        self.assertEqual(context["matched_history_count"], 1)
        self.assertEqual(context["voice_sample_count"], 1)

    def test_build_stateful_context_matches_same_app_when_focused_element_differs(self) -> None:
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
        self.assertEqual(context["surface_match_debug"]["match_mode"], "bundle_match")
        self.assertEqual(len(context["recent_surface_history"]), 3)
        self.assertEqual([sample["text"] for sample in context["voice_samples"]], ["reply 2", "reply 1", "reply 0"])

    def test_build_stateful_context_keeps_scanning_for_voice_after_history_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            rows = [
                ("20260503-120400-000", "2026-05-03T12:04:05+00:00", None, "Newest run.", ["a", "b", "c"]),
                ("20260503-120300-000", "2026-05-03T12:03:05+00:00", None, "Second newest run.", ["d", "e", "f"]),
                ("20260503-120250-000", "2026-05-03T12:02:55+00:00", None, "Third newest run.", ["g", "h", "i"]),
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
        self.assertEqual(
            [item["tldr"] for item in context["recent_surface_history"]],
            ["Newest run.", "Second newest run.", "Third newest run."],
        )
        self.assertEqual([sample["text"] for sample in context["voice_samples"]], ["older custom reply"])
        self.assertEqual(context["preference_examples"][0]["user_typed"], "older custom reply")
        self.assertEqual(context["preference_examples"][0]["rejected_suggestions"], ["Sounds good.", "I agree.", "Let's proceed."])
        self.assertEqual(context["matched_history_count"], 3)
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

    def test_build_stateful_context_excludes_old_runs_outside_window(self) -> None:
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
        self.assertEqual(context["surface_match_debug"]["skipped_reasons"]["bundle_match_too_old"], 1)

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
        self.assertEqual(len(context["recent_surface_history"]), 1)
        self.assertEqual(context["recent_surface_history"][0]["chosen_action"], "copied")
        self.assertEqual(context["recent_surface_history"][0]["chosen_text"], "Model-authored text")
        self.assertEqual(context["surface_match_debug"]["match_mode"], "bundle_match")

    def test_build_stateful_context_uses_window_id_when_both_runs_have_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            other = runs / "20260503-120000-000"
            other.mkdir(parents=True)
            (other / "request.json").write_text(
                json.dumps(
                    {
                        "frontmost_app": {"bundle_id": "com.example.chat", "window_id": 999},
                    }
                ),
                encoding="utf-8",
            )
            (other / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "custom_reply_text": "from a different window",
                        "response": {"tldr": "Other window."},
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {"frontmost_app": {"bundle_id": "com.example.chat", "window_id": 7}},
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["voice_samples"], [])
        self.assertEqual(context["recent_surface_history"], [])
        self.assertEqual(
            context["surface_match_debug"]["skipped_reasons"]["window_id_mismatch"],
            1,
        )

    def test_build_stateful_context_window_id_match_promotes_match_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            same = runs / "20260503-120000-000"
            same.mkdir(parents=True)
            (same / "request.json").write_text(
                json.dumps(
                    {
                        "frontmost_app": {"bundle_id": "com.example.chat", "window_id": 7},
                    }
                ),
                encoding="utf-8",
            )
            (same / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "custom_reply_text": "same window reply",
                        "response": {"tldr": "Same window."},
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {"frontmost_app": {"bundle_id": "com.example.chat", "window_id": 7}},
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["surface_match_debug"]["match_mode"], "window_match")
        self.assertEqual(context["matched_history_count"], 1)

    def test_build_stateful_context_falls_back_to_bundle_match_when_window_id_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runs = root / "runs"
            old = runs / "20260503-120000-000"
            old.mkdir(parents=True)
            # Previous run has no window_id (legacy / pre-upgrade run).
            (old / "request.json").write_text(
                json.dumps({"frontmost_app": {"bundle_id": "com.example.chat"}}),
                encoding="utf-8",
            )
            (old / "run.json").write_text(
                json.dumps(
                    {
                        "finished_at": "2026-05-03T12:00:05+00:00",
                        "custom_reply_text": "legacy run reply",
                        "response": {"tldr": "Legacy run."},
                    }
                ),
                encoding="utf-8",
            )

            context = tldr_once.build_stateful_context(
                runs,
                {"frontmost_app": {"bundle_id": "com.example.chat", "window_id": 7}},
                now=tldr_once._parse_iso("2026-05-03T12:05:00+00:00"),
            )

        self.assertIsNotNone(context)
        assert context is not None
        self.assertEqual(context["surface_match_debug"]["match_mode"], "bundle_match")
        self.assertEqual(context["matched_history_count"], 1)

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
        old_disable = os.environ.get("TLDR_DISABLE_PROXY")
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
                os.environ.pop("TLDR_DISABLE_PROXY", None)

                def fake_proxy(
                    request_payload: dict[str, object],
                    settings: dict[str, object],
                    proxy_settings: dict[str, str],
                    image_paths: list[Path],
                    stream_events: bool = False,
                ) -> dict[str, object]:
                    self.assertIn("stateful_context", request_payload)
                    self.assertEqual(request_payload["preferences"]["model"], "gemini-3.1-flash-lite-preview")
                    self.assertEqual(len(image_paths), 1)
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
                with (
                    mock.patch.object(tldr_once, "proxy_settings_from_env", return_value={"url": "https://proxy.example", "token": "token"}),
                    mock.patch.object(tldr_once, "generate_via_proxy", side_effect=fake_proxy),
                    redirect_stdout(stdout),
                ):
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
                self.assertIn("Stateful TLDR context:", model_context["proxy_server_preview"]["system_instruction"])
                self.assertEqual(model_context["proxy_server_preview"]["contents"], [tldr_once.MODEL_CONTENT_TEXT])
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


if __name__ == "__main__":
    unittest.main()
