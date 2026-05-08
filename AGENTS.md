# AGENTS.md

This repository is optimized for agent collaboration on early-stage product discovery.

See also:

- [README.md](README.md) for the public repo entrypoint
- [CLAUDE.md](CLAUDE.md) for implementation-oriented guidance
- [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md) for internal workflows and Conductor behavior
- [docs/PROJECT_BRIEF.md](docs/PROJECT_BRIEF.md) for product scope and success criteria
- [docs/EXPERIMENT_LOG.md](docs/EXPERIMENT_LOG.md) for durable experiment history
- [scratchpad/README.md](scratchpad/README.md) for capture and sweep workflow details

## Mission

Build toward a trustworthy, local-first cross-app assistant, starting with one validated capability: intelligent copy-paste.

## Operating Principles

- Source of truth: GitHub-first repository state.
- Clean structure first: keep module and folder ownership obvious.
- Experiments over builds: learning signal beats feature count.
- Manual before automation: validate outputs by hand before adding plumbing.
- Single-focus discipline: deeply validate one magical moment before expanding scope.
- Profile before optimizing: measure actual bottlenecks.

## Engineering Guidelines

- Keep changes minimal, reversible, and well-scoped.
- Avoid premature abstraction and framework-heavy setups.
- Prefer simple scripts and notes for early validation.
- Do not add background daemons, hotkeys, or polished UI until manual value is proven.
- Favor additive iteration with clear experiment boundaries; do not delete prior learning artifacts unless explicitly requested.
- Keep deployed protocol surfaces stable: `/v1/tldr`, `tldr_*` tables/caches, and `tldr_dt_*` token prefixes are deliberately frozen v1 names.
- When debugging Conductor hooks, check `.context/conductor/setup-receipt.json` and `~/conductor/archive/blink/_archive_runs.jsonl` before assuming setup or archive failed.
- When validating `app/` locally, use `bash app/scripts/install_local_app.sh` and launch only `~/Applications/Blink.app`. Do not run Blink from `DerivedData` or `app/build`.
- For a full clean-build + TCC-reset dogfood session, follow [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md).
- Cutting a public Sparkle release goes through `app/scripts/release.sh`; see [app/README.md](app/README.md#sparkle-releases).

## Documentation Requirements

When running experiments, update `docs/EXPERIMENT_LOG.md` with date, hypothesis, setup, result, decision, and next step.

If introducing any new folder/module, document purpose in either `README.md` for top-level paths or a local README inside that folder.

When workflow changes, update the relevant root or internal documentation:

- `README.md` for public-facing quickstart and navigation
- `CLAUDE.md` and `AGENTS.md` for agent execution guidance
- `docs/CONTRIBUTING_INTERNAL.md` for internal workflow details
- `docs/` for product and experiment context
