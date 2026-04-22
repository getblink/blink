from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from . import gemini, openai_sdk


class MissingCredentialError(RuntimeError):
    pass


def provider_name(settings: dict[str, Any]) -> str:
    return str(settings.get("provider") or "gemini")


def _provider_options(settings: dict[str, Any]) -> dict[str, Any]:
    options = settings.get("provider_options")
    return dict(options) if isinstance(options, dict) else {}


def _normalize_headers(
    value: Any,
    *,
    field_name: str,
) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{field_name} must be an object when provided")
    return {str(key): str(item) for key, item in value.items()}


def resolve_runtime_settings(settings: dict[str, Any]) -> dict[str, Any]:
    provider = provider_name(settings)
    options = _provider_options(settings)
    api_key_env = str(
        options.get("api_key_env") or ("GEMINI_API_KEY" if provider == "gemini" else "")
    ).strip()
    if not api_key_env:
        raise ValueError(f"Provider {provider} is missing provider_options.api_key_env")

    api_key = os.environ.get(api_key_env)
    if not api_key:
        raise MissingCredentialError(f"Missing required env var: {api_key_env}")

    base_url = options.get("base_url")
    if base_url is not None and not isinstance(base_url, str):
        raise ValueError("provider_options.base_url must be a string when provided")

    for env_name in options.get("url_substitutions", []) or []:
        env_name = str(env_name)
        value = os.environ.get(env_name)
        if not value:
            raise MissingCredentialError(
                f"Missing required env var for base_url substitution: {env_name}"
            )
        if base_url is not None:
            base_url = base_url.replace(f"{{{env_name}}}", value)

    return {
        "provider": provider,
        "api_key_env": api_key_env,
        "api_key": api_key,
        "api_style": str(options.get("api_style") or "chat_completions"),
        "base_url": base_url,
        "default_headers": _normalize_headers(
            options.get("default_headers"),
            field_name="provider_options.default_headers",
        ),
        "extra_headers": _normalize_headers(
            options.get("extra_headers"),
            field_name="provider_options.extra_headers",
        ),
        "extra_body": options.get("extra_body"),
        "provider_options": options,
    }


def dispatch(
    client_cache: dict[tuple[Any, ...], Any],
    config: dict[str, Any],
    prompt_text: str,
    source_path: Path,
    target_path: Path,
    target_metadata: dict[str, Any],
) -> dict[str, Any]:
    settings = config["settings"]
    runtime = resolve_runtime_settings(settings)
    provider = runtime["provider"]

    if provider == "gemini":
        return gemini.generate_completion(
            client_cache,
            settings,
            prompt_text,
            source_path,
            target_path,
            target_metadata,
            runtime,
            stream_to_terminal=False,
        )
    if provider == "openai_sdk":
        return openai_sdk.generate_completion(
            client_cache,
            settings,
            prompt_text,
            source_path,
            target_path,
            target_metadata,
            runtime,
            stream_to_terminal=False,
        )
    raise ValueError(f"Unsupported provider: {provider}")


__all__ = ["MissingCredentialError", "dispatch", "provider_name", "resolve_runtime_settings"]
