#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import traceback
from urllib import error, parse, request
from uuid import uuid4
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from env_loader import load_runtime_env
from image_prep import prepare_request_image


DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3-flash-preview",
    "temperature": 1.0,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "preprocess_request_images": True,
    "request_image_format": "jpeg",
    "request_image_max_dimension": 1600,
    "request_image_jpeg_quality": 70,
    "timeout_seconds": 120,
}


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

    "high" is the Google-documented default for Gemini 3 Flash/Pro. "minimal"
    is avoided: Flash hallucinates its own model name at that level.
    """
    return "high" if _is_thinking_model(model) else None


def max_output_tokens_for_model(model: str) -> int | None:
    """Per-model override for max_output_tokens, or None to honor settings.

    Thinking tokens count against max_output_tokens, so leave headroom for
    THINKING_BUDGET_TOKENS plus a comfortable JSON reply.
    """
    return 2048 if _is_thinking_model(model) else None


def media_resolution_for_model(model: str, base: str) -> str:
    if model == "gemini-3-flash-preview":
        return "MEDIA_RESOLUTION_MEDIUM"
    return base


def build_generate_config(types_module, prompt_text: str, settings: dict[str, Any]):
    model = settings.get("model", "")
    max_tokens = max_output_tokens_for_model(model) or settings["max_output_tokens"]
    media_resolution = media_resolution_for_model(model, settings["media_resolution"])
    kwargs = dict(
        system_instruction=prompt_text,
        temperature=settings["temperature"],
        max_output_tokens=max_tokens,
        media_resolution=media_resolution,
        response_mime_type="application/json",
        response_schema=response_schema(),
    )
    level = thinking_level_for_model(model)
    if level is not None:
        kwargs["thinking_config"] = types_module.ThinkingConfig(thinking_level=level)
    return types_module.GenerateContentConfig(**kwargs)

PROXY_URL_ENV = "BLINK_PROXY_URL"
PROXY_TOKEN_ENV = "BLINK_PROXY_TOKEN"
PROXY_URL_ENV_DEPRECATED = "TLDR_PROXY_URL"
PROXY_TOKEN_ENV_DEPRECATED = "TLDR_PROXY_TOKEN"
DISABLE_PROXY_ENV = "BLINK_DISABLE_PROXY"
DISABLE_PROXY_ENV_DEPRECATED = "TLDR_DISABLE_PROXY"
DEVICE_TOKEN_PATH = Path.home() / ".blink" / "device_token"
MODEL_CONTENT_TEXT = "Summarize this active window and propose three replies."
SERVER_CONTENT_TEXT = MODEL_CONTENT_TEXT

STATEFUL_CONTEXT_VERSION = 1
MAX_SCREENSHOT_FRAMES = 8
VOICE_SAMPLE_LIMIT = 5
SURFACE_HISTORY_LIMIT = 3
PREFERENCE_EXAMPLE_LIMIT = 3
PREFERENCE_REJECTED_SUGGESTION_LIMIT = 3
VOICE_SAMPLE_MAX_CHARS = 500
VOICE_SAMPLE_MIN_CHARS = 15
SURFACE_TEXT_MAX_CHARS = 500
PREFERENCE_TEXT_MAX_CHARS = 360
FOLLOW_UP_INSTRUCTION_MAX_CHARS = 500
SURFACE_CONTEXT_WINDOW_SECONDS = 15 * 60
RESPONSE_SCHEMA_VERSION = 2
SUGGESTION_TAG_LIMIT = 2
SUGGESTION_TAG_MAX_CHARS = 24

STYLE_ABOUT_ME_MAX_CHARS = 2000

# See server/gemini.py for the full rationale. Recent same-surface history
# is suppressed in the rendered prompt while we iterate on the surface
# history architecture (feedback loop, stale-context bias, novelty-test
# breakdown). build_stateful_context still records the data so debug
# telemetry is preserved; only the prompt rendering ignores it.
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


DEFAULT_PROMPT = """You are looking at one or more screenshots of the user's active app. Talk to the user like a friend leaning over their shoulder. Warm, terse, direct.

If multiple screenshots are provided, they show the same window scrolled top to bottom in capture order. Treat them as one continuous page. Adjacent frames will overlap; deduplicate visually rather than summarizing each frame separately.

Global constraints (apply to TL;DR and every suggestion):

- Don't invent. Only assert what is visible on screen. When the screen is dense or ambiguous, hedge: "Looks like...", "Probably...", "Sounds like...". Never overclaim.
- Never use em dashes ("—") or en dashes ("–"). Use a period, comma, semicolon, or a new line instead.
  - Bad: "Sarah's waiting on your estimate — she needs it before 4pm."
  - Bad: "$1,247 invoice due Mar 15 – card on file expired."
  - Good: "Sarah's waiting on your estimate. She needs it before 4pm."
  - Good: "$1,247 invoice due Mar 15. Card on file expired last week."
- Don't mention that you saw a screenshot.

Produce two things, in this order:

1. A TL;DR addressed to the user.
2. Three concrete suggestions: candidate replies, paste-ready phrasings, or next actions the user might send, paste, or do.

TL;DR rules, in priority order (rule 1 beats rule 2 beats rule 3, etc.):

1. Lead with the subject of action. Never start the TL;DR with "You", "You're", "You've", or "Your". Open with the person, system, document, number, or event driving the takeaway. The user can still be addressed as "you" later in the line.
   - Bad: "You're looking at a Slack thread with Sarah."
   - Bad: "You have an invoice due Friday."
   - Bad: "Your migration estimate is due."
   - Good: "Joe's asking if you want dinner tonight; he's flexible on time."
   - Good: "The agent just finished the UI refactor. 3 tests are still red."
   - Good: "Sarah needs your migration estimate before her 4pm sync."
   - Good: "$1,247 Stripe invoice due Mar 15."

2. Quote concrete, load-bearing details. Names, numbers, dates, deadlines, doc titles, dollar amounts, error messages. Specificity beats summary.

3. Surface only signal. Signal is what the user does not already know that changes their next move (a blocker, decision, ask, risk, deadline, name, error, or new fact). Apply the novelty test before including anything: if you just watched the user, or an agent acting on their behalf, produce or witness this fact in the visible session, it is not novel and should not appear in the TL;DR. Recent timestamps and approaching deadlines weight highest. Skip Blink diagnostics, app state, or anything the user obviously already saw. If nothing on screen passes the novelty test, the TL;DR is one short status sentence acknowledging there's nothing new.

4. The user has already seen the screen. Don't recap. App name, current channel, who they're chatting with, what they just typed, what they themselves just did in this session: all already known.

5. Protagonist captures. When the user is the protagonist of the capture (their own coding session, own draft, own outgoing messages dominate), most of what's on screen is already known and the TL;DR shrinks accordingly. Identifiers produced in the visible session (commit hashes, PR numbers, build numbers, file paths, branch names) are noise even though they look like the rule-2 kind of specifics. The user, or an agent acting on their direction, just produced them and was watching. Reference what changed by content, not by hash.

6. If something on screen is clearly inconsistent or worth a sanity check, add a brief "Heads up, ..." clause on its own line, after a blank line. Only when the evidence is visible. Never invent one. Cases that warrant one:
   - A date in a draft contradicts a date earlier in the thread.
   - A name in a draft doesn't match the recipient.
   - Two numbers that should match (subtotal vs line items, two prices, two timestamps) don't.
   - A draft contains a fact the source doesn't support.
   - A deadline conflicts with a commitment elsewhere on screen.
   - A typo or wrong recipient in a draft about to be sent.

7. Voice and reference. Friend voice, not press release. Everyday words; contractions are fine. Avoid corporate filler like "action items", "circle back", "looping in", "just wanted to", "kindly", "as per", "FYI". When referring to the user, use direct second person ("you", "your"); never "the user", "I see that", "this screen shows", "I can see". (Rule 1's "don't lead with You" still holds.)

8. Length scales with signal density, not capture density. One tight headline sentence (≤200 chars) for the single most behavior-changing fact. Add supporting beats only when the capture has multiple distinct load-bearing items that pass the novelty test. The headline must work as the entire TL;DR on its own. 3 sentences or fewer per paragraph. No bullets, no numbered lists in the output itself.

Suggestion rules, in priority order:

1. Produce exactly three suggestions. Each must be ready to paste or send as-is.

2. Sound like the user. The three suggestions should read like the user wrote them. Match their casing, punctuation, contractions, sentence shape, vocabulary, hedging, and emoji/no-emoji style. Draw from any of the user's own prior messages visible in the screenshot AND from the user voice examples below. Lean toward the user's house style when you have multiple consistent voice samples; otherwise prefer neutral phrasing. Do not force shortness when a more complete answer fits the user better.
   Two guards that apply to every suggestion rule below: (a) do not carry names, commitments, numbers, dates, or other facts from voice samples into the reply unless the current screen supports them; voice samples are for style, not content; (b) the current capture's tone wins when it conflicts with older voice (for example, a formal escalation overrides a casual chat tic).

3. Make each suggestion specific to the visible names, question, plan, bug, document, or request. Don't force variety the screen doesn't need; if only one direction is earned, use it across multiple suggestions rather than inventing opposing stances. Avoid generic filler like "Got it, thanks" unless the screenshot truly calls only for a brief acknowledgement.

4. Continue drafts; don't rewrite them. Look for any visible compose box, draft text, selected text, or caret context.
   - If the user has already started typing, suggestions are paste-at-caret continuations or completions, not rewrites that duplicate the existing draft.
   - Do not repeat the existing draft prefix. Continue after the caret.
   - If the draft ends mid-sentence, continue it naturally.
   - If the draft is already a full sentence, suggest text that could follow it.

5. If the screen has no message to reply to, treat suggestions as next actions or paste-ready phrasings appropriate to the surface: a code-review comment, a meeting-decline reason, a draft email, a search query, a commit message.

6. On AI-agent or coding-agent surfaces, suggestions should steer the agent, ask for evidence, request implementation, or push back. Phrase these as requests or directions to the agent ("Can you...", "Please...", "Show me..."), not as the user's own future work. Avoid "I agree...", "I'll test...", or self-referential agent-progress phrasing unless the visible context truly calls for that as the user's message.

For each suggestion, include 1-2 short tags that describe the move at a glance, such as Reply, Ask, Pushback, Next step, Clarify, Evidence, Commit, Defer, or Draft. Tags are labels only; the suggestion text must still be paste-ready by itself.

Worked example: protagonist surface. The user watched an agent finish work in real time. Scratch flags there is no real novelty; the TL;DR collapses to one sentence; the suggestions steer the agent forward rather than narrate user actions:

{"schema_version": 2, "tldr": "Agent shipped the adaptive-length TL;DR plan and is standing by.", "suggestions": [{"text": "open the local Blink overlay on a dense Slack thread and check that the tldr expands beat-by-beat as expected", "tags": ["Next step"]}, {"text": "can you paste the diff stats for server/prompt.txt and app/Resources/prompt.txt so i can confirm the parity test passed?", "tags": ["Ask", "Evidence"]}, {"text": "kick off a sweep on the dogfood fixture set and report any captures where the TL;DR came back as a bare status", "tags": ["Next step"]}]}

Output JSON only:

{"schema_version": 2, "tldr": "...", "suggestions": [{"text": "...", "tags": ["Reply"]}, {"text": "...", "tags": ["Ask"]}, {"text": "...", "tags": ["Next step"]}]}
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def bundle_id() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S-") + f"{datetime.now().microsecond // 1000:03d}"


def plain_data(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if hasattr(value, "model_dump"):
        return plain_data(value.model_dump(exclude_none=True))
    if isinstance(value, dict):
        return {str(key): plain_data(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain_data(item) for item in value]
    return str(value)


def save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def load_json(path: Path | None, fallback: dict[str, Any]) -> dict[str, Any]:
    if path is None or not path.exists():
        return dict(fallback)
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    result = dict(fallback)
    for key in fallback:
        if key in payload:
            result[key] = payload[key]
    return result


def load_json_object(path: Path | None) -> dict[str, Any] | None:
    if path is None or not path.exists():
        return None
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def read_text(path: Path | None, fallback: str) -> str:
    if path is None or not path.exists():
        return fallback
    return path.read_text(encoding="utf-8")


def env_truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "on"}


def _bounded_text(value: Any, limit: int) -> str | None:
    text = str(value or "").strip()
    if not text:
        return None
    return text[:limit]


def _parse_iso(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


_VOICE_PRIORITY_BY_MATCH_MODE = {
    "window_match": 0,
    "bundle_match": 1,
    "cross_surface": 2,
}


def _voice_priority(sample: dict[str, Any]) -> int:
    return _VOICE_PRIORITY_BY_MATCH_MODE.get(sample.get("match_mode"), 3)


def _run_sort_time(run_dir: Path, run_log: dict[str, Any]) -> datetime:
    for key in ("chosen_at", "custom_reply_at", "finished_at", "started_at"):
        parsed = _parse_iso(run_log.get(key))
        if parsed is not None:
            return parsed
    try:
        return datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc)
    except OSError:
        return datetime.fromtimestamp(0, tz=timezone.utc)


def _load_run_pair(run_dir: Path) -> tuple[dict[str, Any], dict[str, Any]] | None:
    run_path = run_dir / "run.json"
    request_path = run_dir / "request.json"
    if not run_path.exists():
        return None
    try:
        run_log = json.loads(run_path.read_text(encoding="utf-8"))
        request_log = (
            json.loads(request_path.read_text(encoding="utf-8"))
            if request_path.exists()
            else {}
        )
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(run_log, dict):
        return None
    if not isinstance(request_log, dict):
        request_log = {}
    return run_log, request_log


def _surface_key(envelope: dict[str, Any]) -> dict[str, Any]:
    frontmost = envelope.get("frontmost_app")
    if not isinstance(frontmost, dict):
        frontmost = {}
    focused = envelope.get("focused_context")
    if not isinstance(focused, dict):
        focused = {}
    bundle_id = _bounded_text(
        frontmost.get("bundle_id") or focused.get("bundle_id"),
        160,
    )
    title = _bounded_text(focused.get("title"), 160)
    role = _bounded_text(
        focused.get("role") or focused.get("ax_role") or focused.get("focused_role"),
        160,
    )
    raw_window_id = frontmost.get("window_id")
    window_id = raw_window_id if isinstance(raw_window_id, int) else None
    return {
        "bundle_id": bundle_id,
        "title": title,
        "role": role,
        "window_id": window_id,
    }


def _surface_match(
    current_key: dict[str, Any],
    previous_key: dict[str, Any],
) -> tuple[str | None, str | None]:
    current_bundle = current_key.get("bundle_id")
    previous_bundle = previous_key.get("bundle_id")
    if not current_bundle:
        return None, "current_missing_bundle_id"
    if not previous_bundle:
        return None, "previous_missing_bundle_id"
    if current_bundle != previous_bundle:
        return None, "bundle_id_mismatch"
    current_window = current_key.get("window_id")
    previous_window = previous_key.get("window_id")
    if isinstance(current_window, int) and isinstance(previous_window, int):
        if current_window != previous_window:
            return None, "window_id_mismatch"
        return "window_match", None
    return "bundle_match", None


def build_stateful_context(
    runs_dir: Path,
    current_envelope: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, Any] | None:
    if not runs_dir.exists():
        return None
    now = now or datetime.now(timezone.utc)
    run_pairs: list[tuple[Path, dict[str, Any], dict[str, Any], datetime]] = []
    for run_dir in runs_dir.iterdir():
        if not run_dir.is_dir():
            continue
        pair = _load_run_pair(run_dir)
        if pair is None:
            continue
        run_log, request_log = pair
        run_pairs.append((run_dir, run_log, request_log, _run_sort_time(run_dir, run_log)))
    run_pairs.sort(key=lambda item: item[3], reverse=True)

    voice_candidates: list[dict[str, Any]] = []
    seen_voice: set[str] = set()
    preference_examples: list[dict[str, Any]] = []
    seen_preference: set[str] = set()
    recent_surface_history: list[dict[str, Any]] = []
    current_surface_key = _surface_key(current_envelope)
    surface_match_debug: dict[str, Any] = {
        "match_mode": "no_match",
        "matched_run_ids": [],
        "skipped_reasons": {},
    }

    for run_dir, run_log, request_log, sort_time in run_pairs:
        previous_surface_key = _surface_key(request_log)
        match_mode, skipped_reason = _surface_match(current_surface_key, previous_surface_key)

        age_seconds = (now - sort_time).total_seconds()
        if age_seconds < 0:
            surface_match_debug["skipped_reasons"]["future_run"] = surface_match_debug["skipped_reasons"].get("future_run", 0) + 1
            continue

        response = run_log.get("response") if isinstance(run_log.get("response"), dict) else {}
        custom_text = _bounded_text(run_log.get("custom_reply_text"), VOICE_SAMPLE_MAX_CHARS)
        # Single-word noise like "test", "ok", "ack" carries no real style or
        # preference signal and tends to harm the model when it gets imitated
        # verbatim. Drop it from both voice samples and preference examples.
        if custom_text and len(custom_text) < VOICE_SAMPLE_MIN_CHARS:
            custom_text = None

        # Voice samples are not gated by surface match or the recency window:
        # the user's voice changes slowly and is informative across apps. The
        # surface buckets below still apply both gates. Same-app voice from a
        # different window is still high-signal, so a window_id_mismatch
        # against the same bundle is treated as a bundle_match for voice
        # purposes (only a true bundle mismatch is cross_surface).
        if custom_text and custom_text not in seen_voice:
            frontmost = request_log.get("frontmost_app")
            if not isinstance(frontmost, dict):
                frontmost = {}
            if match_mode:
                voice_match_mode = match_mode
            elif skipped_reason == "window_id_mismatch":
                voice_match_mode = "bundle_match"
            else:
                voice_match_mode = "cross_surface"
            voice_candidates.append(
                {
                    "text": custom_text,
                    "created_at": run_log.get("custom_reply_at") or run_log.get("chosen_at") or run_log.get("finished_at"),
                    "app_bundle_id": frontmost.get("bundle_id"),
                    "app_name": frontmost.get("app_name"),
                    "match_mode": voice_match_mode,
                }
            )
            seen_voice.add(custom_text)

        if match_mode is None:
            reason = skipped_reason or "no_match"
            surface_match_debug["skipped_reasons"][reason] = surface_match_debug["skipped_reasons"].get(reason, 0) + 1
            continue
        if age_seconds > SURFACE_CONTEXT_WINDOW_SECONDS:
            reason = f"{match_mode}_too_old"
            surface_match_debug["skipped_reasons"][reason] = surface_match_debug["skipped_reasons"].get(reason, 0) + 1
            continue

        if len(recent_surface_history) < SURFACE_HISTORY_LIMIT:
            history_item = {
                "created_at": run_log.get("finished_at") or run_log.get("started_at"),
                "tldr": _bounded_text(response.get("tldr"), SURFACE_TEXT_MAX_CHARS),
                "chosen_action": run_log.get("chosen_action"),
                "chosen_index": run_log.get("chosen_index"),
                "custom_reply_text": _bounded_text(run_log.get("custom_reply_text"), SURFACE_TEXT_MAX_CHARS),
                "chosen_text": _bounded_text(run_log.get("chosen_text"), SURFACE_TEXT_MAX_CHARS),
                "run_dir": run_dir.name,
                "match_mode": match_mode,
            }
            history_item = {key: value for key, value in history_item.items() if value not in (None, "", [])}
            if len(history_item) > 3:
                if not (recent_surface_history and history_item.get("tldr") is not None and history_item.get("tldr") == recent_surface_history[-1].get("tldr")):
                    recent_surface_history.append(history_item)
                    surface_match_debug["matched_run_ids"].append(run_dir.name)
                    if surface_match_debug["match_mode"] == "no_match":
                        surface_match_debug["match_mode"] = match_mode

        raw_suggestions = response.get("suggestions")
        rejected_suggestions = []
        if isinstance(raw_suggestions, list):
            rejected_suggestions = [
                text
                for text in (_bounded_text(item, PREFERENCE_TEXT_MAX_CHARS) for item in raw_suggestions)
                if text
            ][:PREFERENCE_REJECTED_SUGGESTION_LIMIT]
        if (
            custom_text
            and custom_text not in seen_preference
            and rejected_suggestions
            and len(preference_examples) < PREFERENCE_EXAMPLE_LIMIT
        ):
            preference_examples.append(
                {
                    "screen_takeaway": _bounded_text(response.get("tldr"), PREFERENCE_TEXT_MAX_CHARS),
                    "rejected_suggestions": rejected_suggestions,
                    "user_typed": _bounded_text(custom_text, PREFERENCE_TEXT_MAX_CHARS),
                    "run_dir": run_dir.name,
                    "match_mode": match_mode,
                }
            )
            seen_preference.add(custom_text)

    # Prefer same-window voice, then same-bundle, then cross-surface. Within
    # each priority bucket the input order (time-desc) is preserved by the
    # stable sort, so the cap of VOICE_SAMPLE_LIMIT favors the most relevant
    # signal when same-surface samples exist, and falls back to recent
    # cross-surface voice when they don't.
    voice_candidates.sort(key=_voice_priority)
    voice_samples = voice_candidates[:VOICE_SAMPLE_LIMIT]

    if not voice_samples and not recent_surface_history and not preference_examples:
        if not surface_match_debug["skipped_reasons"]:
            return None
        return {
            "schema_version": STATEFUL_CONTEXT_VERSION,
            "voice_samples": [],
            "preference_examples": [],
            "recent_surface_history": [],
            "surface_match_debug": surface_match_debug,
            "surface_key": current_surface_key,
            "matched_history_count": 0,
            "voice_sample_count": 0,
            "preference_example_count": 0,
        }
    return {
        "schema_version": STATEFUL_CONTEXT_VERSION,
        "voice_samples": voice_samples,
        "preference_examples": preference_examples,
        "recent_surface_history": recent_surface_history,
        "surface_match_debug": surface_match_debug,
        "surface_key": current_surface_key,
        "matched_history_count": len(recent_surface_history),
        "voice_sample_count": len(voice_samples),
        "preference_example_count": len(preference_examples),
    }


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
    follow_up_instruction = _bounded_text(
        reroll_context.get("follow_up_instruction"),
        FOLLOW_UP_INSTRUCTION_MAX_CHARS,
    )
    style_text = style_block(style)
    if (
        not voice_samples
        and not preference_examples
        and not surface_history
        and not previous_suggestion_texts
        and not style_text
        and not follow_up_instruction
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
            ]
        )
        if follow_up_instruction:
            lines.extend(
                [
                    "User follow-up instruction:",
                    follow_up_instruction,
                    "Apply this instruction to the new suggestions while still using only visible evidence.",
                ]
            )
        lines.append(
            "The user asked for a fresh set of suggestions for the same capture. Use the same visible evidence, but avoid repeating these previous suggestions unless one is clearly the only correct answer:"
        )
        for suggestion in previous_suggestion_texts:
            lines.append(f"- {suggestion}")
    elif follow_up_instruction:
        lines.extend(
            [
                "Reroll instructions:",
                "User follow-up instruction:",
                follow_up_instruction,
                "Apply this instruction to a fresh set of suggestions for the same capture while still using only visible evidence.",
            ]
        )
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
                            "description": "A candidate reply or next action the user might send next.",
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


def response_schema():
    from google.genai import types

    contract = response_schema_contract()
    return types.Schema(
        type=types.Type.OBJECT,
        required=contract["required"],
        propertyOrdering=contract["property_ordering"],
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
                            description="A candidate reply or next action the user might send next.",
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


def parse_json_response(raw_text: str) -> tuple[Any | None, str | None]:
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


def normalize_payload(parsed: dict[str, Any]) -> tuple[str, list[str], list[dict[str, Any]]]:
    tldr = str(parsed.get("tldr") or "").strip()
    suggestion_details = normalize_suggestion_details(parsed)
    suggestions = [item["text"] for item in suggestion_details]
    return tldr, suggestions, suggestion_details


def build_response_payload(
    raw_text: str,
    usage: Any,
    duration_ms: int,
    image_diagnostics: dict[str, Any] | None = None,
) -> dict[str, Any]:
    parsed, parse_error = parse_json_response(raw_text)
    usage_dict = plain_data(usage)
    thoughts_token_count: int | None = None
    if isinstance(usage_dict, dict):
        for key in ("thoughts_token_count", "thoughtsTokenCount", "thinking_tokens"):
            value = usage_dict.get(key)
            if isinstance(value, int):
                thoughts_token_count = value
                break
    payload: dict[str, Any] = {
        "raw": raw_text,
        "usage": usage_dict,
        "thoughts_token_count": thoughts_token_count,
        "duration_ms": duration_ms,
        "parse_error": parse_error,
        "warnings": [],
        "request_id": None,
    }
    if image_diagnostics:
        payload.update(image_diagnostics)
    if parsed is None:
        payload.update(
            {
                "status": "parse_error",
                "tldr": "Gemini returned non-JSON output.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload
    if not isinstance(parsed, dict):
        payload.update(
            {
                "status": "schema_mismatch",
                "tldr": "Gemini returned an unexpected JSON shape.",
                "suggestions": [raw_text or "[empty response]"],
            }
        )
        return payload
    tldr, suggestions, suggestion_details = normalize_payload(parsed)
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


def prepare_screenshot_part(
    types_module,
    screenshot_path: Path,
    settings: dict[str, Any],
) -> tuple[Any, dict[str, Any]]:
    request_image = prepare_request_image(screenshot_path, settings)
    image_part = types_module.Part.from_bytes(
        data=request_image["bytes_data"],
        mime_type=request_image["mime_type"],
    )
    diagnostics = {
        "image_bytes_original": request_image["original_bytes"],
        "image_bytes_compressed": request_image["request_bytes"],
        "image_prepare_ms": request_image["duration_ms"],
        "media_resolution_resolved": media_resolution_for_model(
            str(settings.get("model") or ""),
            str(settings.get("media_resolution") or "MEDIA_RESOLUTION_LOW"),
        ),
    }
    return image_part, diagnostics


def prepare_screenshot_parts(
    types_module,
    screenshot_paths: list[Path],
    settings: dict[str, Any],
) -> tuple[list[Any], dict[str, Any]]:
    parts: list[Any] = []
    frames: list[dict[str, Any]] = []
    original_total = 0
    compressed_total = 0
    prepare_total = 0
    media_resolution = media_resolution_for_model(
        str(settings.get("model") or ""),
        str(settings.get("media_resolution") or "MEDIA_RESOLUTION_LOW"),
    )
    for index, screenshot_path in enumerate(screenshot_paths):
        part, diagnostics = prepare_screenshot_part(types_module, screenshot_path, settings)
        parts.append(part)
        original_total += int(diagnostics.get("image_bytes_original") or 0)
        compressed_total += int(diagnostics.get("image_bytes_compressed") or 0)
        prepare_total += int(diagnostics.get("image_prepare_ms") or 0)
        frames.append(
            {
                "index": index,
                "path": str(screenshot_path),
                **diagnostics,
            }
        )
    return parts, {
        "frames": frames,
        "frame_count": len(screenshot_paths),
        "image_bytes_original": original_total,
        "image_bytes_compressed": compressed_total,
        "image_prepare_ms": prepare_total,
        "image_bytes_original_total": original_total,
        "image_bytes_compressed_total": compressed_total,
        "media_resolution_resolved": media_resolution,
    }


def emit_stream_event(kind: str, payload: dict[str, Any]) -> None:
    event = {"event": kind, **payload}
    print(json.dumps(event, ensure_ascii=True), flush=True)


def extract_partial_suggestions(raw_text: str) -> list[str]:
    """Parse zero or more suggestion strings from streaming JSON output.

    Returns closed suggestions plus the in-progress one (if any) so the overlay
    can show suggestions appearing token-by-token. Returns [] if no
    "suggestions" array has started yet.
    """
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


def proxy_settings_from_env() -> dict[str, str] | None:
    if env_truthy(os.environ.get(DISABLE_PROXY_ENV)) or env_truthy(os.environ.get(DISABLE_PROXY_ENV_DEPRECATED)):
        return None
    proxy_url = (
        os.environ.get(PROXY_URL_ENV)
        or os.environ.get(PROXY_URL_ENV_DEPRECATED)
        or ""
    ).strip()
    proxy_token = ""
    if DEVICE_TOKEN_PATH.exists():
        proxy_token = DEVICE_TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not proxy_token:
        proxy_token = (
            os.environ.get(PROXY_TOKEN_ENV)
            or os.environ.get(PROXY_TOKEN_ENV_DEPRECATED)
            or ""
        ).strip()
    if not proxy_url and not proxy_token:
        return None
    if not proxy_url or not proxy_token:
        raise ValueError(f"Set both {PROXY_URL_ENV} and {PROXY_TOKEN_ENV}, or neither.")
    return {
        "url": proxy_url.rstrip("/"),
        "token": proxy_token,
    }


def bundled_proxy_token_from_env() -> str:
    return (
        os.environ.get(PROXY_TOKEN_ENV)
        or os.environ.get(PROXY_TOKEN_ENV_DEPRECATED)
        or ""
    ).strip()


def clear_device_token_if_matches(token: str) -> bool:
    if not token.startswith("tldr_dt_") or not DEVICE_TOKEN_PATH.exists():
        return False
    try:
        existing = DEVICE_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    if existing != token:
        return False
    try:
        DEVICE_TOKEN_PATH.unlink()
    except OSError:
        return False
    return True


def write_model_input(
    path: Path,
    *,
    generation_path: str,
    prompt_text: str,
    request_payload: dict[str, Any],
) -> None:
    lines = [f"generation_path: {generation_path}", ""]
    if generation_path == "proxy":
        lines.extend(
            [
                "scope:",
                "Client-side diagnostic preview for the proxy request. The packaged app sends request.json plus the screenshot to the server; the server renders the final Gemini request with its deployed prompt.",
                "",
                "proxy_server_system_instruction_preview:",
                prompt_text.rstrip(),
                "",
                "proxy_server_contents_preview:",
            ]
        )
        lines.extend(
            [
                SERVER_CONTENT_TEXT,
                "",
                "submitted_proxy_request_json:",
                json.dumps(plain_data(request_payload), indent=2, ensure_ascii=True, sort_keys=True),
                "",
            ]
        )
    else:
        lines.extend(
            [
                "scope:",
                "Actual local Gemini system instruction and text content for this run path.",
                "",
                "system_instruction:",
                prompt_text.rstrip(),
                "",
                "contents_text:",
                MODEL_CONTENT_TEXT,
                "",
                "structured_request_context_json:",
                json.dumps(plain_data(request_payload), indent=2, ensure_ascii=True, sort_keys=True),
                "",
            ]
        )
    path.write_text("\n".join(lines), encoding="utf-8")


def write_model_context(
    path: Path,
    *,
    generation_path: str,
    prompt_text: str,
    request_payload: dict[str, Any],
    stateful_context: dict[str, Any] | None,
    settings: dict[str, Any],
) -> None:
    payload: dict[str, Any] = {
        "schema_version": 1,
        "generation_path": generation_path,
        "model": settings.get("model"),
        "stateful_context_summary": {
            "voice_sample_count": len(stateful_context.get("voice_samples", [])) if stateful_context else 0,
            "preference_example_count": len(stateful_context.get("preference_examples", [])) if stateful_context else 0,
            "recent_surface_history_count": len(stateful_context.get("recent_surface_history", [])) if stateful_context else 0,
            "surface_match_debug": stateful_context.get("surface_match_debug") if stateful_context else None,
        },
        "submitted_request": request_payload,
    }
    if generation_path == "proxy":
        payload["model_input_scope"] = (
            "client_proxy_payload_with_server_rendering_preview"
        )
        payload["proxy_server_preview"] = {
            "system_instruction": prompt_text,
            "contents": [SERVER_CONTENT_TEXT],
            "note": "The deployed server owns the exact final model input for proxy runs; this preview mirrors the local server renderer.",
        }
    else:
        payload["model_input_scope"] = "actual_local_gemini_input"
        payload["local_gemini_input"] = {
            "system_instruction": prompt_text,
            "contents_text": MODEL_CONTENT_TEXT,
        }
    save_json(path, payload)


def _proxy_diagnostics(
    proxy_settings: dict[str, str],
    *,
    accept: str,
    stream_events: bool,
    http_status: int | None = None,
    content_type: str | None = None,
    error_type: str | None = None,
) -> dict[str, Any]:
    parsed = parse.urlparse(proxy_settings["url"])
    diagnostics: dict[str, Any] = {
        "scheme": parsed.scheme,
        "host": parsed.netloc,
        "base_path": parsed.path or "/",
        "request_path": "/v1/tldr",
        "accept": accept,
        "stream_events": stream_events,
    }
    if http_status is not None:
        diagnostics["http_status"] = http_status
    if content_type:
        diagnostics["content_type"] = content_type
    if error_type:
        diagnostics["error_type"] = error_type
    return diagnostics


def _proxy_error_payload(
    message: str,
    *,
    duration_ms: int | None,
    proxy_diagnostics: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "status": "error",
        "tldr": "Proxy request failed.",
        "suggestions": [message],
        "raw": message,
        "usage": None,
        "duration_ms": duration_ms,
        "parse_error": None,
        "warnings": [],
        "request_id": None,
        "model": None,
        "proxy_diagnostics": proxy_diagnostics,
    }


def _proxy_error_message(raw_body: str, fallback: str) -> str:
    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError:
        return fallback
    detail = parsed.get("detail")
    if not detail:
        return fallback
    return str(detail)


def _parse_sse_event_block(block: str) -> tuple[str, dict[str, Any] | None]:
    event_name = "message"
    data_lines: list[str] = []
    for raw_line in block.splitlines():
        if raw_line.startswith(":"):
            continue
        if raw_line.startswith("event:"):
            event_name = raw_line.removeprefix("event:").strip() or "message"
        elif raw_line.startswith("data:"):
            data_lines.append(raw_line.removeprefix("data:").lstrip())
    if not data_lines:
        return event_name, None
    try:
        parsed = json.loads("\n".join(data_lines))
    except json.JSONDecodeError:
        return event_name, None
    if not isinstance(parsed, dict):
        return event_name, None
    return event_name, parsed


def _iter_sse_events(response: Any) -> Any:
    pending: list[str] = []
    while True:
        line = response.readline()
        if not line:
            break
        text = line.decode("utf-8", errors="replace") if isinstance(line, bytes) else str(line)
        text = text.rstrip("\r\n")
        if text:
            pending.append(text)
            continue
        if pending:
            yield _parse_sse_event_block("\n".join(pending))
            pending = []
    if pending:
        yield _parse_sse_event_block("\n".join(pending))


def _encode_multipart_request(
    request_payload: dict[str, Any],
    image_paths: list[Path],
) -> tuple[bytes, str]:
    boundary = f"blink-{uuid4().hex}"
    request_json = json.dumps(request_payload, ensure_ascii=True, sort_keys=True).encode("utf-8")
    parts: list[bytes] = [
        f"--{boundary}\r\n".encode("utf-8"),
        b'Content-Disposition: form-data; name="request"\r\n',
        b"Content-Type: application/json\r\n\r\n",
        request_json,
        b"\r\n",
    ]
    for index, image_path in enumerate(image_paths):
        field_name = "screenshot" if index == 0 else f"screenshot_{index}"
        parts.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                (
                    f'Content-Disposition: form-data; name="{field_name}"; '
                    f'filename="screenshot_{index}{image_path.suffix or ".png"}"\r\n'
                ).encode("utf-8"),
                b"Content-Type: image/png\r\n\r\n",
                image_path.read_bytes(),
                b"\r\n",
            ]
        )
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(parts), boundary


def generate_via_proxy(
    request_payload: dict[str, Any],
    settings: dict[str, Any],
    proxy_settings: dict[str, str],
    image_paths: list[Path],
    stream_events: bool = False,
    retry_stale_device_token: bool = True,
) -> dict[str, Any]:
    body, boundary = _encode_multipart_request(request_payload, image_paths)
    timeout_seconds = float(settings["timeout_seconds"])
    accept = "text/event-stream" if stream_events else "application/json"
    proxy_diagnostics = _proxy_diagnostics(
        proxy_settings,
        accept=accept,
        stream_events=stream_events,
    )
    req = request.Request(
        f"{proxy_settings['url']}/v1/tldr",
        data=body,
        headers={
            "Authorization": f"Bearer {proxy_settings['token']}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": accept,
        },
        method="POST",
    )

    started = time.perf_counter()
    try:
        with request.urlopen(req, timeout=timeout_seconds) as response:
            response_status = getattr(response, "status", None) or getattr(response, "code", None)
            content_type = response.headers.get("content-type") if getattr(response, "headers", None) else None
            proxy_diagnostics = _proxy_diagnostics(
                proxy_settings,
                accept=accept,
                stream_events=stream_events,
                http_status=response_status,
                content_type=content_type,
            )
            if stream_events:
                if content_type and "text/event-stream" not in content_type.lower():
                    raw_body = response.read().decode("utf-8", errors="replace")
                    try:
                        parsed_json = json.loads(raw_body)
                    except json.JSONDecodeError:
                        parsed_json = None
                    if isinstance(parsed_json, dict) and (
                        "tldr" in parsed_json
                        or "suggestions" in parsed_json
                        or parsed_json.get("status") in {"ok", "error", "parse_error", "schema_mismatch"}
                    ):
                        proxy_diagnostics["fallback"] = "json_response"
                        raw_text = raw_body
                        parsed = parsed_json
                    else:
                        proxy_diagnostics["error_type"] = "non_sse_response"
                        fallback = f"Proxy returned non-SSE response (HTTP {response_status or 'unknown'})."
                        return _proxy_error_payload(
                            _proxy_error_message(raw_body, fallback),
                            duration_ms=int(round((time.perf_counter() - started) * 1000)),
                            proxy_diagnostics=proxy_diagnostics,
                        )
                else:
                    final_payload: dict[str, Any] | None = None
                    raw_events: list[dict[str, Any]] = []
                    for event_name, data in _iter_sse_events(response):
                        if data is None:
                            continue
                        raw_events.append({"event": event_name, "data": data})
                        if event_name in {"partial_tldr", "partial_suggestions"}:
                            emit_stream_event(event_name, data)
                        elif event_name == "final":
                            final_payload = data
                        elif event_name == "error":
                            final_payload = {
                                "status": "error",
                                "tldr": "Proxy request failed.",
                                "suggestions": [str(data.get("detail") or "Proxy returned an error event.")],
                                "duration_ms": int(round((time.perf_counter() - started) * 1000)),
                                "warnings": data.get("warnings") if isinstance(data.get("warnings"), list) else [],
                                "request_id": data.get("request_id"),
                                "model": data.get("model"),
                                "proxy_diagnostics": proxy_diagnostics,
                            }
                    raw_text = json.dumps(raw_events, ensure_ascii=True)
                    if final_payload is None:
                        return _proxy_error_payload(
                            "Proxy stream ended without a final event.",
                            duration_ms=int(round((time.perf_counter() - started) * 1000)),
                            proxy_diagnostics=proxy_diagnostics,
                        )
                    parsed = final_payload
            else:
                raw_text = response.read().decode("utf-8")
                parsed = json.loads(raw_text)
    except error.HTTPError as exc:
        finished = time.perf_counter()
        raw_body = exc.read().decode("utf-8", errors="replace")
        bundled_token = bundled_proxy_token_from_env()
        if (
            retry_stale_device_token
            and exc.code == 401
            and proxy_settings["token"].startswith("tldr_dt_")
            and bundled_token
            and bundled_token != proxy_settings["token"]
            and clear_device_token_if_matches(proxy_settings["token"])
        ):
            retry_settings = {**proxy_settings, "token": bundled_token}
            retry_payload = generate_via_proxy(
                request_payload=request_payload,
                settings=settings,
                proxy_settings=retry_settings,
                image_paths=image_paths,
                stream_events=stream_events,
                retry_stale_device_token=False,
            )
            warnings = retry_payload.setdefault("warnings", [])
            if isinstance(warnings, list):
                warnings.append("Cleared stale cached device token after proxy returned 401.")
            return retry_payload
        fallback = f"Proxy returned HTTP {exc.code}."
        return _proxy_error_payload(
            _proxy_error_message(raw_body, fallback),
            duration_ms=int(round((finished - started) * 1000)),
            proxy_diagnostics=_proxy_diagnostics(
                proxy_settings,
                accept=accept,
                stream_events=stream_events,
                http_status=exc.code,
                content_type=exc.headers.get("content-type") if exc.headers else None,
                error_type="http_error",
            ),
        )
    except error.URLError as exc:
        finished = time.perf_counter()
        return _proxy_error_payload(
            f"Proxy request failed: {exc.reason}",
            duration_ms=int(round((finished - started) * 1000)),
            proxy_diagnostics=_proxy_diagnostics(
                proxy_settings,
                accept=accept,
                stream_events=stream_events,
                error_type="url_error",
            ),
        )
    except json.JSONDecodeError:
        finished = time.perf_counter()
        return _proxy_error_payload(
            "Proxy returned non-JSON output.",
            duration_ms=int(round((finished - started) * 1000)),
            proxy_diagnostics=_proxy_diagnostics(
                proxy_settings,
                accept=accept,
                stream_events=stream_events,
                error_type="json_decode_error",
            ),
        )

    finished = time.perf_counter()
    if not isinstance(parsed, dict):
        return _proxy_error_payload(
            "Proxy returned an unexpected response.",
            duration_ms=int(round((finished - started) * 1000)),
            proxy_diagnostics=proxy_diagnostics,
        )

    suggestion_details = normalize_suggestion_details(parsed)
    if suggestion_details:
        suggestions = [item["text"] for item in suggestion_details]
    else:
        raw_suggestions = parsed.get("suggestions")
        if not isinstance(raw_suggestions, list):
            raw_suggestions = []
        suggestions = []
        for item in raw_suggestions:
            if isinstance(item, dict):
                text = str(item.get("text") or "").strip()
            else:
                text = str(item or "").strip()
            if text:
                suggestions.append(text)
            if len(suggestions) >= 3:
                break
        suggestion_details = [{"text": text, "tags": []} for text in suggestions]

    payload: dict[str, Any] = {
        "status": str(parsed.get("status") or "error"),
        "tldr": str(parsed.get("tldr") or ""),
        "suggestions": suggestions,
        "suggestion_details": suggestion_details,
        "raw": raw_text,
        "usage": None,
        "duration_ms": int(parsed.get("duration_ms") or round((finished - started) * 1000)),
        "parse_error": None,
        "warnings": parsed.get("warnings") if isinstance(parsed.get("warnings"), list) else [],
        "request_id": parsed.get("request_id"),
        "model": parsed.get("model"),
        "proxy_diagnostics": parsed.get("proxy_diagnostics") if isinstance(parsed.get("proxy_diagnostics"), dict) else proxy_diagnostics,
    }
    return payload


def request_payload_for_proxy(request_payload: dict[str, Any]) -> dict[str, Any]:
    payload = dict(request_payload)
    reroll_context = payload.get("reroll_context")
    if isinstance(reroll_context, dict):
        source_request_id = str(reroll_context.get("source_request_id") or "").strip()
        if source_request_id:
            trimmed_reroll_context = {
                "schema_version": int(reroll_context.get("schema_version") or 1),
                "source_request_id": source_request_id,
            }
            follow_up_instruction = _bounded_text(
                reroll_context.get("follow_up_instruction"),
                FOLLOW_UP_INSTRUCTION_MAX_CHARS,
            )
            if follow_up_instruction:
                trimmed_reroll_context["follow_up_instruction"] = follow_up_instruction
            payload["reroll_context"] = trimmed_reroll_context
        else:
            payload.pop("reroll_context", None)
    return payload


def stream_phase_message(request_payload: dict[str, Any]) -> str:
    return (
        "Rerolling suggestions..."
        if isinstance(request_payload.get("reroll_context"), dict)
        else "Reading this screen..."
    )


def generate(
    screenshot_paths: list[Path],
    prompt_text: str,
    settings: dict[str, Any],
) -> dict[str, Any]:
    from google import genai
    from google.genai import types

    client = genai.Client(
        api_key=os.environ.get("GEMINI_API_KEY"),
        http_options=types.HttpOptions(timeout=int(settings["timeout_seconds"] * 1000)),
    )
    image_parts, image_diagnostics = prepare_screenshot_parts(types, screenshot_paths, settings)
    config = build_generate_config(types, prompt_text, settings)
    started = time.perf_counter()
    response = client.models.generate_content(
        model=settings["model"],
        contents=image_parts + [MODEL_CONTENT_TEXT],
        config=config,
    )
    duration_ms = int(round((time.perf_counter() - started) * 1000))
    raw_text = (response.text or "").strip()
    return build_response_payload(
        raw_text=raw_text,
        usage=getattr(response, "usage_metadata", None),
        duration_ms=duration_ms,
        image_diagnostics=image_diagnostics,
    )


def generate_streaming(
    screenshot_paths: list[Path],
    prompt_text: str,
    settings: dict[str, Any],
) -> dict[str, Any]:
    from google import genai
    from google.genai import types

    client = genai.Client(
        api_key=os.environ.get("GEMINI_API_KEY"),
        http_options=types.HttpOptions(timeout=int(settings["timeout_seconds"] * 1000)),
    )
    image_parts, image_diagnostics = prepare_screenshot_parts(types, screenshot_paths, settings)
    config = build_generate_config(types, prompt_text, settings)
    started = time.perf_counter()
    raw_text = ""
    usage = None
    last_partial = ""
    last_partial_suggestions: list[str] = []
    first_token_perf: float | None = None
    for chunk in client.models.generate_content_stream(
        model=settings["model"],
        contents=image_parts + [MODEL_CONTENT_TEXT],
        config=config,
    ):
        text = getattr(chunk, "text", None) or ""
        if text:
            if first_token_perf is None:
                first_token_perf = time.perf_counter()
            raw_text += text
            partial = extract_partial_tldr(raw_text)
            if partial and partial != last_partial:
                last_partial = partial
                emit_stream_event("partial_tldr", {"tldr": partial})
            partial_suggestions = extract_partial_suggestions(raw_text)
            if partial_suggestions and partial_suggestions != last_partial_suggestions:
                last_partial_suggestions = list(partial_suggestions)
                emit_stream_event(
                    "partial_suggestions",
                    {"suggestions": partial_suggestions},
                )
        chunk_usage = getattr(chunk, "usage_metadata", None)
        if chunk_usage is not None:
            usage = chunk_usage
    finished_perf = time.perf_counter()
    duration_ms = int(round((finished_perf - started) * 1000))
    payload = build_response_payload(
        raw_text=raw_text.strip(),
        usage=usage,
        duration_ms=duration_ms,
        image_diagnostics=image_diagnostics,
    )
    if first_token_perf is not None:
        ttft_ms = int(round((first_token_perf - started) * 1000))
        payload["time_to_first_token_ms"] = ttft_ms
        payload["streaming_ms"] = max(0, duration_ms - ttft_ms)
    return payload


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run one Blink screenshot request.")
    parser.add_argument("--screenshot", type=Path, required=True, action="append")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--settings", type=Path)
    parser.add_argument("--prompt", type=Path)
    parser.add_argument("--host-profile", type=Path)
    parser.add_argument("--request-json", type=Path)
    parser.add_argument("--skip-gemini", action="store_true")
    parser.add_argument("--stream-events", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    load_runtime_env()
    settings = load_json(args.settings, DEFAULT_SETTINGS)
    runtime = load_json(
        args.runtime,
        {"version": 1, "auto_paste": True, "model": settings["model"], "style": None},
    )
    if runtime.get("model"):
        settings["model"] = runtime["model"]
    style = runtime.get("style") if isinstance(runtime.get("style"), dict) else None
    prompt_text = read_text(args.prompt, DEFAULT_PROMPT)
    request_payload = load_json_object(args.request_json) or {
        "request_id": None,
        "schema_version": 1,
        "input_mode": "screenshot",
    }
    stateful_context = build_stateful_context(args.out_dir, request_payload)
    proxy_settings = proxy_settings_from_env()
    if stateful_context is not None:
        request_payload["stateful_context"] = stateful_context
    if proxy_settings is not None and request_payload.get("request_id"):
        # Preserve the Swift app's preferences (notably thinking_level) instead
        # of stomping them. The server treats `model` and `thinking_level` as
        # client-driven and ignores the rest.
        incoming_prefs = request_payload.get("preferences")
        forwarded_prefs: dict[str, Any] = (
            dict(incoming_prefs) if isinstance(incoming_prefs, dict) else {}
        )
        forwarded_prefs["model"] = settings["model"]
        request_payload["preferences"] = forwarded_prefs
    generation_path = (
        "skip_gemini"
        if args.skip_gemini
        else ("proxy" if proxy_settings is not None and request_payload.get("request_id") else "local_gemini")
    )
    reroll_context = request_payload.get("reroll_context") if isinstance(request_payload.get("reroll_context"), dict) else None
    if style:
        request_payload["style"] = style
    model_prompt_text = (
        prompt_with_context(prompt_text, stateful_context, reroll_context, style)
        if generation_path in {"proxy", "local_gemini"}
        else prompt_text
    )

    run_dir = args.out_dir / bundle_id()
    run_dir.mkdir(parents=True, exist_ok=False)
    stderr_log = run_dir / "stderr.log"
    stderr_log.write_text("", encoding="utf-8")
    screenshot_paths: list[Path] = list(args.screenshot)
    if not screenshot_paths:
        raise ValueError("At least one --screenshot is required.")
    if len(screenshot_paths) > MAX_SCREENSHOT_FRAMES:
        raise ValueError(f"At most {MAX_SCREENSHOT_FRAMES} screenshots are supported.")
    screenshot_out = run_dir / "screenshot.png"
    screenshot_outputs: list[Path] = []
    frame_logs: list[dict[str, Any]] = []
    for index, screenshot_path in enumerate(screenshot_paths):
        frame_out = run_dir / f"screenshot_{index}.png"
        shutil.copy2(screenshot_path, frame_out)
        screenshot_outputs.append(frame_out)
        frame_logs.append(
            {
                "index": index,
                "filename": frame_out.name,
                "bytes": frame_out.stat().st_size,
            }
        )
    shutil.copy2(screenshot_outputs[0], screenshot_out)
    save_json(run_dir / "frames.json", frame_logs)
    save_json(run_dir / "request.json", request_payload)
    write_model_input(
        run_dir / "model_input.txt",
        generation_path=generation_path,
        prompt_text=model_prompt_text,
        request_payload=request_payload,
    )
    write_model_context(
        run_dir / "model_context.json",
        generation_path=generation_path,
        prompt_text=model_prompt_text,
        request_payload=request_payload,
        stateful_context=stateful_context,
        settings=settings,
    )

    host_profile = {}
    if args.host_profile and args.host_profile.exists():
        try:
            host_profile = json.loads(args.host_profile.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            host_profile = {"host_profile_error": "invalid_json"}

    run_log: dict[str, Any] = {
        "status": "started",
        "started_at": now_iso(),
        "request_id": request_payload.get("request_id"),
        "client": request_payload.get("client") or {},
        "runtime": runtime,
        "settings": settings,
        "stateful_context": {
            "voice_sample_count": len(stateful_context.get("voice_samples", [])) if stateful_context else 0,
            "preference_example_count": len(stateful_context.get("preference_examples", [])) if stateful_context else 0,
            "recent_surface_history_count": len(stateful_context.get("recent_surface_history", [])) if stateful_context else 0,
        },
        "frame_count": len(screenshot_outputs),
        "screenshot": {"path": "screenshot.png", "bytes": screenshot_out.stat().st_size},
        "screenshots": [
            {"path": item.name, "bytes": item.stat().st_size}
            for item in screenshot_outputs
        ],
    }
    save_json(run_dir / "host_profile.json", host_profile)

    try:
        if args.stream_events:
            emit_stream_event("run_started", {"bundle_dir": str(run_dir)})
            emit_stream_event(
                "phase",
                {
                    "phase": "model_started",
                    "message": stream_phase_message(request_payload),
                },
            )
        if args.skip_gemini:
            response = {
                "status": "ok",
                "tldr": "You're testing the packaged Blink app.",
                "suggestions": [
                    "This looks good to me.",
                    "Nice, the packaged Blink flow is working.",
                    "Let's try it on one more real conversation.",
                ],
                "suggestion_details": [
                    {"text": "This looks good to me.", "tags": ["Reply"]},
                    {"text": "Nice, the packaged Blink flow is working.", "tags": ["Confirm"]},
                    {"text": "Let's try it on one more real conversation.", "tags": ["Next step"]},
                ],
                "raw": "",
                "usage": None,
                "duration_ms": 0,
                "parse_error": None,
                "warnings": [],
                "request_id": request_payload.get("request_id"),
                "model": settings["model"],
                "media_resolution_resolved": media_resolution_for_model(
                    settings["model"],
                    settings["media_resolution"],
                ),
            }
            if args.stream_events:
                emit_stream_event("partial_tldr", {"tldr": response["tldr"]})
        else:
            if proxy_settings is not None and request_payload.get("request_id"):
                response = generate_via_proxy(
                    request_payload=request_payload_for_proxy(request_payload),
                    settings=settings,
                    proxy_settings=proxy_settings,
                    image_paths=screenshot_outputs,
                    stream_events=args.stream_events,
                )
            else:
                if not os.environ.get("GEMINI_API_KEY"):
                    raise RuntimeError("Set GEMINI_API_KEY in ~/.blink/.env or the launch environment.")
                if args.stream_events and generation_path == "local_gemini":
                    response = generate_streaming(screenshot_outputs, model_prompt_text, settings)
                else:
                    response = generate(screenshot_outputs, model_prompt_text, settings)
                response["request_id"] = request_payload.get("request_id")
                response["warnings"] = []
                response["model"] = settings["model"]
        if isinstance(response.get("frames"), list):
            diagnostics_by_index = {
                item.get("index"): item
                for item in response["frames"]
                if isinstance(item, dict)
            }
            for frame_log in frame_logs:
                diagnostics = diagnostics_by_index.get(frame_log["index"])
                if isinstance(diagnostics, dict):
                    frame_log["image_diagnostics"] = diagnostics
            save_json(run_dir / "frames.json", frame_logs)
        save_json(run_dir / "response.json", response)
        run_log.update(
            {
                "status": response["status"],
                "finished_at": now_iso(),
                "request_id": response.get("request_id"),
                "response": {
                    "tldr": response["tldr"],
                    "suggestions": response["suggestions"],
                    "suggestion_details": response.get("suggestion_details"),
                    "duration_ms": response.get("duration_ms"),
                    "model": response.get("model"),
                    "warnings": response.get("warnings"),
                    "image_bytes_original": response.get("image_bytes_original"),
                    "image_bytes_compressed": response.get("image_bytes_compressed"),
                    "image_prepare_ms": response.get("image_prepare_ms"),
                    "media_resolution_resolved": response.get("media_resolution_resolved"),
                },
            }
        )
        for key in (
            "image_bytes_original",
            "image_bytes_compressed",
            "image_prepare_ms",
            "media_resolution_resolved",
            "proxy_diagnostics",
        ):
            if key in response:
                run_log[key] = response[key]
        save_json(run_dir / "run.json", run_log)
        stdout = {
            "status": response["status"],
            "bundle_dir": str(run_dir),
            "tldr": response["tldr"],
            "suggestions": response["suggestions"],
            "suggestion_details": response.get("suggestion_details"),
            "request_id": response.get("request_id"),
            "duration_ms": response.get("duration_ms"),
            "warnings": response.get("warnings"),
            "model": response.get("model"),
        }
        if args.stream_events:
            emit_stream_event("final", stdout)
        else:
            print(json.dumps(stdout, ensure_ascii=True), flush=True)
        return 0
    except Exception as exc:
        error_text = traceback.format_exc()
        stderr_log.write_text(error_text, encoding="utf-8")
        print(error_text, file=sys.stderr, end="")
        if args.stream_events:
            emit_stream_event("error", {"message": str(exc), "traceback": error_text})
        run_log.update(
            {
                "status": "error",
                "finished_at": now_iso(),
                "error": str(exc),
            }
        )
        save_json(run_dir / "run.json", run_log)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
