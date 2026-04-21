# Blink

Blink is a clean-slate repository for building an AI assistant that understands workflow context across apps.

The initial focus is a single magical moment:

- **Intelligent copy-paste** — capture information from what is on-screen and paste the right value into the currently focused field.

## Product thesis

Modern AI tools are siloed inside individual apps. Blink explores a local, cross-app context layer that can:

- understand what the user is looking at,
- carry that context between apps,
- and help in the exact moment a task is being performed.

Autocomplete and intent may be explored later, but this repository is currently focused on validating intelligent copy-paste first.

## Current stage

This project is in **experiments over builds** mode.

Principles:

- Manual before automation.
- Learn before scaling.
- One core workflow at a time.
- Keep architecture simple until repeated patterns appear.

## Repository map

- `AGENTS.md` — guidance for coding agents working in this repo.
- `docs/PROJECT_BRIEF.md` — high-level scope, goals, and non-goals.
- `docs/EXPERIMENT_LOG.md` — running log of experiments, results, and follow-ups.
- `docs/MANUAL_COPY_PASTE_PLAYBOOK.md` — practical protocol for screenshot framing, prompt structure, and manual evaluation.
- `scratchpad/` — resident hotkey runner plus disposable scripts for profiling screenshot-to-completion experiments.

## How to work in this repo

1. Start with a concrete experiment hypothesis.
2. Define how success/failure will be evaluated.
3. Prefer minimal artifacts (scripts, notes, prompts) over broad infrastructure.
4. Record outcomes in `docs/EXPERIMENT_LOG.md`.
5. Only productize what has shown repeated signal.

## Immediate next step

Run the first intelligent copy-paste experiments manually and log:

- source type (doc/image/web page/PDF),
- target field type,
- extraction/mapping quality,
- correction effort,
- time saved vs manual entry.
