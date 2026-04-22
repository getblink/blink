# Blink

Blink is an experiment in local, cross-app intelligent copy-paste. The current goal is narrow on purpose: capture what the user is looking at, infer what belongs in the focused field, and suggest the right paste with low correction effort.

## Quickstart

1. Put `GEMINI_API_KEY=...` in `.env` at the repo root.
2. Create the local virtualenv and install dependencies:

```bash
python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install -r scratchpad/requirements.txt
```

3. Start the resident capture runner:

```bash
./capture
```

4. Press `ctrl+shift+c` on a source window, then `ctrl+shift+v` on a target field to record fixtures under `scratchpad/fixtures/`.
5. Sweep saved fixtures against config variants:

```bash
./sweep --fixtures 'scratchpad/fixtures/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/<name>
```

6. Open `compare.html` and `summary.md` in the sweep output directory.

In Conductor workspaces, `scratchpad/fixtures` points at a shared pool in `~/conductor/shared/blink/fixtures/`, so new workspaces inherit the full captured corpus automatically while archived sweeps still remain self-contained.

Conductor hook receipts now make it easy to sanity-check execution: setup writes `.context/conductor/setup-receipt.json`, and archive appends `~/conductor/archive/blink/_archive_runs.jsonl` plus `archive-receipt.json` inside each preserved archive bundle.

## Current focus

- **In scope:** intelligent copy-paste
- **Out of scope for now:** autocomplete, intent feeds, polished UI, background automation
- **Working style:** experiments over builds, manual validation before productization

## Documentation Tree

- [AGENTS.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/AGENTS.md:1): repo operating rules and documentation expectations for coding agents
- [CLAUDE.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/CLAUDE.md:1): implementation-oriented repo guide, layout, and current script workflow
- [docs/PROJECT_BRIEF.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/docs/PROJECT_BRIEF.md:1): product scope, success criteria, constraints, and phase goals
- [docs/MANUAL_COPY_PASTE_PLAYBOOK.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/docs/MANUAL_COPY_PASTE_PLAYBOOK.md:1): manual trial framing, prompt structure, and evaluation protocol
- [docs/EXPERIMENT_LOG.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/docs/EXPERIMENT_LOG.md:1): durable experiment history and outcomes
- [scratchpad/README.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/scratchpad/README.md:1): capture runner, fixture schema, sweep flow, and scratchpad-specific usage
- [scratchpad/eval_configs/README.md](/Users/henryz2004/conductor/workspaces/blink/kyiv/scratchpad/eval_configs/README.md:1): config override format for offline sweeps

## Repository Map

- `docs/` contains the product brief, manual playbook, and experiment log
- `scratchpad/` contains the hotkey runner, shared Gemini request helpers, OCR wrapper, sweep runner, and evaluation configs
- `capture` is the repo-root wrapper for the resident capture runner
- `sweep` is the repo-root wrapper for the offline fixture sweep

## Working Expectations

1. Start with a clear experiment hypothesis.
2. Prefer the fixture capture + sweep workflow over ad hoc prompt trials.
3. Keep changes minimal, reversible, and easy to inspect.
4. Record real experiment outcomes in `docs/EXPERIMENT_LOG.md`.
5. Update docs whenever the workflow or folder structure changes.
