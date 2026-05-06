from __future__ import annotations

import json
import os
import unittest
from typing import Any
from unittest import mock

import httpx
from fastapi.testclient import TestClient

from server import gemini
from server.main import _selected_settings, app
from server.storage import TelemetryStore


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_API_TOKENS": "dev-token",
                "GEMINI_API_KEY": "test-key",
                "TLDR_ALLOWED_MODELS": "gemini-3.1-flash-lite-preview",
            },
            clear=False,
        )
        self.env.start()
        self.client = TestClient(app)

    def tearDown(self) -> None:
        self.env.stop()

    def test_healthz_returns_ok(self) -> None:
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_tldr_success(self, create_client: mock.Mock, generate: mock.Mock) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're reviewing a plan.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 321,
            "usage": {"total_token_count": 42},
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "tldr": "You're reviewing a plan.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 321,
                "model": "gemini-3.1-flash-lite-preview",
            },
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_success(self, create_client: mock.Mock, generate: mock.Mock) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertEqual(kwargs["settings"]["model"], "gemini-3.1-flash-lite-preview")
            self.assertEqual(kwargs["settings"]["temperature"], 0.3)
            self.assertEqual(kwargs["settings"]["max_output_tokens"], 640)
            return {
                "status": "ok",
                "tldr": "You're in Messages.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 111,
                "usage": {"total_token_count": 7},
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate

        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-123",
                        "schema_version": 1,
                        "capture_mode": "frontmost_window",
                        "client": {"install_id": "install-abc"},
                        "input_mode": "screenshot",
                        "preferences": {
                            "model": "gemini-3.1-flash-lite-preview",
                            "temperature": 0.3,
                            "max_output_tokens": 640,
                        },
                        "frontmost_app": {"app_name": "Messages"},
                        "consent": {"allow_event_logging": True, "allow_content_retention": False},
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["request_id"], "req-123")
        self.assertEqual(response.json()["status"], "ok")
        self.assertEqual(response.json()["warnings"], [])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions_streaming")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_streams_sse_frames(
        self,
        create_client: mock.Mock,
        generate_streaming: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate_streaming.return_value = iter(
            [
                {"event": "partial_tldr", "data": {"tldr": "Sarah needs a reply."}},
                {"event": "partial_suggestions", "data": {"suggestions": ["One", "Two"]}},
                {
                    "event": "final",
                    "data": {
                        "status": "ok",
                        "tldr": "Sarah needs a reply.",
                        "suggestions": ["One", "Two", "Three"],
                        "duration_ms": 22,
                        "usage": {"total_token_count": 10},
                        "model": "gemini-3.1-flash-lite-preview",
                    },
                },
            ]
        )

        response = self.client.post(
            "/v1/tldr",
            headers={
                "Authorization": "Bearer dev-token",
                "Accept": "text/event-stream",
            },
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-sse",
                        "schema_version": 1,
                        "capture_mode": "frontmost_window",
                        "input_mode": "screenshot",
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertIn("text/event-stream", response.headers["content-type"])

        frames = [frame for frame in response.text.split("\n\n") if frame.strip()]
        parsed: list[tuple[str, dict[str, Any]]] = []
        for frame in frames:
            lines = frame.split("\n")
            event_line = next(line for line in lines if line.startswith("event: "))
            data_line = next(line for line in lines if line.startswith("data: "))
            parsed.append(
                (event_line[len("event: ") :], json.loads(data_line[len("data: ") :]))
            )

        self.assertEqual(
            [name for name, _ in parsed],
            ["partial_tldr", "partial_suggestions", "final"],
        )
        self.assertEqual(parsed[0][1], {"tldr": "Sarah needs a reply."})
        self.assertEqual(parsed[1][1], {"suggestions": ["One", "Two"]})
        self.assertEqual(parsed[2][1]["request_id"], "req-sse")
        self.assertEqual(parsed[2][1]["status"], "ok")
        self.assertEqual(parsed[2][1]["suggestions"], ["One", "Two", "Three"])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions_streaming")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_sse_final_with_parse_error_emits_status_in_frame(
        self,
        create_client: mock.Mock,
        generate_streaming: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate_streaming.return_value = iter(
            [
                {
                    "event": "final",
                    "data": {
                        "status": "parse_error",
                        "tldr": "Gemini returned non-JSON output.",
                        "suggestions": [],
                        "duration_ms": 12,
                        "usage": None,
                        "model": "gemini-3-flash-preview",
                    },
                },
            ]
        )

        response = self.client.post(
            "/v1/tldr",
            headers={
                "Authorization": "Bearer dev-token",
                "Accept": "text/event-stream",
            },
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-sse-bad",
                        "schema_version": 1,
                        "capture_mode": "frontmost_window",
                        "input_mode": "screenshot",
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        frame = next(f for f in response.text.split("\n\n") if f.strip())
        data_line = next(line for line in frame.split("\n") if line.startswith("data: "))
        payload = json.loads(data_line[len("data: ") :])
        self.assertEqual(payload["status"], "parse_error")
        self.assertEqual(payload["request_id"], "req-sse-bad")

    def test_gemini_config_forces_medium_media_resolution_for_gemini_3_flash(self) -> None:
        captured_config: dict[str, Any] = {}

        class FakeThinkingConfig:
            def __init__(self, **_: Any) -> None:
                pass

        class FakeGenerateContentConfig:
            def __init__(self, **kwargs: Any) -> None:
                captured_config.update(kwargs)

        class FakeTypes:
            ThinkingConfig = FakeThinkingConfig
            GenerateContentConfig = FakeGenerateContentConfig

        with mock.patch.object(gemini, "_schema", return_value={"schema": True}):
            gemini._generate_config(
                FakeTypes,
                {
                    "model": "gemini-3-flash-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                },
                "PROMPT",
            )

        self.assertEqual(captured_config["media_resolution"], "MEDIA_RESOLUTION_MEDIUM")

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_accepts_multiple_screenshots_in_order(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            images = kwargs["images"]
            self.assertEqual([data for data, _ in images], [b"zero", b"one", b"two"])
            return {
                "status": "ok",
                "tldr": "Long page summary.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 111,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-frames",
                        "schema_version": 1,
                        "capture_mode": "frontmost_window_scroll",
                        "input_mode": "screenshot",
                    }
                )
            },
            files=[
                ("screenshot_2", ("two.png", b"two", "image/png")),
                ("screenshot_0", ("zero.png", b"zero", "image/png")),
                ("screenshot_1", ("one.png", b"one", "image/png")),
            ],
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["request_id"], "req-frames")

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_legacy_single_screenshot_field(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertEqual(kwargs["images"], [(b"legacy", "image/png")])
            return {
                "status": "ok",
                "tldr": "Legacy screenshot summary.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 111,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-legacy-shot",
                        "input_mode": "screenshot",
                    }
                )
            },
            files={"screenshot": ("screen.png", b"legacy", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["request_id"], "req-legacy-shot")

    def test_v1_tldr_rejects_malformed_screenshot_field(self) -> None:
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={"request": json.dumps({"request_id": "req-bad", "input_mode": "screenshot"})},
            files={"screenshot_foo": ("screen.png", b"bad", "image/png")},
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("invalid screenshot frame field", response.json()["detail"])

    def test_v1_tldr_rejects_out_of_range_screenshot_field(self) -> None:
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={"request": json.dumps({"request_id": "req-bad-index", "input_mode": "screenshot"})},
            files={"screenshot_999": ("screen.png", b"bad", "image/png")},
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("invalid screenshot frame field", response.json()["detail"])

    def test_v1_tldr_rejects_string_screenshot_field(self) -> None:
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps({"request_id": "req-string-frame", "input_mode": "screenshot"}),
                "screenshot_0": "not-a-file",
            },
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("must be a file", response.json()["detail"])

    def test_v1_tldr_rejects_duplicate_frame_zero(self) -> None:
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={"request": json.dumps({"request_id": "req-dup", "input_mode": "screenshot"})},
            files=[
                ("screenshot", ("legacy.png", b"legacy", "image/png")),
                ("screenshot_0", ("zero.png", b"zero", "image/png")),
            ],
        )

        self.assertEqual(response.status_code, 422)
        self.assertIn("duplicate screenshot frame index", response.json()["detail"])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_accepts_ocr_metadata_with_screenshot(self, create_client: mock.Mock, generate: mock.Mock) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're drafting a reply.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 55,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-ocr",
                        "input_mode": "screenshot",
                        "ocr_packet": {
                            "blocks": [{"text": "Can you send the doc?", "confidence": 0.98}]
                        },
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["request_id"], "req-ocr")

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_sends_content_to_model_but_redacts_storage_without_retention_opt_in(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertNotIn("context_text", kwargs)
            return {
                "status": "ok",
                "tldr": "You're drafting a reply.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 77,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        telemetry_store = mock.Mock()

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-private",
                            "client": {"install_id": "install-private"},
                            "input_mode": "screenshot",
                            "focused_context": {
                                "value": "secret draft",
                                "selected_text": "draft",
                            },
                            "ocr_packet": {
                                "blocks": [{"text": "ocr secret", "confidence": 0.9}]
                            },
                            "consent": {
                                "allow_event_logging": True,
                                "allow_content_retention": False,
                            },
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        recorded = telemetry_store.record_request.call_args.args[0]
        self.assertEqual(recorded["install_id"], "install-private")
        self.assertEqual(recorded["summary"], "You're drafting a reply.")
        self.assertEqual(recorded["suggestions"], ["One", "Two", "Three"])
        self.assertEqual(recorded["focused_context"]["value"]["redacted"], True)
        self.assertEqual(recorded["ocr_packet"]["blocks"][0]["text"]["redacted"], True)

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_sends_stateful_context_to_model_and_redacts_storage_without_retention(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            prompt_text = kwargs["prompt_text"]
            self.assertIn("sounds good, i'll take a look", prompt_text)
            self.assertIn("Sarah asked for a review", prompt_text)
            return {
                "status": "ok",
                "tldr": "Sarah needs a reply.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 77,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        telemetry_store = mock.Mock()

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-stateful",
                            "input_mode": "screenshot",
                            "ocr_packet": {"blocks": [{"text": "current ask"}]},
                            "stateful_context": {
                                "schema_version": 1,
                                "voice_samples": [
                                    {"text": "sounds good, i'll take a look"}
                                ],
                                "recent_surface_history": [
                                    {
                                        "tldr": "Sarah asked for a review",
                                        "custom_reply_text": "i'll review this now",
                                    }
                                ],
                            },
                            "consent": {
                                "allow_event_logging": True,
                                "allow_content_retention": False,
                            },
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        recorded = telemetry_store.record_request.call_args.args[0]
        self.assertEqual(
            recorded["stateful_context"]["voice_samples"][0]["text"]["redacted"],
            True,
        )
        self.assertEqual(
            recorded["stateful_context"]["recent_surface_history"][0]["custom_reply_text"]["redacted"],
            True,
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_skips_response_cache_without_retention_opt_in(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're drafting a reply.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 44,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }
        cache = mock.Mock()
        cache.enabled = True
        telemetry_store = mock.Mock()

        with mock.patch("server.main._response_cache", return_value=cache), mock.patch(
            "server.main._telemetry_store",
            return_value=telemetry_store,
        ):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-no-cache",
                            "input_mode": "screenshot",
                            "ocr_packet": {"blocks": [{"text": "private cache text"}]},
                            "consent": {"allow_content_retention": False},
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        cache.get.assert_not_called()
        cache.set.assert_not_called()

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_warns_on_disallowed_model(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're reviewing a plan.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 99,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-model",
                        "input_mode": "screenshot",
                        "preferences": {"model": "not-allowed"},
                        "ocr_packet": {"blocks": [{"text": "hello"}]},
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertIn("requested_model_disallowed", response.json()["warnings"])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_propagates_thinking_level_preference(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertEqual(kwargs["settings"].get("thinking_level"), "high")
            return {
                "status": "ok",
                "tldr": "ok",
                "suggestions": ["a", "b", "c"],
                "duration_ms": 1,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate

        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-thinking",
                        "input_mode": "screenshot",
                        "preferences": {"thinking_level": "HIGH"},
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["warnings"], [])

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_warns_on_disallowed_thinking_level(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertNotIn("thinking_level", kwargs["settings"])
            return {
                "status": "ok",
                "tldr": "ok",
                "suggestions": ["a", "b", "c"],
                "duration_ms": 1,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate

        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-thinking-bad",
                        "input_mode": "screenshot",
                        "preferences": {"thinking_level": "ludicrous"},
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 200)
        self.assertIn("requested_thinking_level_disallowed", response.json()["warnings"])

    def test_selected_settings_accepts_each_thinking_level(self) -> None:
        for raw, expected in [
            ("low", "low"),
            ("medium", "medium"),
            ("high", "high"),
            ("HIGH", "high"),
            ("  Medium  ", "medium"),
        ]:
            warnings: list[str] = []
            settings = _selected_settings({"preferences": {"thinking_level": raw}}, warnings)
            self.assertEqual(settings.get("thinking_level"), expected, raw)
            self.assertEqual(warnings, [], raw)

    def test_selected_settings_silently_ignores_empty_thinking_level(self) -> None:
        for raw in ["", "   "]:
            warnings: list[str] = []
            settings = _selected_settings({"preferences": {"thinking_level": raw}}, warnings)
            self.assertNotIn("thinking_level", settings)
            self.assertEqual(warnings, [], repr(raw))

    def test_selected_settings_silently_ignores_non_string_thinking_level(self) -> None:
        for raw in [1, True, None, ["high"], {"value": "high"}]:
            warnings: list[str] = []
            settings = _selected_settings({"preferences": {"thinking_level": raw}}, warnings)
            self.assertNotIn("thinking_level", settings)
            self.assertEqual(warnings, [], repr(raw))

    def test_selected_settings_warns_on_unknown_thinking_level(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings(
            {"preferences": {"thinking_level": "ludicrous"}}, warnings
        )
        self.assertNotIn("thinking_level", settings)
        self.assertEqual(warnings, ["requested_thinking_level_disallowed"])

    def test_selected_settings_omits_thinking_level_when_absent(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings({"preferences": {}}, warnings)
        self.assertNotIn("thinking_level", settings)
        self.assertEqual(warnings, [])

        warnings = []
        settings = _selected_settings({}, warnings)
        self.assertNotIn("thinking_level", settings)
        self.assertEqual(warnings, [])

    def test_generate_config_uses_default_low_for_thinking_model_without_override(self) -> None:
        captured_thinking: dict[str, Any] = {}

        class FakeThinkingConfig:
            def __init__(self, **kwargs: Any) -> None:
                captured_thinking.update(kwargs)

        class FakeGenerateContentConfig:
            def __init__(self, **_: Any) -> None:
                pass

        class FakeTypes:
            ThinkingConfig = FakeThinkingConfig
            GenerateContentConfig = FakeGenerateContentConfig

        with mock.patch.object(gemini, "_schema", return_value={"schema": True}):
            gemini._generate_config(
                FakeTypes,
                {
                    "model": "gemini-3-flash-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                },
                "PROMPT",
            )

        self.assertEqual(captured_thinking, {"thinking_level": "low"})

    def test_generate_config_uses_client_thinking_level_override(self) -> None:
        captured_thinking: dict[str, Any] = {}

        class FakeThinkingConfig:
            def __init__(self, **kwargs: Any) -> None:
                captured_thinking.update(kwargs)

        class FakeGenerateContentConfig:
            def __init__(self, **_: Any) -> None:
                pass

        class FakeTypes:
            ThinkingConfig = FakeThinkingConfig
            GenerateContentConfig = FakeGenerateContentConfig

        with mock.patch.object(gemini, "_schema", return_value={"schema": True}):
            gemini._generate_config(
                FakeTypes,
                {
                    "model": "gemini-3-flash-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                    "thinking_level": "high",
                },
                "PROMPT",
            )

        self.assertEqual(captured_thinking, {"thinking_level": "high"})

    def test_generate_config_ignores_thinking_level_on_non_thinking_model(self) -> None:
        captured_thinking: dict[str, Any] = {}
        thinking_called = False

        class FakeThinkingConfig:
            def __init__(self, **kwargs: Any) -> None:
                nonlocal thinking_called
                thinking_called = True
                captured_thinking.update(kwargs)

        class FakeGenerateContentConfig:
            def __init__(self, **_: Any) -> None:
                pass

        class FakeTypes:
            ThinkingConfig = FakeThinkingConfig
            GenerateContentConfig = FakeGenerateContentConfig

        with mock.patch.object(gemini, "_schema", return_value={"schema": True}):
            gemini._generate_config(
                FakeTypes,
                {
                    "model": "gemini-3.1-flash-lite-preview",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                    "thinking_level": "high",
                },
                "PROMPT",
            )

        self.assertFalse(thinking_called)
        self.assertEqual(captured_thinking, {})

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_still_succeeds_when_request_storage_fails(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're in Messages.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 88,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }
        telemetry_store = mock.Mock()
        telemetry_store.record_request.side_effect = RuntimeError("db unavailable")

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-storage-fail",
                            "input_mode": "screenshot",
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["request_id"], "req-storage-fail")

    def test_tldr_rejects_oversized_screenshot(self) -> None:
        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={
                "screenshot": (
                    "screen.png",
                    b"x" * ((10 * 1024 * 1024) + 1),
                    "image/png",
                )
            },
        )

        self.assertEqual(response.status_code, 413)

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_tldr_maps_parse_error_to_503(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "parse_error",
            "tldr": "Gemini returned non-JSON output.",
            "suggestions": ["oops"],
            "duration_ms": 111,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }

        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer dev-token"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 503)
        self.assertIn("parse_error", response.json()["detail"])

    def test_tldr_rejects_bad_token(self) -> None:
        response = self.client.post(
            "/tldr",
            headers={"Authorization": "Bearer nope"},
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 401)

    def test_events_accept_valid_json(self) -> None:
        telemetry_store = mock.Mock()
        telemetry_store.record_event.return_value = True

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer dev-token"},
                json={
                    "request_id": "req-123",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                    "client": {"install_id": "install-abc"},
                },
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True, "stored": True})
        stored_payload = telemetry_store.record_event.call_args.kwargs["payload"]
        self.assertEqual(stored_payload["install_id"], "install-abc")

    def test_events_endpoint_does_not_mutate_request_row(self) -> None:
        # Outcome is now derived from the run_completed event via the
        # tldr_requests_with_outcome view, so the events handler should
        # only record the event itself — never UPDATE the requests table.
        telemetry_store = mock.Mock()
        telemetry_store.record_event.return_value = True

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer dev-token"},
                json={
                    "request_id": "req-123",
                    "event_type": "run_completed",
                    "created_at": "2026-04-29T00:00:00Z",
                    "details": {"outcome": "user_typed"},
                },
            )
        self.assertEqual(response.status_code, 200)
        telemetry_store.record_event.assert_called_once()
        # Mock auto-creates attributes on access; .called is False unless we
        # actually invoked it, so this asserts the mutation path is gone.
        self.assertFalse(telemetry_store.update_request_outcome.called)

    def test_auth_mint_uses_bootstrap_and_persists_hashed_device_token(self) -> None:
        telemetry_store = mock.Mock()

        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": "bootstrap"}, clear=False), \
             mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/auth/mint",
                headers={"Authorization": "Bearer bootstrap"},
                json={"install_id": "install-abc"},
            )

        self.assertEqual(response.status_code, 200)
        token = response.json()["token"]
        self.assertTrue(token.startswith("tldr_dt_"))
        call = telemetry_store.mint_device_token.call_args.kwargs
        self.assertEqual(call["install_id"], "install-abc")
        self.assertEqual(len(call["token_hash"]), 64)

    def test_bootstrap_token_accepted_on_events_during_legacy_window(self) -> None:
        # During the upgrade window (BLINK_LEGACY_TOKEN_ALLOWED defaults true)
        # the bundled bootstrap token should also satisfy non-mint endpoints
        # so first-launch installs aren't bricked between launch and a
        # successful mint round-trip.
        telemetry_store = mock.Mock()
        telemetry_store.record_event.return_value = True

        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": "bootstrap"}, clear=False), \
             mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer bootstrap"},
                json={
                    "request_id": "req-bootstrap-event",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                },
            )
        self.assertEqual(response.status_code, 200)

    def test_bootstrap_token_rejected_on_events_when_legacy_disabled(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "BLINK_BOOTSTRAP_TOKEN": "bootstrap",
                "BLINK_LEGACY_TOKEN_ALLOWED": "false",
            },
            clear=False,
        ):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer bootstrap"},
                json={
                    "request_id": "req-bootstrap-event",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                },
            )
        self.assertEqual(response.status_code, 401)
        self.assertIn(
            "bootstrap token is only valid for minting",
            response.json()["detail"],
        )

    def test_legacy_shared_token_rejected_when_legacy_disabled(self) -> None:
        with mock.patch.dict(
            os.environ,
            {"BLINK_LEGACY_TOKEN_ALLOWED": "false"},
            clear=False,
        ):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer dev-token"},
                json={
                    "request_id": "req-legacy",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                },
            )
        self.assertEqual(response.status_code, 401)

    def test_auth_mint_rejects_install_id_over_128_chars(self) -> None:
        long_install_id = "x" * 129
        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": "bootstrap"}, clear=False):
            response = self.client.post(
                "/v1/auth/mint",
                headers={"Authorization": "Bearer bootstrap"},
                json={"install_id": long_install_id},
            )
        self.assertEqual(response.status_code, 422)
        self.assertIn("128", response.json()["detail"])

    def test_auth_mint_returns_500_when_bootstrap_empty(self) -> None:
        with mock.patch.dict(os.environ, {"BLINK_BOOTSTRAP_TOKEN": ""}, clear=False):
            response = self.client.post(
                "/v1/auth/mint",
                headers={"Authorization": "Bearer anything"},
                json={"install_id": "install-abc"},
            )
        self.assertEqual(response.status_code, 500)

    def test_events_report_unstored_when_storage_disabled(self) -> None:
        with mock.patch(
            "server.main._telemetry_store",
            return_value=TelemetryStore(database_url=None, enabled=False),
        ):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer dev-token"},
                json={
                    "request_id": "req-disabled",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                },
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True, "stored": False})

    def test_events_still_succeed_when_storage_fails(self) -> None:
        telemetry_store = mock.Mock()
        telemetry_store.record_event.side_effect = RuntimeError("db unavailable")

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr/events",
                headers={"Authorization": "Bearer dev-token"},
                json={
                    "request_id": "req-123",
                    "event_type": "capture_started",
                    "created_at": "2026-04-29T00:00:00Z",
                },
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"ok": True, "stored": False})

    def test_proxy_rejects_bad_token(self) -> None:
        response = self.client.post(
            "/v1beta/models/gemini:generateContent",
            headers={"Authorization": "Bearer nope"},
            json={"contents": []},
        )
        self.assertEqual(response.status_code, 401)

    def test_proxy_500_when_server_missing_gemini_key(self) -> None:
        with mock.patch.dict(os.environ, {"GEMINI_API_KEY": ""}):
            response = self.client.post(
                "/v1beta/models/gemini:generateContent",
                headers={"Authorization": "Bearer dev-token"},
                json={"contents": []},
            )
        self.assertEqual(response.status_code, 500)

    def test_proxy_forwards_body_and_swaps_api_key(self) -> None:
        captured: dict[str, Any] = {}

        async def fake_send(self_client: httpx.AsyncClient, req: httpx.Request, stream: bool = False, **_: Any) -> Any:
            captured["url"] = str(req.url)
            captured["headers"] = {k.lower(): v for k, v in req.headers.items()}
            captured["body"] = req.read()
            response = mock.Mock()
            response.status_code = 200
            response.headers = {"content-type": "application/json"}

            async def aiter_raw() -> Any:
                yield b'{"ok":true}'

            async def aclose() -> None:
                return None

            response.aiter_raw = aiter_raw
            response.aclose = aclose
            return response

        with mock.patch.object(httpx.AsyncClient, "send", fake_send):
            response = self.client.post(
                "/v1beta/models/gemini:generateContent",
                headers={
                    "Authorization": "Bearer dev-token",
                    "x-goog-api-key": "client-side-leftover",
                    "Content-Type": "application/json",
                },
                content=b'{"contents":[{"parts":[{"text":"hi"}]}]}',
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b'{"ok":true}')
        self.assertEqual(captured["headers"].get("x-goog-api-key"), "test-key")
        self.assertNotIn("authorization", captured["headers"])
        self.assertEqual(
            captured["url"],
            "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent",
        )
        self.assertEqual(captured["body"], b'{"contents":[{"parts":[{"text":"hi"}]}]}')


if __name__ == "__main__":
    unittest.main()
