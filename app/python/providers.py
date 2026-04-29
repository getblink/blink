from __future__ import annotations

import os
from typing import Any


class MissingCredentialError(RuntimeError):
    pass


def _provider_options(settings: dict[str, Any]) -> dict[str, Any]:
    options = settings.get("provider_options")
    return dict(options) if isinstance(options, dict) else {}


def _normalize_headers(value: Any, *, field_name: str) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{field_name} must be an object when provided")
    return {str(key): str(item) for key, item in value.items()}


def resolve_runtime_settings(settings: dict[str, Any]) -> dict[str, Any]:
    provider = str(settings.get("provider") or "gemini")
    options = _provider_options(settings)
    api_key_env = str(
        options.get("api_key_env") or ("GEMINI_API_KEY" if provider == "gemini" else "")
    ).strip()
    if not api_key_env:
        raise ValueError(f"Provider {provider} is missing provider_options.api_key_env")

    api_key = os.environ.get(api_key_env)
    if not api_key:
        # Proxy mode: BLINK_PROXY_URL+TOKEN replaces direct provider auth. We
        # still hand a non-empty placeholder to the SDK so it doesn't bail
        # before the request leaves; the proxy strips it and substitutes the
        # real upstream key.
        proxy_url = os.environ.get("BLINK_PROXY_URL")
        proxy_token = os.environ.get("BLINK_PROXY_TOKEN")
        if proxy_url and proxy_token:
            api_key = proxy_token
        else:
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
