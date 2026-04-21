# Project Brief

## Vision

Blink explores a local, cross-app context system that helps users carry information between applications in real time.

## Why this matters

People work across multiple apps but current AI assistants are app-bound. Blink aims to support the real workflow instead of isolated surfaces.

## Initial capability (in scope)

### Intelligent copy-paste

Given content the user has recently viewed, Blink should infer what belongs in the currently focused destination field and provide a high-quality paste suggestion.

Examples:

- Extracting key values from non-selectable UI
- Pulling details from receipts/listings/screenshots/PDFs
- Mapping content to structured form fields

## Out of scope (for now)

- Full cross-app autocomplete productization
- User-facing intent feed as a polished feature
- Broad automation pipelines and hotkey orchestration

These may be revisited only after strong evidence from copy-paste experiments.

## Success criteria for this phase

- Repeated manual wins on real tasks
- Lower correction effort than manual re-entry
- Clear trust behavior (few surprising/wrong inserts)
- Evidence that context carry-over is materially useful

## Product constraints

- Privacy-local by default
- Minimal context transfer when external LLM calls are used
- Clear operator visibility into what was captured and why output was produced

## Working style

- Cloud-first, resume-anywhere workflow
- Small, auditable commits
- Structured experiment logging
