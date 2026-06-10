# AGENTS.md

This repository is optimized for agent collaboration on early-stage product discovery.

See also:

- [README.md](README.md) for the public repo entrypoint
- [CLAUDE.md](CLAUDE.md) for implementation-oriented guidance
- [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md) for internal workflows, Conductor behavior, and env-var sync across workspaces
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
- `staging` is the trunk: branch new work off `origin/staging` and land it there (fast-forward: `git push origin HEAD:staging`); promote to `main` via PR (`gh pr create --base main`) at release time. `main` legitimately lags `staging` between releases. NEVER force-reset `staging` from `main` (`git push origin +origin/main:staging` silently drops everything accumulated on the trunk — this has destroyed work before). Both branches deploy to Cloud Run via `.github/workflows/deploy-server.yml` when `server/**` changes. See [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md#branch-strategy).
- Rebuilds and deploys are independent: `install_local_app.sh` only rebuilds the app; pushing `staging` only redeploys the server. Changes touching both need both.
- Runtime config has *two-copy* footguns. The loaded file beats the in-code default:
  - Prompts: edit `server/prompt.txt` and `app/Resources/prompt.txt` together (parity test enforces).
  - Sampling: `temperature` and `max_output_tokens` are server-owned. Tune `server/gemini.py:DEFAULT_SETTINGS` and redeploy; client values for these are ignored by `_selected_settings`.
  - `thinking_level` is the one client-overridable knob. The macOS "Reasoning" picker sends `low`/`medium`/`high` in `preferences.thinking_level`; the server validates and forwards. Don't strip `preferences` in `blink_once.py`'s proxy path or the picker silently does nothing.
  - Gemini 3 `thinking_level` + `max_output_tokens` share one budget; `high` thinking truncates short-response JSON. Default is `"low"` with 4096 tokens; a user opting into `medium`/`high` accepts that tradeoff.
- When debugging Conductor hooks, check `.context/conductor/setup-receipt.json` and `~/conductor/archive/blink/_archive_runs.jsonl` before assuming setup or archive failed.
- When rotating credentials or adding env vars, edit `~/conductor/repos/blink/.env` (the canonical source) and then run `~/conductor/repos/blink/.conductor/sync_env.sh` to propagate to existing workspaces. New workspaces inherit it automatically via `setup.sh`.
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
