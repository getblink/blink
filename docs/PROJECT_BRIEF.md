# Project Brief

See also:

- `README.md` for the repo entrypoint and quickstart
- `AGENTS.md` for working rules and documentation expectations
- `CLAUDE.md` for implementation-oriented repo guidance
- `docs/MANUAL_COPY_PASTE_PLAYBOOK.md` for hands-on trial execution
- `docs/EXPERIMENT_LOG.md` for actual experiment outcomes
- `scratchpad/README.md` for the current fixture capture and sweep workflow

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

## Current operational path

The current validation loop is:

1. run `./capture`
2. capture source and target fixtures with `ctrl+shift+c` and `ctrl+shift+v`
3. compare results offline with `./sweep`
4. record outcomes in `docs/EXPERIMENT_LOG.md`
