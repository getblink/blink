from __future__ import annotations

# Forked from scratchpad/tldr_reply/gemini.py @ 3f7352ae6c27b8099fe000d7a64a0b02b6f0f209

import json
import re
import time
from pathlib import Path
from typing import Any, Iterator

DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3-flash-preview",
    "temperature": 1.0,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "timeout_seconds": 120,
}

MODEL_CONTENT_TEXT = "Summarize this active window and propose three replies."
REROLL_CONTENT_TEXT = (
    "Produce a fresh set of three suggestions. They must not overlap in stance, "
    "verb shape, or wording with your previous response above. If two valid moves "
    "cover the same intent, pick the one you did not already offer. Keep the same JSON schema."
)
PREFERENCE_EXAMPLE_LIMIT = 3
PREFERENCE_REJECTED_SUGGESTION_LIMIT = 3
VOICE_SAMPLE_MAX_CHARS = 500
SURFACE_TEXT_MAX_CHARS = 500
PREFERENCE_TEXT_MAX_CHARS = 360
RESPONSE_SCHEMA_VERSION = 2
SUGGESTION_TAG_LIMIT = 2
SUGGESTION_TAG_MAX_CHARS = 24

STYLE_ABOUT_ME_MAX_CHARS = 2000

# Recent same-surface history is currently disabled in the rendered prompt
# while the architecture is iterated on. Known issues observed in dogfood:
#
# 1. Feedback loop: prior TL;DR is lifted verbatim into the next request's
#    surface history, so any identifier (commit hash, PID, build number)
#    that leaked into a TL;DR keeps reappearing across subsequent captures
#    and reinforces itself.
# 2. Stale-context bias: the model treats prior summaries as ambient
#    "what's happening on this surface" instead of "snapshot from N seconds
#    ago about a different concrete moment," so it surfaces those specifics
#    as if they were on the current screen.
# 3. Novelty test breakdown: rule 5's "session-produced identifiers are
#    noise" relies on the model knowing what was session-produced.  When the
#    hash arrives via surface_history, the model reads it as ambient context
#    rather than something it just helped produce, and the rule misfires.
# 4. Voice-sample contamination (separate but related): conversational
#    fragments the user typed to a coding agent are captured as voice
#    samples and bleed into suggestions on unrelated surfaces.  Leaving
#    voice samples on for now; this is tracked as a follow-up.
#
# When re-enabling, options to consider: sanitize prior TL;DRs before
# injecting them; truncate prior summaries to a topic-level cue rather than
# the full text; or differentiate "what was on the surface" from "what the
# model said about it."
SURFACE_HISTORY_ENABLED = False
STYLE_KNOB_INSTRUCTIONS: dict[str, dict[str, str]] = {
    "initiative": {
        "incremental": "Initiative: stay incremental. Suggest small continuations or short nudges, not full drafts.",
        "agentic": "Initiative: take the lead. Produce complete, send-ready drafts the user can use as-is.",
    },
    "tone": {
        "casual": "Tone: casual. Contractions are fine, lowercase is fine, light punctuation.",
        "formal": "Tone: formal. Proper punctuation, professional register, no slang.",
    },
    "length": {
        "terse": "Length: keep each suggestion to one short sentence.",
        "thorough": "Length: two or three sentences are fine when the situation calls for it.",
    },
    "directness": {
        "diplomatic": "Directness: lean diplomatic. Soften pushback, hedge, preserve harmony.",
        "direct": "Directness: be direct. Push back when you disagree; name the real issue without softening.",
    },
    "voice_mirror": {
        "neutral": "Voice mirror: use a clean neutral register; do not lean hard on prior voice samples.",
        "mirror": "Voice mirror: tightly imitate the user's voice samples even when they clash with the current capture's tone.",
    },
}
STYLE_KNOB_ORDER = ("initiative", "tone", "length", "directness", "voice_mirror")


def style_block(style: dict[str, Any] | None) -> str:
    if not isinstance(style, dict):
        return ""
    lines: list[str] = []
    for knob in STYLE_KNOB_ORDER:
        value = str(style.get(knob) or "").strip().lower()
        instruction = STYLE_KNOB_INSTRUCTIONS.get(knob, {}).get(value)
        if instruction:
            lines.append(f"- {instruction}")
    about_me = str(style.get("about_me") or "").strip()
    if about_me:
        about_me = about_me[:STYLE_ABOUT_ME_MAX_CHARS]
        lines.append(f"- About the user: {about_me}")
    if not lines:
        return ""
    return "Style preferences:\n" + "\n".join(lines)


def _is_thinking_model(model: str) -> bool:
    """Gemini 3 Pro / Flash are reasoning models with non-trivial thinking budgets."""
    if not model:
        return False
    name = model.lower()
    if not name.startswith(("gemini-3-", "gemini-3.")):
        return False
    return "flash-lite" not in name


def thinking_level_for_model(model: str) -> str | None:
    """Return the thinking_level for a model, or None to omit it.

    "low" matches the task (a quick screen summary + 3 reply suggestions is
    closer to "simple instruction following" than complex reasoning). Diversity
    comes from temperature=1.0 and the reroll-instruction rewrite, not thinking
    depth. "high" greedily fills max_output_tokens on Gemini 3 and "medium"
    still burned ~2400 tokens on this task in dogfood. "minimal" is avoided:
    Flash has historically hallucinated its own model name at that level.
    """
    return "low" if _is_thinking_model(model) else None


def max_output_tokens_for_model(model: str) -> int | None:
    """Per-model override for max_output_tokens, or None to honor settings."""
    return 4096 if _is_thinking_model(model) else None


def media_resolution_for_model(model: str, base: str) -> str:
    if model == "gemini-3-flash-preview":
        return "MEDIA_RESOLUTION_MEDIUM"
    return base


def _bounded_text(value: Any, limit: int) -> str | None:
    text = str(value or "").strip()
    if not text:
        return None
    return text[:limit]


def prompt_with_context(
    prompt_text: str,
    stateful_context: dict[str, Any] | None,
    reroll_context: dict[str, Any] | None = None,
    style: dict[str, Any] | None = None,
) -> str:
    if not stateful_context:
        stateful_context = {}
    voice_samples = stateful_context.get("voice_samples")
    preference_examples = stateful_context.get("preference_examples")
    surface_history = stateful_context.get("recent_surface_history")
    if not isinstance(voice_samples, list):
        voice_samples = []
    if not isinstance(preference_examples, list):
        preference_examples = []
    if not isinstance(surface_history, list):
        surface_history = []
    if not SURFACE_HISTORY_ENABLED:
        surface_history = []
    if not isinstance(reroll_context, dict):
        reroll_context = {}
    previous_suggestions = reroll_context.get("previous_suggestions")
    if not isinstance(previous_suggestions, list):
        previous_suggestions = []
    previous_suggestion_texts = [
        text
        for text in (_bounded_text(item, PREFERENCE_TEXT_MAX_CHARS) for item in previous_suggestions)
        if text
    ][:3]
    style_text = style_block(style)
    if (
        not voice_samples
        and not preference_examples
        and not surface_history
        and not previous_suggestion_texts
        and not style_text
    ):
        return prompt_text
    has_stateful_context = bool(voice_samples or preference_examples or surface_history)
    preference_texts = {
        text
        for example in preference_examples
        if isinstance(example, dict)
        for text in [_bounded_text(example.get("user_typed"), PREFERENCE_TEXT_MAX_CHARS)]
        if text
    }
    lines = [""]
    if style_text:
        lines.append(style_text)
    if has_stateful_context:
        lines.extend(
            [
                "Stateful Blink context:",
                "Use user preference examples to infer which suggestions are useful in this surface.",
                "User voice examples below are samples of how this user actually writes. Imitate their style closely in the suggestions: casing, punctuation, contractions, sentence shape, vocabulary, hedging, emoji habits. The 'do not copy facts' rule applies: if a voice sample mentions a name, fact, or commitment that isn't on the current screen, don't carry it over. The current capture's tone wins when it conflicts with older voice (for example, a formal escalation overrides a casual chat tic).",
                "Use recent same-surface history only for continuity in this immediate thread. Current screen evidence wins.",
            ]
        )
    if previous_suggestion_texts:
        lines.extend(
            [
                "Reroll instructions:",
                "The user asked for a fresh set of suggestions for the same capture. Use the same visible evidence, but avoid repeating these previous suggestions unless one is clearly the only correct answer:",
            ]
        )
        for suggestion in previous_suggestion_texts:
            lines.append(f"- {suggestion}")
    if preference_examples:
        valid_pref_examples: list[tuple[dict[str, Any], str, list[str]]] = []
        for example in preference_examples[:PREFERENCE_EXAMPLE_LIMIT]:
            if not isinstance(example, dict):
                continue
            user_typed = _bounded_text(example.get("user_typed"), PREFERENCE_TEXT_MAX_CHARS)
            rejected = example.get("rejected_suggestions")
            if not user_typed or not isinstance(rejected, list):
                continue
            rejected_texts = [
                text
                for text in (_bounded_text(item, PREFERENCE_TEXT_MAX_CHARS) for item in rejected)
                if text
            ][:PREFERENCE_REJECTED_SUGGESTION_LIMIT]
            if not rejected_texts:
                continue
            valid_pref_examples.append((example, user_typed, rejected_texts))
        if len(valid_pref_examples) == 1:
            _, user_typed, _ = valid_pref_examples[0]
            lines.append(f'Last time, the user typed "{user_typed}" instead of the model\'s suggestions.')
        elif valid_pref_examples:
            lines.extend(
                [
                    "User preference examples from this same surface:",
                    "These show cases where model suggestions were not useful enough and the user typed their own reply instead.",
                    "These are individual data points, not a pattern. Don't extrapolate a stance or verb shape from a single example; at most they tell you the user wanted something more specific than what was offered.",
                ]
            )
            for index, (example, user_typed, rejected_texts) in enumerate(valid_pref_examples, start=1):
                screen_takeaway = _bounded_text(example.get("screen_takeaway"), PREFERENCE_TEXT_MAX_CHARS)
                lines.append(f"Example {index}:")
                if screen_takeaway:
                    lines.append(f"Screen takeaway: {screen_takeaway}")
                lines.append("Model suggestions the user did not use:")
                for suggestion in rejected_texts:
                    lines.append(f"- {suggestion}")
                lines.append(f"User typed instead: {user_typed}")
    if voice_samples:
        rendered_voice_samples = []
        for sample in voice_samples:
            if not isinstance(sample, dict):
                continue
            text = _bounded_text(sample.get("text"), VOICE_SAMPLE_MAX_CHARS)
            if text and text not in preference_texts:
                rendered_voice_samples.append(text)
        if rendered_voice_samples:
            lines.append("User voice examples:")
            for text in rendered_voice_samples:
                lines.append(f"- {text}")
    if surface_history:
        lines.append("Recent same-surface history:")
        for item in surface_history:
            if not isinstance(item, dict):
                continue
            tldr = _bounded_text(item.get("tldr"), SURFACE_TEXT_MAX_CHARS)
            custom_reply = _bounded_text(item.get("custom_reply_text"), SURFACE_TEXT_MAX_CHARS)
            chosen_text = _bounded_text(item.get("chosen_text"), SURFACE_TEXT_MAX_CHARS)
            chosen_action = _bounded_text(item.get("chosen_action"), 80)
            chosen_index = item.get("chosen_index")
            if tldr:
                lines.append(f"- Prior summary: {tldr}")
            if custom_reply:
                if custom_reply in preference_texts:
                    lines.append("  Prior outcome: user typed a custom reply instead of using the suggestions.")
                else:
                    lines.append(f"  Prior outcome: {custom_reply}")
            elif chosen_text:
                index_text = f" #{chosen_index + 1}" if isinstance(chosen_index, int) else ""
                action_text = chosen_action or "used"
                lines.append(
                    f"  Prior outcome: user {action_text} model suggestion{index_text}; "
                    "do not copy that prior model-authored wording into new suggestions."
                )
    return prompt_text.rstrip() + "\n" + "\n".join(lines) + "\n"


def prompt_with_stateful_context(prompt_text: str, stateful_context: dict[str, Any] | None) -> str:
    return prompt_with_context(prompt_text, stateful_context)


def plain_data(value: Any) -> Any:
    if value is None:
        return None
    if hasattr(value, "model_dump"):
        return value.model_dump(exclude_none=True)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(key): plain_data(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain_data(item) for item in value]
    if isinstance(value, (str, int, float, bool)):
        return value
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            break
    else:
        return str(value)

    payload: dict[str, Any] = {}
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            payload[attr] = float(getattr(value, attr))
    return payload


def create_client(api_key: str | None, settings: dict[str, Any]) -> Any:
    from google import genai
    from google.genai import types

    return genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(
            timeout=int(settings["timeout_seconds"] * 1000)
        ),
    )


def response_schema_contract() -> dict[str, Any]:
    return {
        "type": "object",
        "required": ["schema_version", "tldr", "suggestions"],
        "property_ordering": ["schema_version", "tldr", "suggestions"],
        "properties": {
            "schema_version": {
                "type": "integer",
                "description": "Response schema version. Always 2.",
            },
            "tldr": {
                "type": "string",
                "description": "Takeaway summary of the capture. Length scales with capture density (see prompt rule 10).",
            },
            "suggestions": {
                "type": "array",
                "min_items": 3,
                "max_items": 3,
                "items": {
                    "type": "object",
                    "required": ["text", "tags"],
                    "property_ordering": ["text", "tags"],
                    "properties": {
                        "text": {
                            "type": "string",
                            "description": "A candidate reply the user might send next.",
                        },
                        "tags": {
                            "type": "array",
                            "min_items": 1,
                            "max_items": 2,
                            "items": {
                                "type": "string",
                                "max_length": SUGGESTION_TAG_MAX_CHARS,
                                "description": "A short label describing the suggestion's move.",
                            },
                        },
                    },
                },
            },
        },
    }


def _schema() -> types.Schema:
    from google.genai import types

    return types.Schema(
        type=types.Type.OBJECT,
        required=["schema_version", "tldr", "suggestions"],
        propertyOrdering=["schema_version", "tldr", "suggestions"],
        properties={
            "schema_version": types.Schema(
                type=types.Type.INTEGER,
                description="Response schema version. Always 2.",
            ),
            "tldr": types.Schema(
                type=types.Type.STRING,
                description="Takeaway summary of the capture. Length scales with capture density (see prompt rule 10).",
            ),
            "suggestions": types.Schema(
                type=types.Type.ARRAY,
                minItems=3,
                maxItems=3,
                items=types.Schema(
                    type=types.Type.OBJECT,
                    required=["text", "tags"],
                    propertyOrdering=["text", "tags"],
                    properties={
                        "text": types.Schema(
                            type=types.Type.STRING,
                            description="A candidate reply the user might send next.",
                        ),
                        "tags": types.Schema(
                            type=types.Type.ARRAY,
                            minItems=1,
                            maxItems=2,
                            items=types.Schema(
                                type=types.Type.STRING,
                                maxLength=SUGGESTION_TAG_MAX_CHARS,
                                description="A short label describing the suggestion's move.",
                            ),
                        ),
                    },
                ),
            ),
        },
    )


def _parse_json_response(raw_text: str) -> tuple[dict[str, Any] | None, str | None]:
    try:
        parsed = json.loads(raw_text)
        return parsed, None
    except json.JSONDecodeError as first_error:
        match = re.search(r"\{.*\}", raw_text, flags=re.DOTALL)
        if not match:
            return None, str(first_error)
        try:
            return json.loads(match.group(0)), None
        except json.JSONDecodeError as second_error:
            return None, str(second_error)


def _normalize_tag(value: Any) -> str | None:
    text = str(value or "").strip()
    if not text:
        return None
    return text[:SUGGESTION_TAG_MAX_CHARS]


def fallback_suggestion_tags(text: str, index: int) -> list[str]:
    normalized = text.strip().lower()
    if (
        "?" in normalized
        or normalized.startswith(("can you", "could you", "would you", "please"))
    ):
        return ["Ask"]
    if normalized.startswith(("wait", "hold on", "i don't", "no,")):
        return ["Pushback"]
    if normalized.startswith((
        "show me",
        "check",
        "fix",
        "add",
        "update",
        "implement",
        "push",
    )):
        return ["Next step"]
    return [["Reply"], ["Ask"], ["Next step"]][max(0, min(index, 2))]


def normalize_suggestion_details(parsed: dict[str, Any]) -> list[dict[str, Any]]:
    raw_suggestions = parsed.get("suggestions")
    if not isinstance(raw_suggestions, list):
        raw_suggestions = []
    details: list[dict[str, Any]] = []
    for item in raw_suggestions:
        if isinstance(item, dict):
            text = str(item.get("text") or item.get("suggestion") or "").strip()
            raw_tags = item.get("tags")
            if not isinstance(raw_tags, list):
                raw_tags = []
            tags = [
                tag
                for tag in (_normalize_tag(raw_tag) for raw_tag in raw_tags)
                if tag
            ][:SUGGESTION_TAG_LIMIT]
        else:
            text = str(item or "").strip()
            tags = []
        if text:
            if not tags:
                tags = fallback_suggestion_tags(text, len(details))
            details.append({"text": text, "tags": tags})
    return details[:3]


def _normalize_payload(parsed: dict[str, Any]) -> tuple[str, list[str], list[dict[str, Any]]]:
    tldr = str(parsed.get("tldr") or "").strip()
    suggestion_details = normalize_suggestion_details(parsed)
    suggestions = [item["text"] for item in suggestion_details]
    return tldr, suggestions, suggestion_details


def usage_token_count(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    for key in ("total_token_count", "total_tokens", "totalTokenCount"):
        value = usage.get(key)
        if isinstance(value, int):
            return value
    return None


def usage_thoughts_token_count(usage: Any) -> int | None:
    if not isinstance(usage, dict):
        return None
    for key in ("thoughts_token_count", "thoughtsTokenCount", "thinking_tokens"):
        value = usage.get(key)
        if isinstance(value, int):
            return value
    return None


def extract_partial_suggestions(raw_text: str) -> list[str]:
    marker = '"suggestions"'
    marker_index = raw_text.find(marker)
    if marker_index < 0:
        return []
    bracket_index = raw_text.find("[", marker_index + len(marker))
    if bracket_index < 0:
        return []
    array_prefix = raw_text[bracket_index + 1:]
    if array_prefix.lstrip().startswith("{"):
        suggestions = []
        for match in re.finditer(r'"text"\s*:\s*"', array_prefix):
            parsed = _parse_partial_json_string(array_prefix[match.end() - 1:])
            if parsed:
                suggestions.append(parsed)
        return suggestions

    suggestions: list[str] = []
    chars: list[str] = []
    in_string = False
    escaped = False
    for char in raw_text[bracket_index + 1:]:
        if in_string:
            if escaped:
                if char == "n":
                    chars.append("\n")
                elif char == "t":
                    chars.append("\t")
                elif char == "r":
                    chars.append("\r")
                else:
                    chars.append(char)
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == '"':
                suggestions.append("".join(chars))
                chars = []
                in_string = False
                continue
            chars.append(char)
        else:
            if char == '"':
                in_string = True
                continue
            if char == "]":
                break
    if in_string and chars:
        suggestions.append("".join(chars))
    return suggestions


def _parse_partial_json_string(raw_text: str) -> str | None:
    if not raw_text.startswith('"'):
        return None
    chars: list[str] = []
    escaped = False
    for char in raw_text[1:]:
        if escaped:
            if char == "n":
                chars.append("\n")
            elif char == "t":
                chars.append("\t")
            elif char == "r":
                chars.append("\r")
            else:
                chars.append(char)
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"':
            break
        chars.append(char)
    text = "".join(chars).strip()
    return text or None


def extract_partial_tldr(raw_text: str) -> str | None:
    marker = '"tldr"'
    marker_index = raw_text.find(marker)
    if marker_index < 0:
        return None
    colon_index = raw_text.find(":", marker_index + len(marker))
    if colon_index < 0:
        return None
    quote_index = raw_text.find('"', colon_index + 1)
    if quote_index < 0:
        return None

    chars: list[str] = []
    escaped = False
    for char in raw_text[quote_index + 1:]:
        if escaped:
            if char == "n":
                chars.append("\n")
            elif char == "t":
                chars.append("\t")
            elif char == "r":
                chars.append("\r")
            else:
                chars.append(char)
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"':
            break
        chars.append(char)

    text = "".join(chars).strip()
    return text or None


def _image_contents(types: Any, images: list[tuple[bytes, str]] | None, image_bytes: bytes | None, mime_type: str) -> list[Any]:
    if images is None:
        images = [(image_bytes, mime_type)] if image_bytes is not None else []
    return [
        types.Part.from_bytes(
            data=data,
            mime_type=image_mime_type,
        )
        for data, image_mime_type in images
    ]


def _text_part(types: Any, text: str) -> Any:
    return types.Part.from_text(text=text)


def _model_turn_text(turn: dict[str, Any]) -> str | None:
    tldr = str(turn.get("tldr") or "").strip()
    suggestions = turn.get("suggestion_details")
    if not isinstance(suggestions, list):
        suggestions = [
            {"text": str(item or "").strip(), "tags": []}
            for item in turn.get("suggestions") or []
            if str(item or "").strip()
        ]
    normalized = []
    for item in suggestions:
        if not isinstance(item, dict):
            continue
        text = str(item.get("text") or "").strip()
        if not text:
            continue
        raw_tags = item.get("tags")
        tags = [
            str(tag).strip()
            for tag in raw_tags
            if str(tag).strip()
        ][:SUGGESTION_TAG_LIMIT] if isinstance(raw_tags, list) else []
        normalized.append({"text": text, "tags": tags})
        if len(normalized) >= 3:
            break
    if not tldr and not normalized:
        return None
    return json.dumps(
        {
            "schema_version": RESPONSE_SCHEMA_VERSION,
            "tldr": tldr,
            "suggestions": normalized,
        },
        ensure_ascii=True,
        sort_keys=True,
    )


def _conversation_contents(
    types: Any,
    images: list[tuple[bytes, str]] | None,
    image_bytes: bytes | None,
    mime_type: str,
    conversation_turns: list[dict[str, Any]] | None,
) -> list[Any]:
    image_parts = _image_contents(types, images, image_bytes, mime_type)
    if not image_parts:
        return []
    if not conversation_turns:
        return [
            types.Content(
                role="user",
                parts=image_parts + [_text_part(types, MODEL_CONTENT_TEXT)],
            )
        ]

    contents: list[Any] = []
    used_capture_images = False

    def append_content(role: str, parts: list[Any]) -> None:
        if not parts:
            return
        if contents and getattr(contents[-1], "role", None) == role:
            contents[-1].parts.extend(parts)
            return
        contents.append(types.Content(role=role, parts=parts))

    for turn in conversation_turns:
        if not isinstance(turn, dict):
            continue
        role = str(turn.get("role") or "").strip()
        if role == "user":
            kind = str(turn.get("kind") or "").strip()
            if kind == "capture" and not used_capture_images:
                append_content(
                    "user",
                    image_parts + [_text_part(types, MODEL_CONTENT_TEXT)],
                )
                used_capture_images = True
                continue
            if kind == "reroll":
                text = REROLL_CONTENT_TEXT
            else:
                text = str(turn.get("text") or REROLL_CONTENT_TEXT).strip()
            append_content("user", [_text_part(types, text)])
        elif role == "model":
            text = _model_turn_text(turn)
            if text:
                append_content("model", [_text_part(types, text)])

    if not used_capture_images:
        contents.insert(
            0,
            types.Content(
                role="user",
                parts=image_parts + [_text_part(types, MODEL_CONTENT_TEXT)],
            ),
        )
    return contents


def _generate_config(types: Any, settings: dict[str, Any], prompt_text: str) -> Any:
    model = settings.get("model", "")
    max_tokens = max_output_tokens_for_model(model) or settings["max_output_tokens"]
    config_kwargs = dict(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=max_tokens,
        media_resolution=media_resolution_for_model(model, settings["media_resolution"]),
        response_mime_type="application/json",
        response_schema=_schema(),
    )
    override = settings.get("thinking_level")
    if isinstance(override, str) and override and _is_thinking_model(model):
        level: str | None = override
    else:
        level = thinking_level_for_model(model)
    if level is not None:
        config_kwargs["thinking_config"] = types.ThinkingConfig(thinking_level=level)
    return types.GenerateContentConfig(**config_kwargs)


def generate_tldr_and_suggestions(
    client: Any,
    settings: dict[str, Any],
    prompt_text: str,
    images: list[tuple[bytes, str]] | None = None,
    image_bytes: bytes | None = None,
    mime_type: str = "image/png",
    conversation_turns: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    from google.genai import types

    contents = _conversation_contents(types, images, image_bytes, mime_type, conversation_turns)
    if not contents:
        raise ValueError("No screenshot was provided.")

    config = _generate_config(types, settings, prompt_text)

    started = time.perf_counter()
    response = client.models.generate_content(
        model=settings["model"],
        contents=contents,
        config=config,
    )
    finished = time.perf_counter()

    raw_text = (response.text or "").strip()
    parsed, parse_error = _parse_json_response(raw_text)
    usage = plain_data(getattr(response, "usage_metadata", None))
    payload: dict[str, Any] = {
        "raw": raw_text,
        "usage": usage,
        "thoughts_token_count": usage_thoughts_token_count(usage),
        "duration_ms": int(round((finished - started) * 1000)),
        "parse_error": parse_error,
        "model": settings["model"],
    }
    if parsed is None:
        payload.update(
            {
                "status": "parse_error",
                "tldr": "Gemini returned non-JSON output.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload

    tldr, suggestions, suggestion_details = _normalize_payload(parsed)
    if len(suggestions) != 3:
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": tldr or "Gemini returned an incomplete response.",
                "suggestions": suggestions or [raw_text or "[empty response]"],
            }
        )
        return payload

    payload.update(
        {
            "status": "ok",
            "schema_version": RESPONSE_SCHEMA_VERSION,
            "tldr": tldr,
            "suggestions": suggestions,
            "suggestion_details": suggestion_details,
        }
    )
    return payload


def generate_tldr_and_suggestions_streaming(
    client: Any,
    settings: dict[str, Any],
    prompt_text: str,
    images: list[tuple[bytes, str]] | None = None,
    image_bytes: bytes | None = None,
    mime_type: str = "image/png",
    conversation_turns: list[dict[str, Any]] | None = None,
) -> Iterator[dict[str, Any]]:
    from google.genai import types

    contents = _conversation_contents(types, images, image_bytes, mime_type, conversation_turns)
    if not contents:
        raise ValueError("No screenshot was provided.")

    config = _generate_config(types, settings, prompt_text)
    started = time.perf_counter()
    raw_text = ""
    usage = None
    last_partial = ""
    last_partial_suggestions: list[str] = []
    for chunk in client.models.generate_content_stream(
        model=settings["model"],
        contents=contents,
        config=config,
    ):
        text = getattr(chunk, "text", None) or ""
        if text:
            raw_text += text
            partial = extract_partial_tldr(raw_text)
            if partial and partial != last_partial:
                last_partial = partial
                yield {"event": "partial_tldr", "data": {"tldr": partial}}
            partial_suggestions = extract_partial_suggestions(raw_text)
            if partial_suggestions and partial_suggestions != last_partial_suggestions:
                last_partial_suggestions = list(partial_suggestions)
                yield {
                    "event": "partial_suggestions",
                    "data": {"suggestions": partial_suggestions},
                }
        chunk_usage = getattr(chunk, "usage_metadata", None)
        if chunk_usage is not None:
            usage = chunk_usage

    duration_ms = int(round((time.perf_counter() - started) * 1000))
    raw_final = raw_text.strip()
    parsed, parse_error = _parse_json_response(raw_final)
    usage_dict = plain_data(usage)
    final: dict[str, Any] = {
        "raw": raw_final,
        "usage": usage_dict,
        "thoughts_token_count": usage_thoughts_token_count(usage_dict),
        "duration_ms": duration_ms,
        "parse_error": parse_error,
        "model": settings["model"],
    }
    if parsed is None:
        final.update(
            {
                "status": "parse_error",
                "tldr": "Gemini returned non-JSON output.",
                "suggestions": [raw_final or "[empty response]"],
            }
        )
    else:
        tldr, suggestions, suggestion_details = _normalize_payload(parsed)
        if len(suggestions) != 3:
            final.update(
                {
                    "status": "schema_mismatch",
                    "tldr": tldr or "Gemini returned an incomplete response.",
                    "suggestions": suggestions or [raw_final or "[empty response]"],
                }
            )
        else:
            final.update(
                {
                    "status": "ok",
                    "schema_version": RESPONSE_SCHEMA_VERSION,
                    "tldr": tldr,
                    "suggestions": suggestions,
                    "suggestion_details": suggestion_details,
                }
            )
    yield {"event": "final", "data": final}
