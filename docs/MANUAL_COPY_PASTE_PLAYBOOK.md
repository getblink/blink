# Manual Intelligent Copy-Paste Playbook (v1)

See also:

- `README.md` for the repo entrypoint
- `docs/PROJECT_BRIEF.md` for scope and success criteria
- `docs/EXPERIMENT_LOG.md` for logging actual trial outcomes
- `scratchpad/README.md` for the current fixture capture and sweep tooling

This playbook is for validating whether a vision model + prompt can reliably suggest the right text for a currently focused field across different apps and content types.

## Core loop (single field)

1. Capture a **source screenshot** (where truth lives).
2. Capture a **target screenshot** (the form field you are about to fill).
3. Send both images + structured prompt to Gemini.
4. Paste model output.
5. Record whether it was correct, partially correct, or wrong.

Current repo workflow:

1. Start `./capture`.
2. Press `ctrl+shift+c` for the source window.
3. Press `ctrl+shift+v` for the target field/window.
4. Review the saved fixture in `scratchpad/fixtures/`.
5. Run `./sweep` when you want to compare prompt/config variants offline.

---

## What each screenshot should capture

## 1) Source screenshot ("copy context")

Goal: maximize factual signal and minimize ambiguity.

Include:

- The full source region that contains the truth you want to reuse.
- Nearby labels, headers, or captions, not just raw values.
- Enough surrounding context to distinguish between similar values.
- If possible, one stable identifier (title snippet, item name, section header, thread subject, document heading).

Avoid:

- Cropping so tightly that labels are cut off.
- Mixing multiple unrelated source candidates in one image.
- Sensitive content not needed for the current task.

## 2) Target screenshot ("paste context")

Goal: make field intent explicit.

Include:

- The field label or visible field purpose.
- The input box itself.
- 1-2 neighboring fields for context.
- Any helper/error text (e.g., "Max 100 characters", format requirements).
- Any visible section header that clarifies what kind of value belongs here.

Avoid:

- Capturing only the blank box without the label.

---

## Encoding caret/focus and existing text

Screenshots alone may not reliably encode cursor state. Use an explicit metadata block in the prompt each turn.

Practical note:

- If the target UI makes the focused field visually unambiguous (for example, a clear blue outline, active cursor, or highlighted label), you can skip metadata for early manual trials and treat the UI itself as the focus signal.
- Reintroduce metadata when focus is subtle, multiple editable regions are visible, partial text edits matter, or latency from manual metadata entry starts to dominate the workflow.

Recommended metadata:

- `task_intent`: copy_exact | normalize_for_field | summarize_for_field | select_best_value.
- `focused_field_label`: visible label of active field.
- `focused_field_type`: short_text | long_text | numeric | currency | dropdown | phone | email.
- `existing_field_text`: exact current text in the focused field (empty string if blank).
- `caret_context`: short note, e.g. "caret at end", "replace all", "insert after '$'".
- `source_scope`: short note if multiple candidate values are visible, e.g. "use shipping address block" or "use current row only".
- `output_constraints`: max length, required format, banned content.

This turns ambiguous visual inference into deterministic instruction.

---

## Prompt template (general)

```text
You are a precise clipboard assistant.

Task:
Given SOURCE_IMAGE (where the source content lives) and TARGET_IMAGE (the UI containing the focused field), produce ONLY the text that should go into the focused field.

Focused field metadata:
- task_intent: "{TASK_INTENT}"
- focused_field_label: "{LABEL}"
- focused_field_type: "{TYPE}"
- existing_field_text: "{EXISTING_TEXT}"
- caret_context: "{CARET_CONTEXT}"
- source_scope: "{SOURCE_SCOPE}"
- output_constraints: "{CONSTRAINTS}"

Rules:
1) Use SOURCE_IMAGE as the primary truth for content.
2) Use TARGET_IMAGE to determine the field intent, local UI context, and formatting constraints.
3) Prefer exact carry-over when possible. Only transform, shorten, normalize, or summarize when task_intent or output_constraints require it.
4) If multiple source candidates are visible, use source_scope plus the target field label to choose the best match.
5) If existing_field_text is non-empty, apply caret_context exactly.
6) Return plain text only. No explanations.
7) If the correct output should be empty, return: [[BLANK]]
8) If uncertain, return: [[NEEDS_REVIEW: reason in <=12 words]]
```

Optional default for early testing:

- Set `task_intent` to `copy_exact` unless the target field clearly requires a transformation.

---

## Suggested micro-evaluation rubric

Per attempt, log:

- `field_name`
- `model_output`
- `gold_value`
- `status`: exact | acceptable | wrong
- `focus_signal`: highlighted_ui | metadata | inferred_from_context
- `metadata_used`: yes | no
- `edit_distance_type`: none | minor | major
- `time_to_final` (seconds)
- `latency_e2e_seconds`
- `failure_mode` (if wrong): extraction | mapping | formatting | hallucination | truncation

This is enough to compare model quality before building any automation.

---

## First experiment recommendation (Facebook relist)

Use Facebook relisting as the first structured scenario, but treat it as a starting case rather than a product assumption.

Run 10-15 single-field trials before multi-field flows.

Order:

1. Title
2. Price
3. Condition
4. Description

Stop criteria for advancing:

- >=80% exact/acceptable on first pass, and
- median correction time < manual retype baseline.

If below threshold, iterate prompt/screenshot framing before writing more code.
