"""Tests for the v2 extractor/paste runtime split (and v1 fallback)."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

import run_once  # noqa: E402
from run_once import (  # noqa: E402
    RUNTIME_ROLE_EXTRACTOR,
    RUNTIME_ROLE_PASTE,
    _full_target_image_role,
    _prepared_source_matches,
    _resolve_runtime_section,
    _role_supports_vision,
    _runtime_role_section,
    _should_use_full_target_image,
)
from source_ocr import NATIVE_SOURCE_OCR_REQUEST_MODE, NATIVE_SOURCE_PACKET_KIND, SOURCE_OCR_PARAMETERS  # noqa: E402
from tests.fixture_helpers import load_fixture  # noqa: E402


def _gemini_preset() -> dict:
    return {
        "id": "gemini-direct",
        "name": "Gemini Direct",
        "provider": "gemini",
        "api_key_env": "GEMINI_API_KEY",
        "api_style": "native",
        "base_url": None,
        "url_substitutions": [],
        "default_headers": {},
        "extra_headers": {},
        "default_model": "gemini-3.1-flash-lite-preview",
        "supports_vision": True,
        "suggested_models": [],
    }


def _groq_preset() -> dict:
    return {
        "id": "groq-chat",
        "name": "Groq Chat",
        "provider": "openai_sdk",
        "api_key_env": "GROQ_API_KEY",
        "api_style": "chat_completions",
        "base_url": "https://api.groq.com/openai/v1",
        "url_substitutions": [],
        "default_headers": {},
        "extra_headers": {},
        "default_model": "meta-llama/llama-4-scout-17b-16e-instruct",
        "supports_vision": True,
        "suggested_models": [],
        "model_overrides": {
            "llama-3.3-70b-versatile": {
                "supports_vision": False,
            },
        },
    }


class V2SelectionTests(unittest.TestCase):
    def test_v2_selection_produces_two_distinct_resolved_settings(self) -> None:
        runtime = {
            "version": 2,
            "request_mode": "source_packet_target_ocr_packet",
            "extractor": {
                "model": "gemini-3.1-flash-lite-preview",
                "provider_preset": _gemini_preset(),
            },
            "paste": {
                "model": "llama-3.3-70b-versatile",
                "provider_preset": _groq_preset(),
            },
        }
        base = {"temperature": 0.0}

        ex = _resolve_runtime_section(base, runtime, RUNTIME_ROLE_EXTRACTOR)
        pa = _resolve_runtime_section(base, runtime, RUNTIME_ROLE_PASTE)

        self.assertEqual(ex["model"], "gemini-3.1-flash-lite-preview")
        self.assertEqual(ex["provider"], "gemini")
        self.assertEqual(pa["model"], "llama-3.3-70b-versatile")
        self.assertEqual(pa["provider"], "openai_sdk")
        self.assertNotEqual(ex["model"], pa["model"])
        self.assertNotEqual(ex["provider_options"]["base_url"], pa["provider_options"]["base_url"])

    def test_v1_selection_falls_back_to_shared_settings(self) -> None:
        runtime = {
            "request_mode": "source_packet_target_ocr_packet",
            "model": "gemini-3.1-flash-lite-preview",
            "provider_preset": _gemini_preset(),
        }
        base = {"temperature": 0.0}

        ex = _resolve_runtime_section(base, runtime, RUNTIME_ROLE_EXTRACTOR)
        pa = _resolve_runtime_section(base, runtime, RUNTIME_ROLE_PASTE)

        self.assertEqual(ex["model"], pa["model"])
        self.assertEqual(ex["provider"], pa["provider"])
        self.assertEqual(ex["provider_options"], pa["provider_options"])

    def test_runtime_role_section_returns_v1_legacy_for_both_roles(self) -> None:
        runtime = {
            "model": "shared-model",
            "provider_preset": _gemini_preset(),
        }
        ex = _runtime_role_section(runtime, RUNTIME_ROLE_EXTRACTOR)
        pa = _runtime_role_section(runtime, RUNTIME_ROLE_PASTE)
        self.assertEqual(ex["model"], "shared-model")
        self.assertEqual(pa["model"], "shared-model")
        self.assertEqual(ex["provider_preset"]["id"], "gemini-direct")
        self.assertEqual(pa["provider_preset"]["id"], "gemini-direct")

    def test_model_override_marks_paste_runtime_as_text_only(self) -> None:
        runtime = {
            "version": 2,
            "extractor": {
                "model": "gemini-3.1-flash-lite-preview",
                "provider_preset": _gemini_preset(),
            },
            "paste": {
                "model": "llama-3.3-70b-versatile",
                "provider_preset": _groq_preset(),
            },
        }

        self.assertTrue(_role_supports_vision(runtime, RUNTIME_ROLE_EXTRACTOR))
        self.assertFalse(_role_supports_vision(runtime, RUNTIME_ROLE_PASTE))
        self.assertEqual(_full_target_image_role(runtime), RUNTIME_ROLE_EXTRACTOR)

    def test_full_target_image_prefers_paste_when_it_supports_vision(self) -> None:
        runtime = {
            "version": 2,
            "extractor": {
                "model": "gemini-3.1-flash-lite-preview",
                "provider_preset": _gemini_preset(),
            },
            "paste": {
                "model": "meta-llama/llama-4-scout-17b-16e-instruct",
                "provider_preset": _groq_preset(),
            },
        }

        self.assertTrue(_role_supports_vision(runtime, RUNTIME_ROLE_PASTE))
        self.assertEqual(_full_target_image_role(runtime), RUNTIME_ROLE_PASTE)

    def test_target_ocr_packet_uses_full_image_when_packet_needs_image(self) -> None:
        target_packet = {
            "completeness": "needs_target_image",
            "fallback_reasons": ["google_docs_degenerate_focus_rect"],
        }

        self.assertTrue(
            _should_use_full_target_image(
                "source_packet_target_ocr_packet",
                target_packet,
            )
        )

    def test_target_ocr_packet_stays_text_only_when_packet_is_sufficient(self) -> None:
        target_packet = {
            "completeness": "sufficient",
            "fallback_reasons": [],
        }

        self.assertFalse(
            _should_use_full_target_image(
                "source_packet_target_ocr_packet",
                target_packet,
            )
        )

    def test_native_source_ocr_mode_uses_same_target_packet_fallback_policy(self) -> None:
        target_packet = {
            "completeness": "needs_target_image",
            "fallback_reasons": ["no_local_target_text"],
        }

        self.assertTrue(
            _should_use_full_target_image(
                NATIVE_SOURCE_OCR_REQUEST_MODE,
                target_packet,
            )
        )

    def test_manual_fixture_routes_image_fallback_to_extractor(self) -> None:
        fixture = load_fixture("manual_google_docs_target_20260425_205140.json")
        runtime = fixture["runtime_selection"]

        self.assertFalse(_role_supports_vision(runtime, RUNTIME_ROLE_PASTE))
        self.assertTrue(_role_supports_vision(runtime, RUNTIME_ROLE_EXTRACTOR))
        self.assertEqual(
            _full_target_image_role(runtime),
            fixture["expected"]["full_target_image_role"],
        )
        self.assertTrue(
            _should_use_full_target_image(
                runtime["request_mode"],
                fixture["target_packet_payload"],
            )
        )


class PreparedSourceMatchesUsesExtractor(unittest.TestCase):
    def test_match_uses_extractor_section_under_v2(self) -> None:
        runtime = {
            "version": 2,
            "request_mode": "source_packet_target_ocr_packet",
            "extractor": {
                "model": "gemini-3.1-flash-lite-preview",
                "provider_preset": _gemini_preset(),
            },
            "paste": {
                "model": "llama-3.3-70b-versatile",
                "provider_preset": _groq_preset(),
            },
        }
        prepared = {
            "status": "ok",
            "source_packet_kind": "model_extracted_text",
            "runtime_signature": {
                "request_mode": "source_packet_target_ocr_packet",
                "provider_preset_id": "gemini-direct",
                "model": "gemini-3.1-flash-lite-preview",
                "source_extract_prompt": "/tmp/p.txt",
            },
        }
        self.assertTrue(
            _prepared_source_matches(prepared, runtime, Path("/tmp/p.txt"))
        )

    def test_match_rejects_when_paste_section_was_used_to_sign(self) -> None:
        runtime = {
            "version": 2,
            "request_mode": "source_packet_target_ocr_packet",
            "extractor": {
                "model": "gemini-3.1-flash-lite-preview",
                "provider_preset": _gemini_preset(),
            },
            "paste": {
                "model": "llama-3.3-70b-versatile",
                "provider_preset": _groq_preset(),
            },
        }
        # Signature claims it was extracted by the paste model — reject.
        prepared = {
            "status": "ok",
            "source_packet_kind": "model_extracted_text",
            "runtime_signature": {
                "request_mode": "source_packet_target_ocr_packet",
                "provider_preset_id": "groq-chat",
                "model": "llama-3.3-70b-versatile",
                "source_extract_prompt": "/tmp/p.txt",
            },
        }
        self.assertFalse(
            _prepared_source_matches(prepared, runtime, Path("/tmp/p.txt"))
        )

    def test_match_uses_v1_top_level_under_legacy_runtime(self) -> None:
        runtime = {
            "request_mode": "source_packet_target_ocr_packet",
            "model": "gemini-3.1-flash-lite-preview",
            "provider_preset": _gemini_preset(),
        }
        prepared = {
            "status": "ok",
            "source_packet_kind": "model_extracted_text",
            "runtime_signature": {
                "request_mode": "source_packet_target_ocr_packet",
                "provider_preset_id": "gemini-direct",
                "model": "gemini-3.1-flash-lite-preview",
                "source_extract_prompt": "/tmp/p.txt",
            },
        }
        self.assertTrue(
            _prepared_source_matches(prepared, runtime, Path("/tmp/p.txt"))
        )


class FullTargetImageFallbackRoutingTests(unittest.TestCase):
    def test_native_source_ocr_mode_uses_target_packet_prompt_and_paste_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_path = root / "source.png"
            target_path = root / "target.png"
            target_meta_path = root / "target_metadata.json"
            geometry_path = root / "geometry.json"
            runtime_path = root / "runtime.json"
            prepared_path = root / "prepared_source.json"
            target_ocr_prompt_path = root / "target_ocr_prompt.txt"
            out_dir = root / "out"

            source_path.write_bytes(b"not actually decoded in this test")
            target_path.write_bytes(b"not actually decoded in this test")
            target_meta_path.write_text(
                json.dumps({"status": "ok", "focused_role": "AXTextArea"}),
                encoding="utf-8",
            )
            geometry_path.write_text("{}", encoding="utf-8")
            target_ocr_prompt_path.write_text("target ocr", encoding="utf-8")

            runtime_selection = {
                "version": 2,
                "request_mode": NATIVE_SOURCE_OCR_REQUEST_MODE,
                "extractor": {
                    "model": "gemini-3.1-flash-lite-preview",
                    "provider_preset": _gemini_preset(),
                },
                "paste": {
                    "model": "llama-3.3-70b-versatile",
                    "provider_preset": _groq_preset(),
                },
                "paths": {
                    "target_ocr_prompt": str(target_ocr_prompt_path),
                },
            }
            runtime_path.write_text(json.dumps(runtime_selection), encoding="utf-8")
            prepared_source = {
                "status": "ok",
                "source_packet_kind": NATIVE_SOURCE_PACKET_KIND,
                "packet_text": "Sarah Chen\nsarah@acmehq.com",
                "build_log": {},
                "runtime_signature": {
                    "request_mode": NATIVE_SOURCE_OCR_REQUEST_MODE,
                    "source_packet_kind": NATIVE_SOURCE_PACKET_KIND,
                    "ocr_parameters": dict(SOURCE_OCR_PARAMETERS),
                },
            }
            prepared_path.write_text(json.dumps(prepared_source), encoding="utf-8")
            target_packet = {
                "status": "ok",
                "packet_text": "FOCUSED_FIELD_LABEL: Email",
                "packet_chars": 26,
                "completeness": "sufficient",
                "fallback_reasons": [],
                "focused_label_hint": "Email",
                "build_log": {"ocr_ms": 3.0},
            }
            ocr_packet_call: dict[str, object] = {}

            def fake_ocr_packet(**kwargs: object) -> dict[str, object]:
                ocr_packet_call.update(kwargs)
                return {
                    "assembled_request_text": "assembled target packet request",
                    "output_text": "sarah@acmehq.com",
                    "run_log": {
                        "status": "ok",
                        "request": {"mode": "source_packet_target_ocr_packet"},
                        "response": {},
                        "timings": {},
                    },
                }

            def fake_runtime(settings: dict[str, object]) -> dict[str, object]:
                return {"provider": settings.get("provider"), "api_key": "fake"}

            with (
                mock.patch("run_once.load_runtime_env", return_value=[]),
                mock.patch("run_once.resolve_runtime_settings", side_effect=fake_runtime),
                mock.patch("run_once.build_target_ocr_packet", return_value=target_packet),
                mock.patch("run_once.run_source_packet_target_ocr_packet", side_effect=fake_ocr_packet),
                mock.patch("run_once.run_source_packet_target_full_image") as full_image,
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    status = run_once.main(
                        [
                            "--source",
                            str(source_path),
                            "--target",
                            str(target_path),
                            "--target-meta",
                            str(target_meta_path),
                            "--geometry",
                            str(geometry_path),
                            "--runtime",
                            str(runtime_path),
                            "--prepared-source",
                            str(prepared_path),
                            "--out-dir",
                            str(out_dir),
                            "--bundle-id",
                            "native-case",
                            "--silent-stderr",
                        ]
                    )

            self.assertEqual(status, 0)
            full_image.assert_not_called()
            self.assertEqual(ocr_packet_call["settings"]["provider"], "openai_sdk")
            self.assertEqual(ocr_packet_call["runtime"]["provider"], "openai_sdk")
            self.assertEqual(ocr_packet_call["source_packet_kind"], NATIVE_SOURCE_PACKET_KIND)

            bundle_dir = out_dir / "native-case"
            self.assertTrue((bundle_dir / "target_ocr_packet.txt").exists())
            self.assertFalse((bundle_dir / "target_ocr_text.txt").exists())
            run_log = json.loads((bundle_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(run_log["target_context"]["mode"], "target_ocr_packet")
            self.assertEqual(run_log["source_packet"]["kind"], NATIVE_SOURCE_PACKET_KIND)

    def test_ocr_packet_needs_image_routes_screenshot_to_extractor(self) -> None:
        fixture = load_fixture("manual_google_docs_target_20260425_205140.json")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_path = root / "source.png"
            target_path = root / "target.png"
            target_meta_path = root / "target_metadata.json"
            geometry_path = root / "geometry.json"
            runtime_path = root / "runtime.json"
            prepared_path = root / "prepared_source.json"
            source_prompt_path = root / "source_extract_prompt.txt"
            target_image_prompt_path = root / "target_image_prompt.txt"
            target_ocr_prompt_path = root / "target_ocr_prompt.txt"
            out_dir = root / "out"

            source_path.write_bytes(b"not actually decoded in this test")
            target_path.write_bytes(b"not actually decoded in this test")
            source_prompt_path.write_text("extract", encoding="utf-8")
            target_image_prompt_path.write_text("target image", encoding="utf-8")
            target_ocr_prompt_path.write_text("target ocr", encoding="utf-8")
            target_meta_path.write_text("{}", encoding="utf-8")
            geometry_path.write_text("{}", encoding="utf-8")

            runtime_selection = dict(fixture["runtime_selection"])
            runtime_selection["paths"] = {
                "source_extract_prompt": str(source_prompt_path),
                "source_packet_target_prompt": str(target_image_prompt_path),
                "target_ocr_prompt": str(target_ocr_prompt_path),
            }
            runtime_path.write_text(
                json.dumps(runtime_selection),
                encoding="utf-8",
            )
            prepared_source = {
                "status": "ok",
                "source_packet_kind": "model_extracted_text",
                "packet_text": "Source packet text.",
                "build_log": {},
                "runtime_signature": {
                    "request_mode": runtime_selection["request_mode"],
                    "provider_preset_id": "gemini-direct",
                    "model": "gemini-3.1-flash-lite-preview",
                    "source_extract_prompt": str(source_prompt_path),
                },
            }
            prepared_path.write_text(json.dumps(prepared_source), encoding="utf-8")
            target_packet = dict(fixture["target_packet_payload"])
            target_packet["build_log"] = {}
            full_image_call: dict[str, object] = {}

            def fake_full_image(**kwargs: object) -> dict[str, object]:
                full_image_call.update(kwargs)
                return {
                    "assembled_request_text": "assembled",
                    "output_text": "filled",
                    "run_log": {
                        "status": "ok",
                        "request": {"mode": "source_packet_target_full_image"},
                        "response": {},
                        "timings": {},
                    },
                }

            def fake_runtime(settings: dict[str, object]) -> dict[str, object]:
                return {"provider": settings.get("provider"), "api_key": "fake"}

            with (
                mock.patch("run_once.load_runtime_env", return_value=[]),
                mock.patch("run_once.resolve_runtime_settings", side_effect=fake_runtime),
                mock.patch("run_once.build_target_ocr_packet", return_value=target_packet),
                mock.patch("run_once.run_source_packet_target_full_image", side_effect=fake_full_image),
                mock.patch("run_once.run_source_packet_target_ocr_packet") as ocr_packet,
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    status = run_once.main(
                        [
                            "--source",
                            str(source_path),
                            "--target",
                            str(target_path),
                            "--target-meta",
                            str(target_meta_path),
                            "--geometry",
                            str(geometry_path),
                            "--runtime",
                            str(runtime_path),
                            "--prepared-source",
                            str(prepared_path),
                            "--out-dir",
                            str(out_dir),
                            "--bundle-id",
                            "case",
                            "--silent-stderr",
                        ]
                    )

            self.assertEqual(status, 0)
            ocr_packet.assert_not_called()
            self.assertEqual(full_image_call["settings"]["provider"], "gemini")
            self.assertEqual(full_image_call["runtime"]["provider"], "gemini")

            run_log = json.loads((out_dir / "case" / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(
                run_log["target_context"]["full_target_image_role"],
                RUNTIME_ROLE_EXTRACTOR,
            )
            self.assertIn("fell_back_to_full_target_image", run_log["warnings"])
            self.assertIn("full_target_image_used_extractor_runtime", run_log["warnings"])


if __name__ == "__main__":
    unittest.main()
