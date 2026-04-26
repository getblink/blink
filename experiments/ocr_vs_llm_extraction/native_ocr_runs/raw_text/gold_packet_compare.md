# Gold Source Packet Comparison

- Packet format(s): `text`
- Fixture count: `9`
- Salient-text recall: `61/66` (`0.924`)
- Candidate-field strict recall: `n/a`
- Candidate-field loose recall: `17/28` (`0.607`)
- Source-kind accuracy: `0/9` (`0.0`)
- `can_answer_without_source_image` accuracy: `0/9` (`0.0`)

## Per Fixture

| Fixture | Salient recall | Field strict | Field loose-only | Kind | Can-answer |
| --- | ---: | ---: | ---: | --- | --- |
| `20260421-034447-726-conductor-unknown-role` | `4/6` | `n/a` | `3` | `no` | `no` |
| `20260421-040106-166-conductor-unknown-role` | `5/5` | `n/a` | `2` | `no` | `no` |
| `20260421-040120-784-conductor-unknown-role` | `7/8` | `n/a` | `0` | `no` | `no` |
| `20260421-040337-924-conductor-unknown-role` | `7/7` | `n/a` | `0` | `no` | `no` |
| `20260421-041218-866-conductor-axtextarea` | `9/9` | `n/a` | `0` | `no` | `no` |
| `20260421-135931-785-conductor-axtextarea` | `8/8` | `n/a` | `0` | `no` | `no` |
| `20260421-140159-935-conductor-axtextarea` | `8/8` | `n/a` | `4` | `no` | `no` |
| `20260421-140702-773-conductor-axtextarea` | `8/8` | `n/a` | `4` | `no` | `no` |
| `20260421-200834-043-microsoft-edge-axtextarea` | `5/7` | `n/a` | `4` | `no` | `no` |

## Misses

### `20260421-034447-726-conductor-unknown-role`

Missed salient text:
- `Apple Magic Keyboard with Keypad - Excellent Condition`
- `Selling my Apple Magic Keyboard with Numeric Keypad. It is in great condition, clean, and all keys are fully responsive.`

Missed candidate fields:
- `title: Apple Magic Keyboard with Keypad - Excellent Condition`
- `description: Selling my Apple Magic Keyboard with Numeric Keypad. It is in great condition, clean, and all keys are fully responsive. Perfect for home office setups, coding, or data entry.`

### `20260421-040120-784-conductor-unknown-role`

Missed salient text:
- `fixture saved (20260421-040120-784-conductor-unknown-role)`

Missed candidate fields:
- `message: Blink scratchpad is running with source loaded; the visible hotkeys are ctrl+shift+c for set source and ctrl+shift+v for run target.`
- `message: Two successive captures saved fixtures 20260421-040106-166-conductor-unknown-role and 20260421-040120-784-conductor-unknown-role, both with target metadata not found and NEEDS_REVIEW outputs.`

### `20260421-040337-924-conductor-unknown-role`

Missed candidate fields:
- `message: Repeated Blink capture attempts failed because target metadata was not found, producing NEEDS_REVIEW outputs for fixtures 20260421-040106-166-conductor-unknown-role and 20260421-040120-784-conductor-unknown-role.`
- `message: A later source capture failed with the exact terminal line: source capture failed (no details).`

### `20260421-041218-866-conductor-axtextarea`

Missed candidate fields:
- `message: If AXFocusedUIElement fails, Blink now tries frontmost app AXFocusedUIElement, frontmost app AXActiveElement, frontmost app AXSharedFocusElements, and a bounded descendant search through the focused window subtree for likely editable or focused nodes.`
- `message: I verified the updated files compile. Next step is to run ./capture again for the Conductor target case and send either the new terminal line for target metadata captured or the newest run.json target_metadata_debug.`

### `20260421-135931-785-conductor-axtextarea`

Missed candidate fields:
- `message: For Blink specifically, the right long-term direction is to use AX to identify target field, bounds, nearby structure, and sometimes caret; use event tap only as a signal that typing or focus activity happened; add AX observers later for focused element changed, selected text changed, and value changed; and always tolerate partial AX exposure with field-bounds-level fallbacks.`
- `message: This last run shows the important blocker is cleared: permissions are good, Conductor target focus is now being found, AX walk and geometry are working, and Gemini is producing a concrete output instead of NEEDS_REVIEW.`

### `20260421-200834-043-microsoft-edge-axtextarea`

Missed salient text:
- `What is your company going to make? Please describe your product and what it does or will do.`
- `A macOS app that continuously observes what you're doing across all your apps and uses that context to help you in the moment.`

Missed candidate fields:
- `description: A macOS app that continuously observes what you're doing across all your apps and uses that context to help you in the moment. Not a chatbot you switch to. Not a copilot locked inside one app. A system-wide layer that understands your workflow.`

