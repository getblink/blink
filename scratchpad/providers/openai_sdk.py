from __future__ import annotations

import base64
import json
import time
from pathlib import Path
from typing import Any

from openai import OpenAI

from gemini_runner import duration_ms, now_iso, plain_data, prepare_request_image


def _request_prep(
    settings: dict[str, Any],
    source_path: Path,
    target_path: Path,
    target_metadata: dict[str, Any],
) -> dict[str, Any]:
    prepare_started_perf = time.perf_counter()
    metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
    instruction_text = (
        "TARGET_METADATA_JSON:\n"
        f"{metadata_json}\n\n"
        "Use the source image as the source context and the target image as the destination context."
    )

    source_request_image = prepare_request_image(source_path, settings)
    target_request_image = prepare_request_image(target_path, settings)

    source_b64 = base64.b64encode(source_request_image["bytes_data"]).decode("ascii")
    target_b64 = base64.b64encode(target_request_image["bytes_data"]).decode("ascii")

    return {
        "instruction_text": instruction_text,
        "source_data_uri": f"data:{source_request_image['mime_type']};base64,{source_b64}",
        "target_data_uri": f"data:{target_request_image['mime_type']};base64,{target_b64}",
        "timings": {
            "request_build_ms": duration_ms(prepare_started_perf),
            "source_image_prepare_ms": source_request_image["duration_ms"],
            "target_image_prepare_ms": target_request_image["duration_ms"],
        },
        "inputs": {
            "instruction_chars": len(instruction_text),
            "source_image_bytes": source_request_image["request_bytes"],
            "target_image_bytes": target_request_image["request_bytes"],
            "source_original_image_bytes": source_request_image["original_bytes"],
            "target_original_image_bytes": target_request_image["original_bytes"],
        },
        "images": {
            "source": source_request_image["log"],
            "target": target_request_image["log"],
        },
    }


def _chat_messages(prep: dict[str, Any], prompt_text: str) -> list[dict[str, Any]]:
    return [
        {"role": "system", "content": prompt_text},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prep["instruction_text"]},
                {"type": "text", "text": "SOURCE_IMAGE"},
                {
                    "type": "image_url",
                    "image_url": {"url": prep["source_data_uri"]},
                },
                {"type": "text", "text": "TARGET_IMAGE"},
                {
                    "type": "image_url",
                    "image_url": {"url": prep["target_data_uri"]},
                },
            ],
        },
    ]


def _responses_input(prep: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "role": "user",
            "content": [
                {"type": "input_text", "text": prep["instruction_text"]},
                {"type": "input_text", "text": "SOURCE_IMAGE"},
                {"type": "input_image", "image_url": prep["source_data_uri"]},
                {"type": "input_text", "text": "TARGET_IMAGE"},
                {"type": "input_image", "image_url": prep["target_data_uri"]},
            ],
        }
    ]


def _get_client(
    client_cache: dict[tuple[Any, ...], Any],
    runtime: dict[str, Any],
) -> OpenAI:
    headers = runtime.get("default_headers") or {}
    cache_key = (
        "openai_sdk",
        runtime["api_key"],
        runtime.get("base_url") or "",
        tuple(sorted(headers.items())),
    )
    client = client_cache.get(cache_key)
    if client is None:
        client_kwargs: dict[str, Any] = {
            "api_key": runtime["api_key"],
            "default_headers": headers or None,
        }
        if runtime.get("base_url"):
            client_kwargs["base_url"] = runtime["base_url"]
        client = OpenAI(**client_kwargs)
        client_cache[cache_key] = client
    return client


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
    client = _get_client(client_cache, runtime)
    prep = _request_prep(settings, source_path, target_path, target_metadata)
    request_client = client.with_options(timeout=float(settings.get("timeout_seconds", 120)))
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
                "messages": _chat_messages(prep, prompt_text),
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

            request_send_perf = time.perf_counter()
            request_send_at = now_iso()
            stream = request_client.chat.completions.create(**request_kwargs)
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
                "input": _responses_input(prep),
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
            request_send_perf = time.perf_counter()
            request_send_at = now_iso()
            stream = request_client.responses.create(**request_kwargs)
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
            **prep["inputs"],
            "images": prep["images"],
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
            **prep["timings"],
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
    return {"run_log": run_log, "output_text": output_text}
