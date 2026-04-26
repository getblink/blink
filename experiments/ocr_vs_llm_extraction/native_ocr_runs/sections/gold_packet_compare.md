# Gold Source Packet Comparison

- Packet format(s): `text`
- Fixture count: `9`
- Salient-text recall: `65/66` (`0.985`)
- Candidate-field strict recall: `n/a`
- Candidate-field loose recall: `15/28` (`0.536`)
- Source-kind accuracy: `0/9` (`0.0`)
- `can_answer_without_source_image` accuracy: `0/9` (`0.0`)

## Per Fixture

| Fixture | Salient recall | Field strict | Field loose-only | Kind | Can-answer |
| --- | ---: | ---: | ---: | --- | --- |
| `20260421-034447-726-conductor-unknown-role` | `6/6` | `n/a` | `5` | `no` | `no` |
| `20260421-040106-166-conductor-unknown-role` | `5/5` | `n/a` | `1` | `no` | `no` |
| `20260421-040120-784-conductor-unknown-role` | `7/8` | `n/a` | `0` | `no` | `no` |
| `20260421-040337-924-conductor-unknown-role` | `7/7` | `n/a` | `0` | `no` | `no` |
| `20260421-041218-866-conductor-axtextarea` | `9/9` | `n/a` | `0` | `no` | `no` |
| `20260421-135931-785-conductor-axtextarea` | `8/8` | `n/a` | `0` | `no` | `no` |
| `20260421-140159-935-conductor-axtextarea` | `8/8` | `n/a` | `2` | `no` | `no` |
| `20260421-140702-773-conductor-axtextarea` | `8/8` | `n/a` | `2` | `no` | `no` |
| `20260421-200834-043-microsoft-edge-axtextarea` | `7/7` | `n/a` | `5` | `no` | `no` |

## Misses

### `20260421-040106-166-conductor-unknown-role`

Missed candidate fields:
- `message: Updated the Markdown tree so the repo has a clearer documentation spine. The main work is in README.md, CLAUDE.md, and AGENTS.md. README.md is now the entrypoint with the current ./capture / ./sweep flow, while CLAUDE.md and AGENTS.md both point back to the other root docs plus the key files under docs/ and scratchpad/.`

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

### `20260421-140159-935-conductor-axtextarea`

Missed candidate fields:
- `description: first version will be ai powered copy & paste. when user copies something, app takes screenshot of current window. when pasting, we use the source capture and target information to predict what the user wants to paste.`
- `description: example use cases - filling out application fields from a resume pdf or google doc. copy and pasting from an image. relisting items on ecommerce platforms w/out having to switch between two tabs dozens of times. everything can be deployed locally and is open source.`

### `20260421-140702-773-conductor-axtextarea`

Missed candidate fields:
- `description: first version will be ai powered copy & paste. when user copies something, app takes screenshot of current window. when pasting, we use the source capture and target information to predict what the user wants to paste.`
- `description: example use cases - filling out application fields from a resume pdf or google doc. copy and pasting from an image. relisting items on ecommerce platforms w/out having to switch between two tabs dozens of times. everything can be deployed locally and is open source.`

