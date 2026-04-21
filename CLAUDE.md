# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Blink

Blink is an early-stage experiment exploring a local, cross-app AI assistant that carries context between applications. The current focus is **intelligent copy-paste**: given a source screenshot and a target field screenshot, a vision model suggests the correct text to paste.

This project is in **experiments-over-builds** mode. Manual validation comes before automation. Do not add polished UI, background daemons, or broad infrastructure unless explicitly asked.

## Repository layout

- `docs/` — project brief, experiment log, and the manual copy-paste playbook
- `scratchpad/` — Python scripts and experiment data for screenshot-to-field trials
  - `hotkey.py` — macOS Quartz-based global hotkey listener (requires Accessibility permissions)
  - `make_trial.py` — CLI to bundle source/target screenshots into a reusable trial packet under `scratchpad/runs/`
  - `prompt.txt` — current base prompt template for the clipboard assistant
  - `.venv/` — Python 3.11 virtualenv (gitignored)
- `AGENTS.md` — operating principles and engineering guidelines for agents

## Development setup

```bash
cd scratchpad
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Key dependencies: `google-genai` (Gemini API), `pyobjc-framework-Quartz` (macOS event tap for hotkeys).

## Running scripts

Create a trial bundle:
```bash
python scratchpad/make_trial.py "trial-name" \
  --source path/to/source.png \
  --target path/to/target.png \
  --intent copy_exact
```

Trial bundles are written to `scratchpad/runs/<timestamp>-<slug>/` and are gitignored.

## Key conventions

- Record experiment outcomes in `docs/EXPERIMENT_LOG.md` with: date, hypothesis, setup, result, decision, next step.
- Keep changes minimal, reversible, and well-scoped. Avoid premature abstraction.
- Favor additive iteration; do not delete prior learning artifacts unless explicitly asked.
- New folders/modules need a README or documentation in `README.md`.
- The vision model prompt in `scratchpad/prompt.txt` and `make_trial.py:render_prompt()` should stay aligned. Changes to one likely require updating the other.
