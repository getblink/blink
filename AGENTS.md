# AGENTS.md

This repository is optimized for agent collaboration on early-stage product discovery.

See also:

- `README.md` for the repo quickstart and documentation tree
- `CLAUDE.md` for the implementation-oriented repo guide and current script flow
- `docs/PROJECT_BRIEF.md` for product scope and success criteria
- `docs/EXPERIMENT_LOG.md` for the durable experiment history
- `scratchpad/README.md` for the current capture and sweep workflow

## Mission

Build toward a trustworthy, local-first cross-app assistant, starting with one validated capability:

- **Intelligent copy-paste** (first priority)

## Operating principles

- **Source of truth:** GitHub-first repository state.
- **Clean structure first:** Keep module and folder ownership obvious.
- **Experiments over builds:** Learning signal beats feature count.
- **Manual before automation:** Validate outputs by hand before adding plumbing.
- **Single-focus discipline:** Deeply validate one magical moment before expanding scope.
- **Profile before optimizing:** Measure actual bottlenecks.

## Engineering guidelines

- Keep changes minimal, reversible, and well-scoped.
- Avoid premature abstraction and framework-heavy setups.
- Prefer simple scripts and notes for early validation.
- Do not add background daemons, hotkeys, or polished UI until manual value is proven.
- Favor additive iteration with clear experiment boundaries; do not delete prior learning artifacts unless explicitly requested.
- When debugging Conductor hooks, check `.context/conductor/setup-receipt.json` and `~/conductor/archive/blink/_archive_runs.jsonl` before assuming setup or archive failed to run.
- When validating `app/` locally, use `bash app/scripts/install_local_app.sh` and launch only `~/Applications/Blink.app`; do not run Blink from `DerivedData` or `app/build`, since macOS may treat those as separate installs for Spotlight/TCC. After Swift app-code changes, reinstall with `bash app/scripts/install_local_app.sh --reset-tcc` before trusting the permissions state again: Accessibility can stay toggled on while effectively still attached to the older binary. For a full clean-build + TCC-reset dogfood session, follow `docs/DOGFOOD_PLAYBOOK.md`.

## Documentation requirements

When running experiments, update `docs/EXPERIMENT_LOG.md` with:

- Date
- Hypothesis
- Setup
- Result
- Decision
- Next step

If introducing any new folder/module, document purpose in either:

- `README.md` (for top-level), or
- a local README inside that folder.

When workflow changes, update the root documentation layer as needed:

- `README.md` for user-facing quickstart and navigation
- `CLAUDE.md` for repo layout and implementation workflow
- `AGENTS.md` for agent-facing guardrails

Preferred documentation chain:

1. `README.md` as the repo entrypoint
2. `CLAUDE.md` and `AGENTS.md` as execution guidance
3. `docs/` for product and experiment context
4. local READMEs for folder-specific operational detail

## Priority order for upcoming work

1. Validate intelligent copy-paste manually.
2. Build minimal support tooling for repeatable evaluation.
3. Reassess whether to expand into autocomplete or intent.
