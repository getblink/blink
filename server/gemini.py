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

_FOR_DESCRIBE_FILE: dict[str, Any] = {
    **DEFAULT_SETTINGS,
    "temperature": 0.4,
    "max_output_tokens": 128,
    "thinking_level": "low",
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
FOLLOW_UP_INSTRUCTION_MAX_CHARS = 500
FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT = 4
# Mirror of blink_once: same-post follow-ups stay valid longer than
# cross-post-same-app ones, and cross-bundle is dropped at scope time on
# the client. The outer hard cap is the same-post window.
FOLLOW_UP_SAME_POST_WINDOW_SECONDS = 30 * 60
FOLLOW_UP_OTHER_SURFACE_WINDOW_SECONDS = 10 * 60
FOLLOW_UP_INSTRUCTION_HISTORY_WINDOW_SECONDS = FOLLOW_UP_SAME_POST_WINDOW_SECONDS
# Mirror of blink_once: TL;DRs in follow-up history can be multi-beat so the
# bound is generous compared to PREFERENCE_TEXT_MAX_CHARS.
FOLLOW_UP_HISTORY_TLDR_MAX_CHARS = 1024
FOLLOW_UP_HISTORY_SUGGESTION_MAX_CHARS = 500
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


def _format_relative_time(age_seconds: Any) -> str:
    try:
        seconds = int(age_seconds)
    except (TypeError, ValueError):
        return "recently"
    if seconds < 0:
        return "just now"
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


_FOLLOW_UP_SCOPE_LABELS = {
    "same_post": "same post",
    "same_window": "different post, same window",
    "same_app": "different surface, same app",
}


def _follow_up_history_lines(history: Any) -> list[str]:
    if not isinstance(history, list):
        return []
    lines: list[str] = []
    for item in history[:FOLLOW_UP_INSTRUCTION_HISTORY_LIMIT]:
        if not isinstance(item, dict):
            continue
        instruction = _bounded_text(item.get("instruction"), FOLLOW_UP_INSTRUCTION_MAX_CHARS)
        if not instruction:
            continue
        relative = _format_relative_time(item.get("age_seconds"))
        app_label = _bounded_text(item.get("app_name"), 80) or _bounded_text(item.get("app_bundle_id"), 80)
        scope_label = _FOLLOW_UP_SCOPE_LABELS.get(str(item.get("scope") or ""))
        prefix = f"[{scope_label}] " if scope_label else ""
        if app_label and scope_label != "same post":
            lines.append(f'- {prefix}{relative}, in {app_label}: "{instruction}"')
        else:
            lines.append(f'- {prefix}{relative}: "{instruction}"')
    return lines


def style_block(style: dict[str, Any] | None) -> str:
    if not isinstance(style, dict):
        return ""
    lines: list[str] = ["<style_preferences>"]
    body_count = 0
    for knob in STYLE_KNOB_ORDER:
        value = str(style.get(knob) or "").strip().lower()
        instruction = STYLE_KNOB_INSTRUCTIONS.get(knob, {}).get(value)
        if instruction:
            lines.append(f"- {instruction}")
            body_count += 1
    about_me = str(style.get("about_me") or "").strip()
    if about_me:
        about_me = about_me[:STYLE_ABOUT_ME_MAX_CHARS]
        lines.append(f"- About the user: {about_me}")
        body_count += 1
    if body_count == 0:
        return ""
    lines.append("</style_preferences>")
    return "\n".join(lines)


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


def _render_follow_up_turn(index: int, turn: dict[str, Any]) -> str:
    sugg_xml = "".join(f"<suggestion>{s}</suggestion>" for s in turn.get("suggestions", []))
    return (
        f'<turn index="{index}"><instruction>{turn["instruction"]}</instruction>'
        f"<tldr>{turn['tldr']}</tldr><suggestions>{sugg_xml}</suggestions></turn>"
    )


def _bounded_follow_up_turns(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, list):
        return []
    result = []
    for turn in raw:
        if not isinstance(turn, dict):
            continue
        instruction = _bounded_text(turn.get("instruction"), FOLLOW_UP_INSTRUCTION_MAX_CHARS) or ""
        tldr = _bounded_text(turn.get("tldr"), FOLLOW_UP_HISTORY_TLDR_MAX_CHARS) or ""
        raw_suggs = turn.get("suggestions")
        suggestions = [
            text
            for text in (
                _bounded_text(item, FOLLOW_UP_HISTORY_SUGGESTION_MAX_CHARS)
                for item in (raw_suggs if isinstance(raw_suggs, list) else [])
            )
            if text
        ][:3]
        if instruction or tldr or suggestions:
            result.append({"instruction": instruction, "tldr": tldr, "suggestions": suggestions})
    return result


def reroll_content_text(follow_up_instruction: Any = None) -> str:
    instruction = _bounded_text(follow_up_instruction, FOLLOW_UP_INSTRUCTION_MAX_CHARS)
    if not instruction:
        return REROLL_CONTENT_TEXT
    return (
        f"{REROLL_CONTENT_TEXT}\n\n"
        "User follow-up instruction:\n"
        f"{instruction}\n"
        "Apply this instruction while still using only visible evidence."
    )


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
    follow_up_history_lines = _follow_up_history_lines(stateful_context.get("recent_follow_up_instructions"))
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
    follow_up_instruction = _bounded_text(
        reroll_context.get("follow_up_instruction"),
        FOLLOW_UP_INSTRUCTION_MAX_CHARS,
    )
    follow_up_turns = _bounded_follow_up_turns(reroll_context.get("follow_up_history"))
    style_text = style_block(style)
    if (
        not voice_samples
        and not preference_examples
        and not surface_history
        and not previous_suggestion_texts
        and not style_text
        and not follow_up_instruction
        and not follow_up_history_lines
        and not follow_up_turns
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
    blocks: list[str] = []
    if style_text:
        blocks.append(style_text)
    if follow_up_history_lines:
        block_lines = [
            "<recent_follow_up_guidance>",
            "Apply per suggestion rule 7.",
        ]
        block_lines.extend(follow_up_history_lines)
        block_lines.append("</recent_follow_up_guidance>")
        blocks.append("\n".join(block_lines))
    if has_stateful_context:
        block_lines = [
            "<stateful_context>",
            "Use user preference examples in <preference_examples> to infer which suggestions are useful in this surface.",
            "User voice examples in <voice_examples> are samples of how this user actually writes. Imitate their style closely in the suggestions: casing, punctuation, contractions, sentence shape, vocabulary, hedging, emoji habits. The 'do not copy facts' rule applies: if a voice sample mentions a name, fact, or commitment that isn't on the current screen, don't carry it over. The current capture's tone wins when it conflicts with older voice (for example, a formal escalation overrides a casual chat tic).",
            "Use the entries in <recent_surface_history> only for continuity in this immediate thread. Current screen evidence wins.",
            "</stateful_context>",
        ]
        blocks.append("\n".join(block_lines))
    if previous_suggestion_texts:
        block_lines = ["<reroll_instructions>"]
        if follow_up_turns:
            block_lines.append("<follow_up_history>")
            for idx, turn in enumerate(follow_up_turns, start=1):
                block_lines.append(_render_follow_up_turn(idx, turn))
            block_lines.append("</follow_up_history>")
        if follow_up_instruction:
            block_lines.extend(
                [
                    f"<follow_up_instruction>{follow_up_instruction}</follow_up_instruction>",
                    "Apply this instruction to the new suggestions while still using only visible evidence.",
                ]
            )
        block_lines.append(
            "The user asked for a fresh set of suggestions for the same capture. Use the same visible evidence, but avoid repeating these previous suggestions unless one is clearly the only correct answer:"
        )
        for suggestion in previous_suggestion_texts:
            block_lines.append(f"- {suggestion}")
        block_lines.append("</reroll_instructions>")
        blocks.append("\n".join(block_lines))
    elif follow_up_instruction or follow_up_turns:
        block_lines = ["<reroll_instructions>"]
        if follow_up_turns:
            block_lines.append("<follow_up_history>")
            for idx, turn in enumerate(follow_up_turns, start=1):
                block_lines.append(_render_follow_up_turn(idx, turn))
            block_lines.append("</follow_up_history>")
        if follow_up_instruction:
            block_lines.extend(
                [
                    f"<follow_up_instruction>{follow_up_instruction}</follow_up_instruction>",
                    "Apply this instruction to a fresh set of suggestions for the same capture while still using only visible evidence.",
                ]
            )
        block_lines.append("</reroll_instructions>")
        blocks.append("\n".join(block_lines))
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
            blocks.append(
                "<preference_examples>\n"
                f'Last time, the user typed "{user_typed}" instead of the model\'s suggestions.\n'
                "</preference_examples>"
            )
        elif valid_pref_examples:
            block_lines = [
                "<preference_examples>",
                "These show cases where model suggestions were not useful enough and the user typed their own reply instead.",
                "These are individual data points, not a pattern. Don't extrapolate a stance or verb shape from a single example; at most they tell you the user wanted something more specific than what was offered.",
            ]
            for index, (example, user_typed, rejected_texts) in enumerate(valid_pref_examples, start=1):
                screen_takeaway = _bounded_text(example.get("screen_takeaway"), PREFERENCE_TEXT_MAX_CHARS)
                block_lines.append(f'<example index="{index}">')
                if screen_takeaway:
                    block_lines.append(f"Screen takeaway: {screen_takeaway}")
                block_lines.append("Model suggestions the user did not use:")
                for suggestion in rejected_texts:
                    block_lines.append(f"- {suggestion}")
                block_lines.append(f"User typed instead: {user_typed}")
                block_lines.append("</example>")
            block_lines.append("</preference_examples>")
            blocks.append("\n".join(block_lines))
    if voice_samples:
        rendered_voice_samples = []
        for sample in voice_samples:
            if not isinstance(sample, dict):
                continue
            text = _bounded_text(sample.get("text"), VOICE_SAMPLE_MAX_CHARS)
            if text and text not in preference_texts:
                rendered_voice_samples.append(text)
        if rendered_voice_samples:
            block_lines = ["<voice_examples>"]
            for text in rendered_voice_samples:
                block_lines.append(f"- {text}")
            block_lines.append("</voice_examples>")
            blocks.append("\n".join(block_lines))
    if surface_history:
        block_lines = ["<recent_surface_history>"]
        body_added = False
        for item in surface_history:
            if not isinstance(item, dict):
                continue
            tldr = _bounded_text(item.get("tldr"), SURFACE_TEXT_MAX_CHARS)
            custom_reply = _bounded_text(item.get("custom_reply_text"), SURFACE_TEXT_MAX_CHARS)
            chosen_text = _bounded_text(item.get("chosen_text"), SURFACE_TEXT_MAX_CHARS)
            chosen_action = _bounded_text(item.get("chosen_action"), 80)
            chosen_index = item.get("chosen_index")
            if tldr:
                block_lines.append(f"- Prior summary: {tldr}")
                body_added = True
            if custom_reply:
                if custom_reply in preference_texts:
                    block_lines.append("  Prior outcome: user typed a custom reply instead of using the suggestions.")
                else:
                    block_lines.append(f"  Prior outcome: {custom_reply}")
                body_added = True
            elif chosen_text:
                index_text = f" #{chosen_index + 1}" if isinstance(chosen_index, int) else ""
                action_text = chosen_action or "used"
                block_lines.append(
                    f"  Prior outcome: user {action_text} model suggestion{index_text}; "
                    "do not copy that prior model-authored wording into new suggestions."
                )
                body_added = True
        if body_added:
            block_lines.append("</recent_surface_history>")
            blocks.append("\n".join(block_lines))
    if not blocks:
        return prompt_text
    return prompt_text.rstrip() + "\n\n" + "\n\n".join(blocks) + "\n"


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


def create_client(api_key: str | None, settings: dict[str, Any] | None = None) -> Any:
    from google import genai
    from google.genai import types

    timeout_ms = int((settings or _FOR_DESCRIBE_FILE)["timeout_seconds"] * 1000)
    return genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(timeout=timeout_ms),
    )


def response_schema_contract(supports_attachments: bool = False, is_followup: bool = False) -> dict[str, Any]:
    suggestion_properties: dict[str, Any] = {
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
    }
    suggestion_required = ["text", "tags"]
    suggestion_ordering = ["text", "tags"]
    if supports_attachments:
        suggestion_properties["attachments"] = {
            "type": "array",
            "default": [],
            "items": {
                "type": "object",
                "required": ["id", "reason"],
                "properties": {
                    "id": {"type": "string"},
                    "reason": {"type": "string", "maxLength": 80},
                },
            },
        }
        suggestion_ordering = ["text", "tags", "attachments"]
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
                "min_items": 0 if is_followup else 3,
                "max_items": 3,
                "items": {
                    "type": "object",
                    "required": suggestion_required,
                    "property_ordering": suggestion_ordering,
                    "properties": suggestion_properties,
                },
            },
        },
    }


def _schema(supports_attachments: bool = False, is_followup: bool = False) -> types.Schema:
    from google.genai import types

    contract = response_schema_contract(supports_attachments=supports_attachments, is_followup=is_followup)
    suggestion_item_contract = contract["properties"]["suggestions"]["items"]
    suggestion_required = suggestion_item_contract["required"]
    suggestion_ordering = suggestion_item_contract["property_ordering"]

    suggestion_properties: dict[str, Any] = {
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
    }
    if supports_attachments:
        suggestion_properties["attachments"] = types.Schema(
            type=types.Type.ARRAY,
            items=types.Schema(
                type=types.Type.OBJECT,
                required=["id", "reason"],
                properties={
                    "id": types.Schema(type=types.Type.STRING),
                    "reason": types.Schema(type=types.Type.STRING, maxLength=80),
                },
            ),
        )

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
                minItems=0 if is_followup else 3,
                maxItems=3,
                items=types.Schema(
                    type=types.Type.OBJECT,
                    required=suggestion_required,
                    propertyOrdering=suggestion_ordering,
                    properties=suggestion_properties,
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
        attachments: list[dict[str, str]] = []
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
            raw_attachments = item.get("attachments")
            if isinstance(raw_attachments, list):
                for attachment in raw_attachments:
                    if not isinstance(attachment, dict):
                        continue
                    att_id = str(attachment.get("id") or "").strip()
                    att_reason = str(attachment.get("reason") or "").strip()
                    if att_id and att_reason:
                        attachments.append({"id": att_id, "reason": att_reason[:80]})
        else:
            text = str(item or "").strip()
            tags = []
        if text:
            if not tags:
                tags = fallback_suggestion_tags(text, len(details))
            entry: dict[str, Any] = {"text": text, "tags": tags}
            if attachments:
                entry["attachments"] = attachments
            details.append(entry)
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


def usage_cached_tokens(usage: Any) -> int | None:
    """Pull `cached_content_token_count` out of Gemini's usage metadata.

    Nonzero means Gemini's implicit (or explicit) prefix cache hit on this
    request — that portion was billed at 25% input rate and skipped re-encoding
    on the inference side. Lets us observe whether the system_instruction
    portion of our prompt is being auto-cached without us configuring anything.
    """
    if not isinstance(usage, dict):
        return None
    for key in ("cached_content_token_count", "cachedContentTokenCount", "cached_tokens"):
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


def _capture_text(user_message_suffix: str = "") -> str:
    """Text part that accompanies the screenshot in the user-role capture
    turn. The selection block (when present) lives here, not in the system
    instruction, because it's ephemeral per-request input — the user's
    explicit "act on this" payload — not stable rules."""
    if user_message_suffix:
        return MODEL_CONTENT_TEXT + "\n\n" + user_message_suffix
    return MODEL_CONTENT_TEXT


def _conversation_contents(
    types: Any,
    images: list[tuple[bytes, str]] | None,
    image_bytes: bytes | None,
    mime_type: str,
    conversation_turns: list[dict[str, Any]] | None,
    user_message_suffix: str = "",
) -> list[Any]:
    image_parts = _image_contents(types, images, image_bytes, mime_type)
    if not image_parts:
        return []
    capture_text = _capture_text(user_message_suffix)
    if not conversation_turns:
        return [
            types.Content(
                role="user",
                parts=image_parts + [_text_part(types, capture_text)],
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
                    image_parts + [_text_part(types, capture_text)],
                )
                used_capture_images = True
                continue
            if kind == "reroll":
                text = reroll_content_text(turn.get("follow_up_instruction"))
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
                parts=image_parts + [_text_part(types, capture_text)],
            ),
        )
    return contents


def _generate_config(types: Any, settings: dict[str, Any], prompt_text: str, is_followup: bool = False) -> Any:
    model = settings.get("model", "")
    max_tokens = max_output_tokens_for_model(model) or settings["max_output_tokens"]
    supports_attachments = bool(settings.get("supports_attachments", False))
    config_kwargs = dict(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=max_tokens,
        media_resolution=media_resolution_for_model(model, settings["media_resolution"]),
        response_mime_type="application/json",
        response_schema=_schema(supports_attachments=supports_attachments, is_followup=is_followup),
    )
    override = settings.get("thinking_level")
    if isinstance(override, str) and override == "off" and _is_thinking_model(model):
        # latency-replay C8 experiment: disable thinking via budget=0.
        config_kwargs["thinking_config"] = types.ThinkingConfig(thinking_budget=0)
        return types.GenerateContentConfig(**config_kwargs)
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
    supports_attachments: bool = False,
    user_message_suffix: str = "",
    is_followup: bool = False,
) -> dict[str, Any]:
    from google.genai import types

    contents = _conversation_contents(
        types,
        images,
        image_bytes,
        mime_type,
        conversation_turns,
        user_message_suffix=user_message_suffix,
    )
    if not contents:
        raise ValueError("No screenshot was provided.")

    config = _generate_config(types, settings, prompt_text, is_followup=is_followup)

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
    if is_followup and len(suggestions) == 0:
        payload.update(
            {
                "status": "ok",
                "schema_version": RESPONSE_SCHEMA_VERSION,
                "tldr": tldr,
                "suggestions": [],
                "suggestion_details": [],
                "suggestions_unchanged": True,
            }
        )
        return payload
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


def generate_file_description(client: Any, file_data: bytes, mime_type: str, kind: str) -> str:
    """Call Gemini with a file and return a one-sentence description."""
    from google.genai import types

    prompt = (
        "In one sentence, describe what this file is and when it would be useful to attach to an email. "
        "Be concrete. Examples: "
        "'Professional headshot, vertical orientation, suitable for press features.' / "
        "'Q1 2026 sponsored-post rate card with UGC pricing.'"
    )
    settings = _FOR_DESCRIBE_FILE.copy()
    model = settings.pop("model")
    timeout_s = settings.pop("timeout_seconds", 120)
    # Remove keys the SDK doesn't accept in generate_content config
    settings.pop("media_resolution", None)
    thinking_level = settings.pop("thinking_level", "low")

    contents = [
        types.Part.from_bytes(data=file_data, mime_type=mime_type),
        types.Part.from_text(text=prompt),
    ]
    config = types.GenerateContentConfig(
        temperature=settings.get("temperature", 0.4),
        max_output_tokens=settings.get("max_output_tokens", 128),
        thinking_config=types.ThinkingConfig(thinking_budget=0 if thinking_level == "low" else None),
        http_options=types.HttpOptions(timeout=int(timeout_s * 1000)),
    )
    response = client.models.generate_content(
        model=model,
        contents=contents,
        config=config,
    )
    text = (response.text or "").strip()
    # Trim to 200 chars as a hard safety cap
    return text[:200]


def generate_tldr_and_suggestions_streaming(
    client: Any,
    settings: dict[str, Any],
    prompt_text: str,
    images: list[tuple[bytes, str]] | None = None,
    image_bytes: bytes | None = None,
    mime_type: str = "image/png",
    conversation_turns: list[dict[str, Any]] | None = None,
    user_message_suffix: str = "",
    is_followup: bool = False,
) -> Iterator[dict[str, Any]]:
    from google.genai import types

    contents = _conversation_contents(
        types,
        images,
        image_bytes,
        mime_type,
        conversation_turns,
        user_message_suffix=user_message_suffix,
    )
    if not contents:
        raise ValueError("No screenshot was provided.")

    config = _generate_config(types, settings, prompt_text, is_followup=is_followup)
    started = time.perf_counter()
    first_chunk_at: float | None = None
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
            if first_chunk_at is None:
                first_chunk_at = time.perf_counter()
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

    finished = time.perf_counter()
    duration_ms = int(round((finished - started) * 1000))
    ttft_ms = (
        int(round((first_chunk_at - started) * 1000))
        if first_chunk_at is not None
        else None
    )
    stream_ms = (
        int(round((finished - first_chunk_at) * 1000))
        if first_chunk_at is not None
        else None
    )
    raw_final = raw_text.strip()
    parsed, parse_error = _parse_json_response(raw_final)
    usage_dict = plain_data(usage)
    final: dict[str, Any] = {
        "raw": raw_final,
        "usage": usage_dict,
        "thoughts_token_count": usage_thoughts_token_count(usage_dict),
        "cached_tokens": usage_cached_tokens(usage_dict),
        "duration_ms": duration_ms,
        "ttft_ms": ttft_ms,
        "stream_ms": stream_ms,
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
        if is_followup and len(suggestions) == 0:
            final.update(
                {
                    "status": "ok",
                    "schema_version": RESPONSE_SCHEMA_VERSION,
                    "tldr": tldr,
                    "suggestions": [],
                    "suggestion_details": [],
                    "suggestions_unchanged": True,
                }
            )
        elif len(suggestions) != 3:
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


# -----------------------------------------------------------------------------
# Tag-delimited output mode (experiment).
#
# Same conversation/system prompt shape, but the model emits its response as
# <tldr>…</tldr><suggestion tags="…">…</suggestion> blocks instead of JSON.
# Goal: shorter output (no JSON escaping or schema-mode overhead) and earlier
# usable streaming (a closed <tldr> tag is immediately renderable).
# -----------------------------------------------------------------------------

_TAG_OUTPUT_FORMAT_BLOCK = """<output_format>
IGNORE the JSON shape shown in the <worked_example> above. Your output MUST use XML-style tags as described here, not JSON.

The first non-whitespace character of your response MUST be the literal text `<tldr>`.

Use exactly this structure, in this order:

<tldr>
Headline here.

Supporting beat or Heads up here.
</tldr>
<suggestion tags="Reply">
Paste-ready text
</suggestion>
<suggestion tags="Reply">
Paste-ready text
</suggestion>
<suggestion tags="Reply">
Paste-ready text
</suggestion>

Rules:
- Exactly one <tldr> and exactly three <suggestion> blocks.
- The `tags="..."` attribute carries 1-2 short labels (e.g. "Reply", "Ask", "Next step", "Pitch", "Insight"), comma-separated, joined with a comma and a single space.
- Text inside tags is the literal value: no JSON quotes, no JSON escaping. Newlines inside <tldr> are real newlines, not `\\n`.
- No prose, attributes, or other tags outside the four listed above. No XML declaration, no wrapper element.
- If you would normally include `attachments` on a suggestion, add an extra attribute `attachments="id1:reason,id2:reason"` on the <suggestion> tag, comma-separated, with each entry as `id:reason`. Omit the attribute when there are no attachments.
</output_format>"""

_OUTPUT_FORMAT_PATTERN = re.compile(r"<output_format>.*?</output_format>", re.DOTALL)


def substitute_output_format_for_tags(prompt_text: str) -> str:
    """Replace the JSON <output_format>...</output_format> block with the tag-mode block."""
    new_prompt, count = _OUTPUT_FORMAT_PATTERN.subn(_TAG_OUTPUT_FORMAT_BLOCK, prompt_text, count=1)
    if count == 0:
        # Prompt didn't carry an output_format block; append the tag block.
        return prompt_text.rstrip() + "\n\n" + _TAG_OUTPUT_FORMAT_BLOCK
    return new_prompt


_TAG_TLDR_CLOSED = re.compile(r"<tldr>(.*?)</tldr>", re.DOTALL)
_TAG_TLDR_OPEN = re.compile(r"<tldr>(.*)", re.DOTALL)
# Suggestion with optional `tags="…"` and optional `attachments="…"` attributes,
# in either order.
_TAG_SUG_ATTRS = r"""(?:\s+tags="(?P<tags>[^"]*)")?(?:\s+attachments="(?P<attachments>[^"]*)")?(?:\s+tags="(?P<tags2>[^"]*)")?"""
_TAG_SUG_CLOSED = re.compile(rf"<suggestion{_TAG_SUG_ATTRS}\s*>(?P<body>.*?)</suggestion>", re.DOTALL)
_TAG_SUG_OPEN = re.compile(rf"<suggestion{_TAG_SUG_ATTRS}\s*>(?P<body>(?!.*</suggestion>).*)", re.DOTALL)


def extract_partial_tldr_tags(raw_text: str) -> str | None:
    """Return the body of <tldr>…</tldr> if closed, else the open body so far.

    Strips any partially-emitted trailing tag (e.g. `<sugges`) so the user
    sees clean text mid-stream.
    """
    m = _TAG_TLDR_CLOSED.search(raw_text)
    if m:
        return m.group(1).strip() or None
    m = _TAG_TLDR_OPEN.search(raw_text)
    if not m:
        return None
    body = m.group(1)
    # Drop any text after the first `<` since it may be a partial tag.
    cut = body.find("<")
    if cut >= 0:
        body = body[:cut]
    body = body.strip()
    return body or None


def _parse_attachments_attr(raw: str) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    if not raw:
        return out
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        if ":" in piece:
            ident, _, reason = piece.partition(":")
            out.append({"id": ident.strip(), "reason": reason.strip()[:80]})
        else:
            out.append({"id": piece.strip(), "reason": ""})
    return out


def extract_partial_suggestions_tags(raw_text: str) -> list[dict[str, Any]]:
    """Return list of {text, tags, attachments?} for all closed (and trailing
    open) <suggestion> blocks. Streaming-safe."""
    results: list[dict[str, Any]] = []
    last_end = 0
    for m in _TAG_SUG_CLOSED.finditer(raw_text):
        tags_str = m.group("tags") or m.group("tags2") or ""
        attachments_str = m.group("attachments") or ""
        tags = [t.strip() for t in tags_str.split(",") if t.strip()]
        text = m.group("body").strip()
        item: dict[str, Any] = {"text": text, "tags": tags}
        attachments = _parse_attachments_attr(attachments_str)
        if attachments:
            item["attachments"] = attachments
        results.append(item)
        last_end = m.end()
    # Trailer: an open <suggestion> that hasn't been closed yet.
    tail = raw_text[last_end:]
    om = _TAG_SUG_OPEN.search(tail)
    if om and "</suggestion>" not in om.group(0):
        tags_str = om.group("tags") or om.group("tags2") or ""
        body = om.group("body")
        cut = body.find("<")
        if cut >= 0:
            body = body[:cut]
        body = body.strip()
        if body:
            tags = [t.strip() for t in tags_str.split(",") if t.strip()]
            results.append({"text": body, "tags": tags})
    return results


def _generate_config_tags(types: Any, settings: dict[str, Any], prompt_text: str) -> Any:
    """Like _generate_config but for tag-delimited text output.

    Drops `response_mime_type=application/json` and `response_schema` (model
    emits plain text); keeps everything else identical (temperature,
    max_output_tokens, media_resolution, thinking_config).
    """
    model = settings.get("model", "")
    max_tokens = max_output_tokens_for_model(model) or settings["max_output_tokens"]
    config_kwargs: dict[str, Any] = dict(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=max_tokens,
        media_resolution=media_resolution_for_model(model, settings["media_resolution"]),
    )
    override = settings.get("thinking_level")
    if isinstance(override, str) and override == "off" and _is_thinking_model(model):
        config_kwargs["thinking_config"] = types.ThinkingConfig(thinking_budget=0)
        return types.GenerateContentConfig(**config_kwargs)
    if isinstance(override, str) and override and _is_thinking_model(model):
        level: str | None = override
    else:
        level = thinking_level_for_model(model)
    if level is not None:
        config_kwargs["thinking_config"] = types.ThinkingConfig(thinking_level=level)
    return types.GenerateContentConfig(**config_kwargs)


def generate_tldr_and_suggestions_streaming_tags(
    client: Any,
    settings: dict[str, Any],
    prompt_text: str,
    images: list[tuple[bytes, str]] | None = None,
    image_bytes: bytes | None = None,
    mime_type: str = "image/png",
    conversation_turns: list[dict[str, Any]] | None = None,
    user_message_suffix: str = "",
) -> Iterator[dict[str, Any]]:
    """Tag-mode mirror of generate_tldr_and_suggestions_streaming.

    Emits the same SSE event names (`partial_tldr`, `partial_suggestions`,
    `final`) so the client and server SSE plumbing don't need to know.
    """
    from google.genai import types

    contents = _conversation_contents(
        types,
        images,
        image_bytes,
        mime_type,
        conversation_turns,
        user_message_suffix=user_message_suffix,
    )
    if not contents:
        raise ValueError("No screenshot was provided.")

    config = _generate_config_tags(types, settings, prompt_text)
    started = time.perf_counter()
    first_chunk_at: float | None = None
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
            if first_chunk_at is None:
                first_chunk_at = time.perf_counter()
            raw_text += text
            partial = extract_partial_tldr_tags(raw_text)
            if partial and partial != last_partial:
                last_partial = partial
                yield {"event": "partial_tldr", "data": {"tldr": partial}}
            partial_items = extract_partial_suggestions_tags(raw_text)
            partial_strings = [item["text"] for item in partial_items if item.get("text")]
            if partial_strings and partial_strings != last_partial_suggestions:
                last_partial_suggestions = list(partial_strings)
                yield {
                    "event": "partial_suggestions",
                    "data": {"suggestions": partial_strings},
                }
        chunk_usage = getattr(chunk, "usage_metadata", None)
        if chunk_usage is not None:
            usage = chunk_usage

    finished = time.perf_counter()
    duration_ms = int(round((finished - started) * 1000))
    ttft_ms = (
        int(round((first_chunk_at - started) * 1000))
        if first_chunk_at is not None
        else None
    )
    stream_ms = (
        int(round((finished - first_chunk_at) * 1000))
        if first_chunk_at is not None
        else None
    )
    raw_final = raw_text.strip()
    usage_dict = plain_data(usage)

    # Final parse: harvest closed tags only (no trailing open block).
    closed_items = []
    for m in _TAG_SUG_CLOSED.finditer(raw_final):
        tags_str = m.group("tags") or m.group("tags2") or ""
        attachments_str = m.group("attachments") or ""
        text = m.group("body").strip()
        tags = [t.strip() for t in tags_str.split(",") if t.strip()]
        attachments = _parse_attachments_attr(attachments_str)
        item: dict[str, Any] = {"text": text, "tags": tags}
        if attachments:
            item["attachments"] = attachments
        closed_items.append(item)
    tldr_match = _TAG_TLDR_CLOSED.search(raw_final)
    tldr_text = (tldr_match.group(1).strip() if tldr_match else "").strip()

    final: dict[str, Any] = {
        "raw": raw_final,
        "usage": usage_dict,
        "thoughts_token_count": usage_thoughts_token_count(usage_dict),
        "cached_tokens": usage_cached_tokens(usage_dict),
        "duration_ms": duration_ms,
        "ttft_ms": ttft_ms,
        "stream_ms": stream_ms,
        "parse_error": None,
        "model": settings["model"],
        "output_format": "tags",
    }

    if not tldr_text and not closed_items:
        final.update(
            {
                "status": "parse_error",
                "tldr": "Gemini returned no recognizable tags.",
                "suggestions": [raw_final or "[empty response]"],
                "parse_error": "no_tags_found",
            }
        )
    elif len(closed_items) != 3:
        final.update(
            {
                "status": "schema_mismatch",
                "tldr": tldr_text or "Gemini returned an incomplete response.",
                "suggestions": [item["text"] for item in closed_items]
                or [raw_final or "[empty response]"],
                "parse_error": f"expected_3_suggestions_got_{len(closed_items)}",
            }
        )
    else:
        final.update(
            {
                "status": "ok",
                "schema_version": RESPONSE_SCHEMA_VERSION,
                "tldr": tldr_text,
                "suggestions": [item["text"] for item in closed_items],
                "suggestion_details": closed_items,
            }
        )
    yield {"event": "final", "data": final}
