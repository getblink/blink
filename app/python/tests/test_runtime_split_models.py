"""Tests for the v2 extractor/paste runtime split (and v1 fallback)."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

APP_PYTHON_DIR = Path(__file__).resolve().parent.parent
if str(APP_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(APP_PYTHON_DIR))

from run_once import (  # noqa: E402
    RUNTIME_ROLE_EXTRACTOR,
    RUNTIME_ROLE_PASTE,
    _prepared_source_matches,
    _resolve_runtime_section,
    _runtime_role_section,
)


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
        "suggested_models": [],
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


if __name__ == "__main__":
    unittest.main()
