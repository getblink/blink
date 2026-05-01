from __future__ import annotations

import base64
import time
from pathlib import Path
from typing import Any

from gemini_runner import (
    build_generation_config,
    duration_ms,
    now_iso,
    plain_data,
    prepare_request_image,
)


def _prepare_content_items(
    settings: dict[str, Any],
    content_items: list[dict[str, Any]],
) -> dict[str, Any]:
    prepare_started_perf = time.perf_counter()
    prepared_items: list[dict[str, Any]] = []
    request_inputs: dict[str, Any] = {}
    image_logs: dict[str, Any] = {}
    timings: dict[str, Any] = {}
    assembled_sections: list[str] = []
    text_chars = 0

    for item in content_items:
        item_type = str(item.get("type") or "")
        if item_type == "text":
            text = str(item.get("text") or "")
            label = str(item.get("label") or "").strip()
            prepared_items.append({"type": "text", "text": text})
            assembled_sections.append(f"{label}:\n{text}" if label else text)
            text_chars += len(text)
            continue

        if item_type == "image":
            key = str(item.get("key") or "image")
            label = str(item.get("label") or key.upper())
            path = Path(item["path"])
            if bool(item.get("preprocessed")):
                started_perf = time.perf_counter()
                started_at = now_iso()
                data = path.read_bytes()
                duration = duration_ms(started_perf)
                mime_type = str(item.get("mime_type") or "image/jpeg")
                prepared = {
                    "bytes_data": data,
                    "mime_type": mime_type,
                    "original_bytes": len(data),
                    "request_bytes": len(data),
                    "duration_ms": duration,
                    "log": {
                        "status": "preprocessed",
                        "enabled": True,
                        "started_at": started_at,
                        "finished_at": now_iso(),
                        "duration_ms": duration,
                        "original_path": str(path),
                        "original_bytes": len(data),
                        "request_path": str(path),
                        "request_bytes": len(data),
                        "request_mime_type": mime_type,
                    },
                }
            else:
                prepared = prepare_request_image(path, settings)
            prepared_items.append(
                {
                    "type": "image",
                    "key": key,
                    "label": label,
                    "bytes_data": prepared["bytes_data"],
                    "mime_type": prepared["mime_type"],
                }
            )
            image_logs[key] = prepared["log"]
            request_inputs[f"{key}_image_bytes"] = prepared["request_bytes"]
            request_inputs[f"{key}_original_image_bytes"] = prepared["original_bytes"]
            timings[f"{key}_image_prepare_ms"] = prepared["duration_ms"]
            assembled_sections.append(
                f"{label}\n[image:{path.name} request_bytes={prepared['request_bytes']} "
                f"mime={prepared['mime_type']}]"
            )
            continue

        raise ValueError(f"Unsupported content item type: {item_type}")

    assembled_request_text = "\n\n".join(section.strip() for section in assembled_sections if section.strip())
    request_inputs["text_chars"] = text_chars
    request_inputs["assembled_request_chars"] = len(assembled_request_text)
    return {
        "prepared_items": prepared_items,
        "assembled_request_text": assembled_request_text,
        "timings": {
            "request_build_ms": duration_ms(prepare_started_perf),
            **timings,
        },
        "inputs": request_inputs,
        "images": image_logs,
    }


def _extract_usage_number(payload: Any, *keys: str) -> Any:
    if not isinstance(payload, dict):
        return None
    for key in keys:
        if key in payload:
            return payload[key]
    return None


def _usage_output_tokens(usage_metadata: Any) -> Any:
    if not isinstance(usage_metadata, dict):
        return None
    for key in (
        "output_tokens",
        "completion_tokens",
        "candidates_token_count",
        "candidatesTokenCount",
    ):
        if usage_metadata.get(key) is not None:
            return usage_metadata[key]
    return None


def _response_error_message(response: Any) -> str | None:
    error = getattr(response, "error", None)
    if error is None:
        return None
    if hasattr(error, "message") and getattr(error, "message"):
        return str(getattr(error, "message"))
    if isinstance(error, dict) and error.get("message"):
        return str(error["message"])
    return str(error)


def _get_gemini_client(settings: dict[str, Any], runtime: dict[str, Any]) -> Any:
    from google import genai
    from google.genai import types
    import os

    timeout_ms = int(float(settings.get("timeout_seconds", 120)) * 1000)
    proxy_url = os.environ.get("BLINK_PROXY_URL")
    proxy_token = os.environ.get("BLINK_PROXY_TOKEN")

    headers: dict[str, str] = {}
    headers.update(runtime.get("default_headers") or {})
    if proxy_url and proxy_token:
        headers["Authorization"] = f"Bearer {proxy_token}"

    http_kwargs: dict[str, Any] = {"timeout": timeout_ms}
    if runtime.get("base_url"):
        http_kwargs["base_url"] = runtime["base_url"]
    elif proxy_url:
        http_kwargs["base_url"] = proxy_url
    if headers:
        http_kwargs["headers"] = headers

    return genai.Client(
        api_key=runtime["api_key"],
        http_options=types.HttpOptions(**http_kwargs),
    )


def _build_gemini_contents(prepared_items: list[dict[str, Any]]) -> list[Any]:
    from google.genai import types

    parts: list[Any] = []
    for item in prepared_items:
        if item["type"] == "text":
            parts.append(types.Part.from_text(text=item["text"]))
            continue
        parts.append(types.Part.from_text(text=item["label"]))
        parts.append(
            types.Part.from_bytes(
                data=item["bytes_data"],
                mime_type=item["mime_type"],
            )
        )
    return [types.Content(role="user", parts=parts)]


def _generate_gemini(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    prepared: dict[str, Any],
    runtime: dict[str, Any],
    response_mime_type: str,
    request_context: dict[str, Any],
    stream_to_terminal: bool,
) -> dict[str, Any]:
    from google.genai import types

    client = _get_gemini_client(settings, runtime)
    output_chunks: list[str] = []
    first_chunk_perf: float | None = None
    final_chunk_perf: float | None = None
    first_chunk_at: str | None = None
    final_chunk_at: str | None = None
    usage_metadata: Any = None
    final_chunk_payload: Any = None
    status = "ok"
    error_message = None
    chunk_count = 0

    config = build_generation_config(settings, prompt_text)
    config_kwargs = plain_data(config)
    config_kwargs["response_mime_type"] = response_mime_type
    generation_config = types.GenerateContentConfig(**config_kwargs)
    request_send_perf = time.perf_counter()
    request_send_at = now_iso()

    try:
        stream = client.models.generate_content_stream(
            model=settings["model"],
            contents=_build_gemini_contents(prepared["prepared_items"]),
            config=generation_config,
        )
        for chunk in stream:
            chunk_count += 1
            chunk_perf = time.perf_counter()
            if first_chunk_perf is None:
                first_chunk_perf = chunk_perf
                first_chunk_at = now_iso()
            final_chunk_perf = chunk_perf
            final_chunk_at = now_iso()
            if getattr(chunk, "text", None):
                output_chunks.append(chunk.text)
                if stream_to_terminal:
                    print(chunk.text, end="", flush=True)
            if getattr(chunk, "usage_metadata", None) is not None:
                usage_metadata = plain_data(chunk.usage_metadata)
            final_chunk_payload = plain_data(chunk)
    except Exception as exc:
        status = "error"
        error_message = str(exc)

    finished_perf = time.perf_counter()
    if final_chunk_perf is None:
        final_chunk_perf = finished_perf

    output_text = "".join(output_chunks).strip()
    output_token_count = _extract_usage_number(
        usage_metadata,
        "candidates_token_count",
        "candidatesTokenCount",
    )
    stream_duration_ms = None
    output_tps = None
    if first_chunk_perf is not None and final_chunk_perf is not None:
        stream_duration_ms = duration_ms(first_chunk_perf, final_chunk_perf)
        if output_token_count and stream_duration_ms and stream_duration_ms > 0:
            output_tps = round(float(output_token_count) / (stream_duration_ms / 1000.0), 2)

    run_log = {
        "status": status,
        "request": {
            "provider": runtime["provider"],
            "api_style": runtime.get("api_style"),
            "base_url": runtime.get("base_url"),
            "model": settings["model"],
            "request_send_at": request_send_at,
            "prompt_chars": len(prompt_text),
            **prepared["inputs"],
            "images": prepared["images"],
            **request_context,
        },
        "response": {
            "usage_metadata": usage_metadata,
            "chunk_count": chunk_count,
            "response_metadata": final_chunk_payload,
            "output_tps": output_tps,
            "output_text": output_text,
            "output_text_length": len(output_text),
        },
        "timings": {
            **prepared["timings"],
            "request_send_at": request_send_at,
            "first_chunk_at": first_chunk_at,
            "final_chunk_at": final_chunk_at,
            "ttft_ms": duration_ms(request_send_perf, first_chunk_perf)
            if first_chunk_perf is not None
            else None,
            "stream_duration_ms": stream_duration_ms,
            "model_latency_ms": duration_ms(request_send_perf, final_chunk_perf),
        },
    }
    if error_message:
        run_log["errors"] = [error_message]
    return {
        "run_log": run_log,
        "output_text": output_text,
        "assembled_request_text": prepared["assembled_request_text"],
    }


def _get_openai_client(runtime: dict[str, Any]) -> Any:
    from openai import OpenAI

    client_kwargs: dict[str, Any] = {
        "api_key": runtime["api_key"],
    }
    if runtime.get("base_url"):
        client_kwargs["base_url"] = runtime["base_url"]
    if runtime.get("default_headers"):
        client_kwargs["default_headers"] = runtime["default_headers"]
    return OpenAI(**client_kwargs)


def _image_data_uri(prepared_item: dict[str, Any]) -> str:
    data = base64.b64encode(prepared_item["bytes_data"]).decode("ascii")
    return f"data:{prepared_item['mime_type']};base64,{data}"


def _chat_messages(prompt_text: str, prepared_items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    user_content: list[dict[str, Any]] = []
    for item in prepared_items:
        if item["type"] == "text":
            user_content.append({"type": "text", "text": item["text"]})
            continue
        user_content.append({"type": "text", "text": item["label"]})
        user_content.append(
            {
                "type": "image_url",
                "image_url": {"url": _image_data_uri(item)},
            }
        )
    return [
        {"role": "system", "content": prompt_text},
        {"role": "user", "content": user_content},
    ]


def _responses_input(prepared_items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    user_content: list[dict[str, Any]] = []
    for item in prepared_items:
        if item["type"] == "text":
            user_content.append({"type": "input_text", "text": item["text"]})
            continue
        user_content.append({"type": "input_text", "text": item["label"]})
        user_content.append(
            {
                "type": "input_image",
                "image_url": _image_data_uri(item),
            }
        )
    return [{"role": "user", "content": user_content}]


def _generate_openai(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    prepared: dict[str, Any],
    runtime: dict[str, Any],
    request_context: dict[str, Any],
    stream_to_terminal: bool,
) -> dict[str, Any]:
    client = _get_openai_client(runtime).with_options(
        timeout=float(settings.get("timeout_seconds", 120))
    )
    api_style = runtime["api_style"]

    output_chunks: list[str] = []
    first_chunk_perf: float | None = None
    final_chunk_perf: float | None = None
    first_chunk_at: str | None = None
    final_chunk_at: str | None = None
    usage_metadata: Any = None
    final_chunk_payload: Any = None
    status = "ok"
    error_message = None
    chunk_count = 0

    request_send_perf = time.perf_counter()
    request_send_at = now_iso()

    try:
        if api_style == "chat_completions":
            request_kwargs: dict[str, Any] = {
                "model": settings["model"],
                "messages": _chat_messages(prompt_text, prepared["prepared_items"]),
                "stream": True,
                "stream_options": {"include_usage": True},
            }
            if settings.get("temperature") is not None:
                request_kwargs["temperature"] = float(settings["temperature"])
            if settings.get("max_output_tokens") is not None:
                request_kwargs["max_tokens"] = int(settings["max_output_tokens"])
            if runtime.get("extra_body") is not None:
                request_kwargs["extra_body"] = runtime["extra_body"]
            if runtime.get("extra_headers"):
                request_kwargs["extra_headers"] = runtime["extra_headers"]

            stream = client.chat.completions.create(**request_kwargs)
            for chunk in stream:
                chunk_count += 1
                chunk_perf = time.perf_counter()
                if first_chunk_perf is None:
                    first_chunk_perf = chunk_perf
                    first_chunk_at = now_iso()
                final_chunk_perf = chunk_perf
                final_chunk_at = now_iso()

                if chunk.choices:
                    delta = chunk.choices[0].delta
                    if getattr(delta, "content", None):
                        text = delta.content
                        output_chunks.append(text)
                        if stream_to_terminal:
                            print(text, end="", flush=True)
                if getattr(chunk, "usage", None) is not None:
                    usage_metadata = plain_data(chunk.usage)
                final_chunk_payload = plain_data(chunk)
        elif api_style == "responses":
            request_kwargs = {
                "model": settings["model"],
                "instructions": prompt_text,
                "input": _responses_input(prepared["prepared_items"]),
                "stream": True,
            }
            if settings.get("temperature") is not None:
                request_kwargs["temperature"] = float(settings["temperature"])
            if settings.get("max_output_tokens") is not None:
                request_kwargs["max_output_tokens"] = int(settings["max_output_tokens"])
            if runtime.get("extra_body") is not None:
                request_kwargs["extra_body"] = runtime["extra_body"]
            if runtime.get("extra_headers"):
                request_kwargs["extra_headers"] = runtime["extra_headers"]

            completed_response = None
            stream = client.responses.create(**request_kwargs)
            for event in stream:
                chunk_count += 1
                chunk_perf = time.perf_counter()
                if first_chunk_perf is None:
                    first_chunk_perf = chunk_perf
                    first_chunk_at = now_iso()
                final_chunk_perf = chunk_perf
                final_chunk_at = now_iso()

                event_type = getattr(event, "type", "")
                if event_type == "response.output_text.delta" and getattr(event, "delta", None):
                    text = event.delta
                    output_chunks.append(text)
                    if stream_to_terminal:
                        print(text, end="", flush=True)
                elif event_type == "response.completed":
                    completed_response = getattr(event, "response", None)
                    usage_metadata = plain_data(getattr(completed_response, "usage", None))
                elif event_type in {"response.failed", "response.incomplete"}:
                    status = "error"
                    completed_response = getattr(event, "response", None)
                    usage_metadata = plain_data(getattr(completed_response, "usage", None))
                    error_message = _response_error_message(completed_response) or str(
                        getattr(completed_response, "status", event_type)
                    )
                elif event_type == "error":
                    status = "error"
                    error_message = str(getattr(event, "message", "streaming error"))
                final_chunk_payload = plain_data(event)

            if completed_response is not None and not output_chunks:
                completed_text = getattr(completed_response, "output_text", None)
                if completed_text:
                    output_chunks.append(str(completed_text))
            if completed_response is not None:
                final_chunk_payload = plain_data(completed_response)
        else:
            raise ValueError(f"Unsupported api_style: {api_style}")
    except Exception as exc:
        status = "error"
        error_message = str(exc)

    finished_perf = time.perf_counter()
    if final_chunk_perf is None:
        final_chunk_perf = finished_perf

    output_text = "".join(output_chunks).strip()
    output_token_count = _usage_output_tokens(usage_metadata)
    stream_duration_ms = None
    output_tps = None
    if first_chunk_perf is not None and final_chunk_perf is not None:
        stream_duration_ms = duration_ms(first_chunk_perf, final_chunk_perf)
        if output_token_count and stream_duration_ms and stream_duration_ms > 0:
            output_tps = round(float(output_token_count) / (stream_duration_ms / 1000.0), 2)

    run_log = {
        "status": status,
        "request": {
            "provider": runtime["provider"],
            "api_style": api_style,
            "base_url": runtime.get("base_url"),
            "model": settings["model"],
            "request_send_at": request_send_at,
            "prompt_chars": len(prompt_text),
            **prepared["inputs"],
            "images": prepared["images"],
            **request_context,
        },
        "response": {
            "usage_metadata": usage_metadata,
            "chunk_count": chunk_count,
            "response_metadata": final_chunk_payload,
            "output_tps": output_tps,
            "output_text": output_text,
            "output_text_length": len(output_text),
        },
        "timings": {
            **prepared["timings"],
            "request_send_at": request_send_at,
            "first_chunk_at": first_chunk_at,
            "final_chunk_at": final_chunk_at,
            "ttft_ms": duration_ms(request_send_perf, first_chunk_perf)
            if first_chunk_perf is not None
            else None,
            "stream_duration_ms": stream_duration_ms,
            "model_latency_ms": duration_ms(request_send_perf, final_chunk_perf),
        },
    }
    if error_message:
        run_log["errors"] = [error_message]
    return {
        "run_log": run_log,
        "output_text": output_text,
        "assembled_request_text": prepared["assembled_request_text"],
    }


def generate_completion(
    *,
    settings: dict[str, Any],
    prompt_text: str,
    content_items: list[dict[str, Any]],
    runtime: dict[str, Any],
    response_mime_type: str = "text/plain",
    request_context: dict[str, Any] | None = None,
    stream_to_terminal: bool = False,
) -> dict[str, Any]:
    prepared = _prepare_content_items(settings, content_items)
    context = dict(request_context or {})
    if runtime["provider"] == "gemini":
        return _generate_gemini(
            settings=settings,
            prompt_text=prompt_text,
            prepared=prepared,
            runtime=runtime,
            response_mime_type=response_mime_type,
            request_context=context,
            stream_to_terminal=stream_to_terminal,
        )
    if runtime["provider"] == "openai_sdk":
        return _generate_openai(
            settings=settings,
            prompt_text=prompt_text,
            prepared=prepared,
            runtime=runtime,
            request_context=context,
            stream_to_terminal=stream_to_terminal,
        )
    raise ValueError(f"Unsupported provider: {runtime['provider']}")
