from __future__ import annotations

from pathlib import Path
from typing import Any

from google import genai
from google.genai import types

from gemini_runner import generate_completion as gemini_generate_completion


def _get_client(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    runtime: dict[str, Any],
) -> genai.Client:
    timeout_ms = int(float(settings.get("timeout_seconds", 120)) * 1000)
    cache_key = ("gemini", runtime["api_key"], timeout_ms)
    client = client_cache.get(cache_key)
    if client is None:
        client = genai.Client(
            api_key=runtime["api_key"],
            http_options=types.HttpOptions(timeout=timeout_ms),
        )
        client_cache[cache_key] = client
    return client


def generate_completion(
    client_cache: dict[tuple[Any, ...], Any],
    settings: dict[str, Any],
    prompt_text: str,
    source_path: Path,
    target_path: Path,
    target_metadata: dict[str, Any],
    runtime: dict[str, Any],
    *,
    stream_to_terminal: bool,
) -> dict[str, Any]:
    client = _get_client(client_cache, settings, runtime)
    return gemini_generate_completion(
        client,
        settings,
        prompt_text,
        source_path,
        target_path,
        target_metadata,
        stream_to_terminal=stream_to_terminal,
    )
