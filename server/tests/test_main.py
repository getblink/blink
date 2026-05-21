from __future__ import annotations

import json
import os
import unittest
from typing import Any
from unittest import mock

import httpx
from fastapi.testclient import TestClient

from server import gemini
from server.main import (
    _build_selection_block,
    _privacy_safe_envelope,
    _selected_settings,
    app,
)
from server.storage import TelemetryStore


class FakeThreadCache:
    enabled = True

    def __init__(self) -> None:
        self.threads: dict[tuple[str, str], dict[str, Any]] = {}
        self.aliases: dict[tuple[str, str], str] = {}
        self.set_thread_calls: list[tuple[str, str, dict[str, Any]]] = []

    def get_thread(self, *, token_id: str, root_request_id: str) -> dict[str, Any] | None:
        return self.threads.get((token_id, root_request_id)) or self.threads.get(("*", root_request_id))

    def set_thread(
        self,
        *,
        token_id: str,
        root_request_id: str,
        payload: dict[str, Any],
    ) -> None:
        self.threads[(token_id, root_request_id)] = payload
        self.set_thread_calls.append((token_id, root_request_id, payload))

    def resolve_root(self, *, token_id: str, request_id: str) -> str | None:
        return self.aliases.get((token_id, request_id)) or self.aliases.get(("*", request_id))

    def set_root_alias(
        self,
        *,
        token_id: str,
        request_id: str,
        root_request_id: str,
    ) -> None:
        self.aliases[(token_id, request_id)] = root_request_id


class MainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = mock.patch.dict(
            os.environ,
            {
                "BLINK_API_TOKENS": "dev-token",
                "GEMINI_API_KEY": "test-key",
                "BLINK_ALLOWED_MODELS": "gemini-3.1-flash-lite-preview",
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
            self.assertEqual(kwargs["settings"]["temperature"], gemini.DEFAULT_SETTINGS["temperature"])
            self.assertEqual(kwargs["settings"]["max_output_tokens"], gemini.DEFAULT_SETTINGS["max_output_tokens"])
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

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_success_creates_redis_thread(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're in Messages.",
            "suggestions": ["One", "Two", "Three"],
            "suggestion_details": [
                {"text": "One", "tags": ["Reply"]},
                {"text": "Two", "tags": ["Ask"]},
                {"text": "Three", "tags": ["Next"]},
            ],
            "duration_ms": 111,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }
        thread_cache = FakeThreadCache()
        telemetry_store = mock.Mock()

        with mock.patch("server.main._thread_cache", return_value=thread_cache), mock.patch(
            "server.main._telemetry_store",
            return_value=telemetry_store,
        ):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-thread",
                            "schema_version": 1,
                            "capture_mode": "frontmost_window",
                            "input_mode": "screenshot",
                            "consent": {"allow_content_retention": False},
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(thread_cache.set_thread_calls), 1)
        token_id, root_id, thread = thread_cache.set_thread_calls[0]
        self.assertTrue(token_id)
        self.assertEqual(root_id, "req-thread")
        self.assertEqual(thread["root_request_id"], "req-thread")
        self.assertEqual(thread["latest_request_id"], "req-thread")
        self.assertEqual(
            [turn["role"] for turn in thread["turns"]],
            ["user", "model"],
        )
        self.assertEqual(thread["turns"][0]["image_count"], 1)
        self.assertEqual(thread_cache.aliases[(token_id, "req-thread")], "req-thread")

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_thread_cache_never_stores_screenshot_bytes(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        generate.return_value = {
            "status": "ok",
            "tldr": "You're in Messages.",
            "suggestions": ["One", "Two", "Three"],
            "duration_ms": 111,
            "usage": None,
            "model": "gemini-3.1-flash-lite-preview",
        }
        thread_cache = FakeThreadCache()
        telemetry_store = mock.Mock()

        with mock.patch("server.main._thread_cache", return_value=thread_cache), mock.patch(
            "server.main._telemetry_store",
            return_value=telemetry_store,
        ):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-thread-private",
                            "input_mode": "screenshot",
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"raw-private-screenshot-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        stored = json.dumps(thread_cache.set_thread_calls[0][2], ensure_ascii=True)
        self.assertNotIn("raw-private-screenshot-bytes", stored)
        self.assertIn("screenshot_sha256", stored)

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_reroll_hydrates_previous_suggestions_from_store(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        source_id = "11111111-1111-4111-8111-111111111111"

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            prompt_text = kwargs["prompt_text"]
            self.assertNotIn("Reroll instructions:", prompt_text)
            turns = kwargs["conversation_turns"]
            self.assertEqual([turn["role"] for turn in turns], ["user", "model", "user"])
            self.assertEqual(turns[1]["suggestions"], ["Please send the doc.", "I'll take a look."])
            self.assertIn("fresh set", turns[2]["text"])
            self.assertIn("make this warmer", turns[2]["text"])
            self.assertEqual(turns[2]["follow_up_instruction"], "make this warmer")
            self.assertNotIn("Stateful Blink context:", prompt_text)
            return {
                "status": "ok",
                "tldr": "Sarah needs a reply.",
                "suggestions": ["One", "Two", "Three"],
                "suggestion_details": [
                    {"text": "One", "tags": ["Reply"]},
                    {"text": "Two", "tags": ["Ask"]},
                    {"text": "Three", "tags": ["Next"]},
                ],
                "duration_ms": 77,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        telemetry_store = mock.Mock()
        telemetry_store.get_previous_response.return_value = {
            "tldr": "Sarah asked for a doc.",
            "suggestions": ["Please send the doc.", "I'll take a look."],
            "suggestion_details": [
                {"text": "Please send the doc.", "tags": ["Ask"]},
                {"text": "I'll take a look.", "tags": ["Reply"]},
            ],
        }

        thread_cache = FakeThreadCache()
        with mock.patch("server.main._telemetry_store", return_value=telemetry_store), mock.patch(
            "server.main._thread_cache",
            return_value=thread_cache,
        ):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-reroll",
                            "schema_version": 1,
                            "capture_mode": "frontmost_window",
                            "input_mode": "screenshot",
                            "reroll_context": {
                                "schema_version": 1,
                                "source_request_id": source_id,
                                "follow_up_instruction": "make this warmer",
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
        self.assertIn("reroll_thread_cache_miss", response.json()["warnings"])
        self.assertIn("reroll_context_hydrated", response.json()["warnings"])
        telemetry_store.get_previous_response.assert_called_once()
        lookup_args = telemetry_store.get_previous_response.call_args.args
        self.assertEqual(lookup_args[0], source_id)
        self.assertIsInstance(lookup_args[1], str)
        self.assertTrue(lookup_args[1])
        recorded = telemetry_store.record_request.call_args.args[0]
        self.assertEqual(
            recorded["reroll_context"],
            {
                "schema_version": 1,
                "source_request_id": source_id,
                "follow_up_instruction": {
                    "redacted": True,
                    "char_count": 16,
                    "sha256_prefix": recorded["reroll_context"]["follow_up_instruction"]["sha256_prefix"],
                },
            },
        )
        self.assertEqual(
            recorded["suggestions"],
            [
                {"text": "One", "tags": ["Reply"]},
                {"text": "Two", "tags": ["Ask"]},
                {"text": "Three", "tags": ["Next"]},
            ],
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_reroll_with_redis_thread_sends_conversation_turns(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        root_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        source_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        current_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        thread_cache = FakeThreadCache()
        thread_cache.aliases[("*", source_id)] = root_id
        thread_cache.threads[("*", root_id)] = {
            "schema_version": 1,
            "root_request_id": root_id,
            "latest_request_id": source_id,
            "created_at": "2026-05-10T00:00:00Z",
            "updated_at": "2026-05-10T00:01:00Z",
            "turns": [
                {"role": "user", "kind": "capture", "request_id": root_id, "image_count": 1},
                {
                    "role": "model",
                    "kind": "response",
                    "request_id": root_id,
                    "tldr": "Sarah needs a reply.",
                    "suggestions": ["Original one", "Original two", "Original three"],
                    "suggestion_details": [
                        {"text": "Original one", "tags": ["Reply"]},
                        {"text": "Original two", "tags": ["Ask"]},
                        {"text": "Original three", "tags": ["Next"]},
                    ],
                },
                {"role": "user", "kind": "reroll", "request_id": source_id, "text": "reroll"},
                {
                    "role": "model",
                    "kind": "response",
                    "request_id": source_id,
                    "tldr": "Sarah still needs a reply.",
                    "suggestions": ["Prior one", "Prior two", "Prior three"],
                    "suggestion_details": [
                        {"text": "Prior one", "tags": ["Reply"]},
                        {"text": "Prior two", "tags": ["Ask"]},
                        {"text": "Prior three", "tags": ["Next"]},
                    ],
                },
            ],
        }

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertNotIn("Reroll instructions:", kwargs["prompt_text"])
            turns = kwargs["conversation_turns"]
            self.assertEqual(
                [turn["role"] for turn in turns],
                ["user", "model", "user", "model", "user"],
            )
            self.assertEqual(turns[-1]["request_id"], current_id)
            self.assertIn("fresh set", turns[-1]["text"])
            return {
                "status": "ok",
                "tldr": "Sarah needs a new reply.",
                "suggestions": ["New one", "New two", "New three"],
                "suggestion_details": [
                    {"text": "New one", "tags": ["Reply"]},
                    {"text": "New two", "tags": ["Ask"]},
                    {"text": "New three", "tags": ["Next"]},
                ],
                "duration_ms": 77,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        telemetry_store = mock.Mock()

        with mock.patch("server.main._thread_cache", return_value=thread_cache), mock.patch(
            "server.main._telemetry_store",
            return_value=telemetry_store,
        ):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": current_id,
                            "input_mode": "screenshot",
                            "reroll_context": {
                                "schema_version": 1,
                                "source_request_id": source_id,
                            },
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertIn("reroll_thread_cache_hit", response.json()["warnings"])
        telemetry_store.get_previous_response.assert_not_called()
        _, stored_root, stored_thread = thread_cache.set_thread_calls[-1]
        self.assertEqual(stored_root, root_id)
        self.assertEqual(stored_thread["latest_request_id"], current_id)
        self.assertEqual(
            [turn["role"] for turn in stored_thread["turns"]],
            ["user", "model", "user", "model", "user", "model"],
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_reroll_context_strips_extra_keys(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        source_id = "22222222-2222-4222-8222-222222222222"

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            self.assertNotIn("malicious previous text", kwargs["prompt_text"])
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
        telemetry_store.get_previous_response.return_value = None

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-reroll-extra",
                            "input_mode": "screenshot",
                            "reroll_context": {
                                "schema_version": 1,
                                "source_request_id": source_id,
                                "previous_suggestions": ["malicious previous text"],
                                "unexpected": {"nested": "payload"},
                            },
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertIn("reroll_context_missing_previous", response.json()["warnings"])
        recorded = telemetry_store.record_request.call_args.args[0]
        self.assertEqual(
            recorded["reroll_context"],
            {"schema_version": 1, "source_request_id": source_id},
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_reroll_missing_source_degrades_gracefully(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()
        source_id = "33333333-3333-4333-8333-333333333333"

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            prompt_text = kwargs["prompt_text"]
            self.assertNotIn("Reroll instructions:", prompt_text)
            self.assertNotIn("Please send the doc.", prompt_text)
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
        telemetry_store.get_previous_response.return_value = None

        with mock.patch("server.main._telemetry_store", return_value=telemetry_store):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-reroll-missing",
                            "input_mode": "screenshot",
                            "reroll_context": {
                                "schema_version": 1,
                                "source_request_id": source_id,
                            },
                        }
                    )
                },
                files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
            )

        self.assertEqual(response.status_code, 200)
        self.assertIn("reroll_context_missing_previous", response.json()["warnings"])
        telemetry_store.get_previous_response.assert_called_once()
        lookup_args = telemetry_store.get_previous_response.call_args.args
        self.assertEqual(lookup_args[0], source_id)
        self.assertIsInstance(lookup_args[1], str)
        self.assertTrue(lookup_args[1])

    def test_v1_tldr_reroll_rejects_malformed_source_request_id(self) -> None:
        response = self.client.post(
            "/v1/tldr",
            headers={"Authorization": "Bearer dev-token"},
            data={
                "request": json.dumps(
                    {
                        "request_id": "req-reroll-bad",
                        "input_mode": "screenshot",
                        "reroll_context": {
                            "schema_version": 1,
                            "source_request_id": "not-a-uuid",
                        },
                    }
                )
            },
            files={"screenshot": ("screen.png", b"png-bytes", "image/png")},
        )

        self.assertEqual(response.status_code, 422)

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

    def test_gemini_config_passthrough_media_resolution_for_gemini_35_flash(self) -> None:
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
                    "model": "gemini-3.5-flash",
                    "temperature": 0.2,
                    "max_output_tokens": 512,
                    "media_resolution": "MEDIA_RESOLUTION_LOW",
                },
                "PROMPT",
            )

        self.assertEqual(captured_config["media_resolution"], "MEDIA_RESOLUTION_LOW")

    def test_response_schema_contract_is_v2_suggestion_objects_with_tags(self) -> None:
        schema = gemini.response_schema_contract()

        self.assertEqual(
            schema["required"], ["schema_version", "tldr", "suggestions"]
        )
        self.assertEqual(
            schema["property_ordering"],
            ["schema_version", "tldr", "suggestions"],
        )
        self.assertEqual(schema["properties"]["schema_version"]["type"], "integer")
        self.assertNotIn("scratch", schema["properties"])
        self.assertNotIn("max_length", schema["properties"]["tldr"])
        suggestions = schema["properties"]["suggestions"]
        self.assertEqual(suggestions["min_items"], 3)
        self.assertEqual(suggestions["max_items"], 3)
        item = suggestions["items"]
        self.assertEqual(item["required"], ["text", "tags"])
        self.assertEqual(item["properties"]["text"]["type"], "string")
        self.assertEqual(item["properties"]["tags"]["min_items"], 1)
        self.assertEqual(item["properties"]["tags"]["max_items"], 2)

    def test_gemini_normalizes_v2_suggestions_with_tags(self) -> None:
        tldr, suggestions, details = gemini._normalize_payload(
            {
                "schema_version": 2,
                "tldr": "Sarah needs a reply.",
                "suggestions": [
                    {"text": "One", "tags": ["Reply", "Direct"]},
                    {"text": "Two", "tags": ["Ask"]},
                    {"text": "Three", "tags": ["Next step"]},
                ],
            }
        )

        self.assertEqual(tldr, "Sarah needs a reply.")
        self.assertEqual(suggestions, ["One", "Two", "Three"])
        self.assertEqual(
            details,
            [
                {"text": "One", "tags": ["Reply", "Direct"]},
                {"text": "Two", "tags": ["Ask"]},
                {"text": "Three", "tags": ["Next step"]},
            ],
        )

    def test_gemini_fills_blank_v2_tags(self) -> None:
        _, _, details = gemini._normalize_payload(
            {
                "schema_version": 2,
                "tldr": "Sarah needs a reply.",
                "suggestions": [
                    {"text": "Can you check the logs?", "tags": []},
                    {"text": "Wait, this still seems wrong.", "tags": []},
                    {"text": "Update the overlay height.", "tags": []},
                ],
            }
        )

        self.assertEqual(
            [item["tags"] for item in details],
            [["Ask"], ["Pushback"], ["Next step"]],
        )

    def test_gemini_conversation_contents_render_alternating_roles(self) -> None:
        class FakePart:
            @staticmethod
            def from_bytes(*, data: bytes, mime_type: str) -> dict[str, Any]:
                return {"bytes": data, "mime_type": mime_type}

            @staticmethod
            def from_text(*, text: str) -> dict[str, Any]:
                return {"text": text}

        class FakeContent:
            def __init__(self, *, role: str, parts: list[Any]) -> None:
                self.role = role
                self.parts = parts

        class FakeTypes:
            Part = FakePart
            Content = FakeContent

        contents = gemini._conversation_contents(
            FakeTypes,
            [(b"png-bytes", "image/png")],
            None,
            "image/png",
            [
                {"role": "user", "kind": "capture", "request_id": "root"},
                {
                    "role": "model",
                    "tldr": "Sarah needs a reply.",
                    "suggestion_details": [
                        {"text": "One", "tags": ["Reply"]},
                        {"text": "Two", "tags": ["Ask"]},
                        {"text": "Three", "tags": ["Next"]},
                    ],
                },
                {"role": "user", "kind": "reroll", "text": "stale prompt text from older deploy"},
            ],
        )

        self.assertEqual([item.role for item in contents], ["user", "model", "user"])
        self.assertEqual(contents[0].parts[0], {"bytes": b"png-bytes", "mime_type": "image/png"})
        self.assertEqual(contents[0].parts[1], {"text": gemini.MODEL_CONTENT_TEXT})
        self.assertIn("suggestions", contents[1].parts[0]["text"])
        self.assertEqual(contents[2].parts, [{"text": gemini.REROLL_CONTENT_TEXT}])

    def test_gemini_conversation_contents_initial_gen_returns_single_user_content(self) -> None:
        class FakePart:
            @staticmethod
            def from_bytes(*, data: bytes, mime_type: str) -> dict[str, Any]:
                return {"bytes": data, "mime_type": mime_type}

            @staticmethod
            def from_text(*, text: str) -> dict[str, Any]:
                return {"text": text}

        class FakeContent:
            def __init__(self, *, role: str, parts: list[Any]) -> None:
                self.role = role
                self.parts = parts

        class FakeTypes:
            Part = FakePart
            Content = FakeContent

        contents = gemini._conversation_contents(
            FakeTypes,
            [(b"png-bytes", "image/png")],
            None,
            "image/png",
            None,
        )

        self.assertEqual(len(contents), 1)
        self.assertEqual(contents[0].role, "user")
        self.assertEqual(contents[0].parts[0], {"bytes": b"png-bytes", "mime_type": "image/png"})
        self.assertEqual(contents[0].parts[1], {"text": gemini.MODEL_CONTENT_TEXT})

    def test_gemini_conversation_contents_reroll_default_text_is_reroll_content_text(self) -> None:
        class FakePart:
            @staticmethod
            def from_bytes(*, data: bytes, mime_type: str) -> dict[str, Any]:
                return {"bytes": data, "mime_type": mime_type}

            @staticmethod
            def from_text(*, text: str) -> dict[str, Any]:
                return {"text": text}

        class FakeContent:
            def __init__(self, *, role: str, parts: list[Any]) -> None:
                self.role = role
                self.parts = parts

        class FakeTypes:
            Part = FakePart
            Content = FakeContent

        contents = gemini._conversation_contents(
            FakeTypes,
            [(b"png-bytes", "image/png")],
            None,
            "image/png",
            [
                {"role": "user", "kind": "capture", "request_id": "root"},
                {
                    "role": "model",
                    "tldr": "Sarah needs a reply.",
                    "suggestion_details": [{"text": "One", "tags": ["Reply"]}],
                },
                {"role": "user", "kind": "reroll"},
            ],
        )

        self.assertEqual(contents[-1].role, "user")
        self.assertEqual(contents[-1].parts, [{"text": gemini.REROLL_CONTENT_TEXT}])
        self.assertNotEqual(contents[-1].parts, [{"text": gemini.MODEL_CONTENT_TEXT}])

    def test_gemini_conversation_contents_reroll_uses_follow_up_instruction(self) -> None:
        class FakePart:
            @staticmethod
            def from_bytes(*, data: bytes, mime_type: str) -> dict[str, Any]:
                return {"bytes": data, "mime_type": mime_type}

            @staticmethod
            def from_text(*, text: str) -> dict[str, Any]:
                return {"text": text}

        class FakeContent:
            def __init__(self, *, role: str, parts: list[Any]) -> None:
                self.role = role
                self.parts = parts

        class FakeTypes:
            Part = FakePart
            Content = FakeContent

        contents = gemini._conversation_contents(
            FakeTypes,
            [(b"png-bytes", "image/png")],
            None,
            "image/png",
            [
                {"role": "user", "kind": "capture", "request_id": "root"},
                {
                    "role": "model",
                    "tldr": "Sarah needs a reply.",
                    "suggestion_details": [{"text": "One", "tags": ["Reply"]}],
                },
                {
                    "role": "user",
                    "kind": "reroll",
                    "text": "stale prompt text from older deploy",
                    "follow_up_instruction": "make these more direct",
                },
            ],
        )

        self.assertEqual(
            contents[-1].parts,
            [{"text": gemini.reroll_content_text("make these more direct")}],
        )
        self.assertNotIn("stale prompt text", contents[-1].parts[0]["text"])

    def test_gemini_conversation_contents_multi_reroll_keeps_reroll_as_final_turn(self) -> None:
        class FakePart:
            @staticmethod
            def from_bytes(*, data: bytes, mime_type: str) -> dict[str, Any]:
                return {"bytes": data, "mime_type": mime_type}

            @staticmethod
            def from_text(*, text: str) -> dict[str, Any]:
                return {"text": text}

        class FakeContent:
            def __init__(self, *, role: str, parts: list[Any]) -> None:
                self.role = role
                self.parts = parts

        class FakeTypes:
            Part = FakePart
            Content = FakeContent

        contents = gemini._conversation_contents(
            FakeTypes,
            [(b"png-bytes", "image/png")],
            None,
            "image/png",
            [
                {"role": "user", "kind": "capture", "request_id": "root"},
                {
                    "role": "model",
                    "tldr": "Sarah needs a reply.",
                    "suggestion_details": [{"text": "One", "tags": ["Reply"]}],
                },
                {"role": "user", "kind": "reroll", "text": "stale prompt text from older deploy"},
                {
                    "role": "model",
                    "tldr": "Sarah needs a reply.",
                    "suggestion_details": [{"text": "Two", "tags": ["Reply"]}],
                },
                {"role": "user", "kind": "reroll"},
            ],
        )

        self.assertEqual([c.role for c in contents], ["user", "model", "user", "model", "user"])
        image_bearing = [
            c for c in contents
            if c.role == "user" and any(isinstance(p, dict) and "bytes" in p for p in c.parts)
        ]
        self.assertEqual(len(image_bearing), 1)
        self.assertEqual(contents[-1].parts, [{"text": gemini.REROLL_CONTENT_TEXT}])
        self.assertEqual(contents[2].parts, [{"text": gemini.REROLL_CONTENT_TEXT}])

    def test_gemini_prompt_with_context_single_preference_example_no_verb_menu(self) -> None:
        prompt = gemini.prompt_with_context(
            "Base.",
            {
                "preference_examples": [
                    {
                        "screen_takeaway": "Agent offered low-risk plan.",
                        "rejected_suggestions": ["Sounds good.", "I agree."],
                        "user_typed": "please run the tests first",
                    }
                ],
            },
        )

        self.assertIn("please run the tests first", prompt)
        self.assertNotIn("Preference lesson:", prompt)
        self.assertNotIn("evidence requests", prompt)
        self.assertNotIn("premise checks", prompt)
        self.assertNotIn("clarifying questions", prompt)

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
                            "preferences": {"model": "gemini-3.1-flash-lite-preview"},
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
            # recent_surface_history is intentionally suppressed in the rendered
            # prompt while the surface-history architecture is iterated on; see
            # server/gemini.py:SURFACE_HISTORY_ENABLED. Storage still records it.
            self.assertNotIn("Sarah asked for a review", prompt_text)
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

    def test_selected_settings_ignores_temperature_and_max_tokens(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings(
            {
                "preferences": {
                    "temperature": 0.3,
                    "max_output_tokens": 640,
                }
            },
            warnings,
        )
        self.assertEqual(settings["temperature"], gemini.DEFAULT_SETTINGS["temperature"])
        self.assertEqual(
            settings["max_output_tokens"], gemini.DEFAULT_SETTINGS["max_output_tokens"]
        )
        self.assertNotIn("thinking_level", settings)
        self.assertEqual(warnings, [])

    def test_selected_settings_honors_client_thinking_level(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings(
            {"preferences": {"thinking_level": "high"}},
            warnings,
        )
        self.assertEqual(settings["thinking_level"], "high")
        self.assertEqual(warnings, [])

    def test_selected_settings_rejects_bogus_thinking_level(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings(
            {"preferences": {"thinking_level": "ultra"}},
            warnings,
        )
        self.assertNotIn("thinking_level", settings)
        self.assertIn("requested_thinking_level_disallowed", warnings)

    def test_selected_settings_defaults_when_preferences_absent(self) -> None:
        warnings: list[str] = []
        settings = _selected_settings({}, warnings)
        self.assertEqual(settings["temperature"], gemini.DEFAULT_SETTINGS["temperature"])
        self.assertEqual(
            settings["max_output_tokens"], gemini.DEFAULT_SETTINGS["max_output_tokens"]
        )
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

    def test_build_selection_block_emits_text_when_retention_allowed(self) -> None:
        block = _build_selection_block(
            {
                "source": "ax",
                "text": "the highlighted text",
                "char_count": 20,
                "truncated": False,
            }
        )
        self.assertIn('source="ax"', block)
        self.assertIn('char_count="20"', block)
        self.assertIn('truncated="false"', block)
        self.assertIn("the highlighted text", block)
        self.assertIn("<selection ", block)
        self.assertIn("</selection>", block)
        self.assertNotIn("text_redacted", block)

    def test_build_selection_block_emits_self_closing_when_redacted(self) -> None:
        block = _build_selection_block(
            {
                "source": "synthetic_copy",
                "text_redacted": True,
                "char_count": 42,
                "truncated": True,
            }
        )
        self.assertIn('source="synthetic_copy"', block)
        self.assertIn('text_redacted="true"', block)
        self.assertIn('truncated="true"', block)
        self.assertTrue(block.rstrip().endswith("/>"))
        self.assertNotIn("</selection>", block)

    def test_privacy_safe_envelope_redacts_selection_text_without_retention(self) -> None:
        envelope = {
            "consent": {"allow_content_retention": False},
            "selection": {
                "source": "ax",
                "text": "highlighted secret",
                "char_count": 18,
                "truncated": False,
            },
            "selections": [
                {
                    "source": "ax",
                    "text": "highlighted secret",
                    "char_count": 18,
                    "truncated": False,
                }
            ],
        }
        sanitized = _privacy_safe_envelope(envelope)
        self.assertNotIn("text", sanitized["selection"])
        self.assertTrue(sanitized["selection"]["text_redacted"])
        self.assertEqual(sanitized["selection"]["char_count"], 18)
        # The plural per-frame array is also redacted.
        self.assertNotIn("text", sanitized["selections"][0])
        self.assertTrue(sanitized["selections"][0]["text_redacted"])
        # The live envelope (what the model sees) is unchanged.
        self.assertEqual(envelope["selection"]["text"], "highlighted secret")

    def test_privacy_safe_envelope_keeps_selection_text_with_retention(self) -> None:
        envelope = {
            "consent": {"allow_content_retention": True},
            "selection": {
                "source": "ax",
                "text": "highlighted",
                "char_count": 11,
                "truncated": False,
            },
        }
        sanitized = _privacy_safe_envelope(envelope)
        self.assertEqual(sanitized["selection"]["text"], "highlighted")
        self.assertNotIn("text_redacted", sanitized["selection"])

    def test_build_selection_block_returns_empty_for_invalid_inputs(self) -> None:
        self.assertEqual(_build_selection_block(None), "")
        self.assertEqual(_build_selection_block({}), "")
        # Empty / whitespace-only text without redaction flag drops to empty.
        self.assertEqual(
            _build_selection_block({"source": "ax", "text": "   "}),
            "",
        )

    @mock.patch("server.main.gemini.generate_tldr_and_suggestions")
    @mock.patch("server.main.gemini.create_client")
    def test_v1_tldr_injects_selection_block_into_prompt(
        self,
        create_client: mock.Mock,
        generate: mock.Mock,
    ) -> None:
        create_client.return_value = object()

        def fake_generate(*_: Any, **kwargs: Any) -> dict[str, Any]:
            prompt_text = kwargs["prompt_text"]
            self.assertIn("<selection ", prompt_text)
            self.assertIn("the user's highlighted paragraph", prompt_text)
            self.assertIn('source="ax"', prompt_text)
            return {
                "status": "ok",
                "tldr": "Selection-aware reply.",
                "suggestions": ["One", "Two", "Three"],
                "duration_ms": 12,
                "usage": None,
                "model": "gemini-3.1-flash-lite-preview",
            }

        generate.side_effect = fake_generate
        with mock.patch("server.main._telemetry_store", return_value=mock.Mock()):
            response = self.client.post(
                "/v1/tldr",
                headers={"Authorization": "Bearer dev-token"},
                data={
                    "request": json.dumps(
                        {
                            "request_id": "req-selection",
                            "input_mode": "screenshot",
                            "preferences": {"model": "gemini-3.1-flash-lite-preview"},
                            "selection": {
                                "source": "ax",
                                "text": "the user's highlighted paragraph",
                                "char_count": 31,
                                "truncated": False,
                            },
                            "consent": {
                                "allow_event_logging": True,
                                "allow_content_retention": True,
                            },
                        }
                    )
                },
                files={"screenshot": ("s.png", b"png-bytes", "image/png")},
            )
        self.assertEqual(response.status_code, 200)


if __name__ == "__main__":
    unittest.main()
