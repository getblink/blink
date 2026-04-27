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

There is also a separate TL;DR + reply-suggestions experiment:

```bash
./tldr
```

It listens for `ctrl+shift+t`, captures one selected window, asks Gemini for a
one-line summary plus three reply candidates, and shows them in a small overlay.
Artifacts land under `scratchpad/tldr_runs/`; see
[`scratchpad/tldr_reply/`](scratchpad/tldr_reply/README.md).

In Conductor workspaces, `scratchpad/fixtures` points at a shared pool in `~/conductor/shared/blink/fixtures/`, so new workspaces inherit the full captured corpus automatically while archived sweeps still remain self-contained.

Conductor hook receipts now make it easy to sanity-check execution: setup writes `.context/conductor/setup-receipt.json`, and archive appends `~/conductor/archive/blink/_archive_runs.jsonl` plus `archive-receipt.json` inside each preserved archive bundle.

## Tester deployment channel (`app/`)

The research loop above runs on the dev box. For non-developer testers, there's a second, independent channel: a signed, notarized Swift `.app` that does the same copy-paste end-to-end and emits bundles we can replay. Source in [`app/`](app/README.md); bundle schema shared across both loops in [`docs/ARTIFACT_SCHEMA.md`](docs/ARTIFACT_SCHEMA.md).

Round-trip for a tester session:

1. Tester runs `Blink.app` → bundles land in `~/Library/Application Support/Blink/runs/<ts>/`.
2. Tester uses the menubar "Export last 10 runs…" action → `~/Desktop/Blink-runs-<ts>.zip`.
3. Researcher imports: `python scratchpad/import_field_runs.py <zip>` → lands under `scratchpad/field_runs/<fixture_id>/`.
4. Replay via sweep: `./sweep --fixtures 'scratchpad/field_runs/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/<name>`.

No runtime coupling between `app/` and `scratchpad/`: production Python is forked from scratchpad at a known SHA (see the header of `app/python/gemini_runner.py`). Resyncing is a deliberate commit.

For local profiling / dogfood on the dev box, do **not** launch Blink out of
`DerivedData` or `app/build` directly. Install one canonical copy instead:

```bash
bash app/scripts/install_local_app.sh
```

That script builds a self-contained Release app, installs it to
`~/Applications/Blink.app`, and hides duplicate build products so Spotlight and
TCC only see one local Blink install. After Swift app-code changes, reinstall
with `--reset-tcc` before trusting Accessibility/Input Monitoring again; we
have seen System Settings keep the toggle enabled while the grant is still
effectively attached to the older binary.

See [`docs/DOGFOOD_PLAYBOOK.md`](docs/DOGFOOD_PLAYBOOK.md) for the full "clean
build + clean permissions + capture everything" procedure, including where
fixtures, profiling timings, `host_profile.json`, and debug logs land per trial.

## Current focus

- **In scope:** intelligent copy-paste
- **Out of scope for now:** autocomplete, intent feeds, polished UI, background automation
- **Working style:** experiments over builds, manual validation before productization

## Documentation Tree

- [AGENTS.md](AGENTS.md): repo operating rules and documentation expectations for coding agents
- [CLAUDE.md](CLAUDE.md): implementation-oriented repo guide, layout, and current script workflow
- [docs/PROJECT_BRIEF.md](docs/PROJECT_BRIEF.md): product scope, success criteria, constraints, and phase goals
- [docs/ARTIFACT_SCHEMA.md](docs/ARTIFACT_SCHEMA.md): versioned bundle contract shared by research and tester loops
- [docs/MANUAL_COPY_PASTE_PLAYBOOK.md](docs/MANUAL_COPY_PASTE_PLAYBOOK.md): manual trial framing, prompt structure, and evaluation protocol
- [docs/DEMO_FIXTURE_PLAN.md](docs/DEMO_FIXTURE_PLAN.md): capture checklist for the one-source / many-targets demo portfolio
- [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md): clean-build + TCC reset + artifact-capture procedure for Blink.app dogfood sessions
- [docs/EXPERIMENT_LOG.md](docs/EXPERIMENT_LOG.md): durable experiment history and outcomes
- [scratchpad/README.md](scratchpad/README.md): capture runner, fixture schema, sweep flow, and scratchpad-specific usage
- [scratchpad/tldr_reply/README.md](scratchpad/tldr_reply/README.md): isolated TL;DR + reply-suggestions hotkey experiment
- [scratchpad/eval_configs/README.md](scratchpad/eval_configs/README.md): config override format for offline sweeps
- [scratchpad/providers/README.md](scratchpad/providers/README.md): sweep-only provider adapters (Gemini + OpenAI-compatible)
- [app/README.md](app/README.md): tester-deployment channel (Swift app + bundled Python)
- [site/README.md](site/README.md): marketing landing page (Astro, static, Cloudflare Pages)

## Repository Map

- `docs/` contains the product brief, artifact schema, manual playbook, and experiment log
- `scratchpad/` contains the hotkey runner, shared Gemini request helpers, OCR wrapper, sweep runner, evaluation configs, and the `field_runs/` + `import_field_runs.py` bridge from the tester app
- `scratchpad/tldr_reply/` contains an isolated single-screenshot TL;DR + reply-suggestions experiment
- `app/` contains the signed/notarized Swift `.app` scaffolding, production Python (`app/python/`), resources, build scripts, and the XcodeGen spec
- `site/` is the standalone marketing landing page (Astro, static, deployed to Cloudflare Pages)
- `capture` is the repo-root wrapper for the resident capture runner
- `sweep` is the repo-root wrapper for the offline fixture sweep
- `tldr` is the repo-root wrapper for the TL;DR + reply-suggestions experiment

## Working Expectations

1. Start with a clear experiment hypothesis.
2. Prefer the fixture capture + sweep workflow over ad hoc prompt trials.
3. Keep changes minimal, reversible, and easy to inspect.
4. Record real experiment outcomes in `docs/EXPERIMENT_LOG.md`.
5. Update docs whenever the workflow or folder structure changes.
