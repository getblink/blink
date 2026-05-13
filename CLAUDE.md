# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

Start with:

- [README.md](README.md) for the public repo entrypoint
- [AGENTS.md](AGENTS.md) for agent-facing guardrails
- [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md) for internal workflows, Conductor setup/archive behavior, env-var sync across workspaces, scratchpad capture, sweeps, and release notes
- [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md) for clean Blink.app reinstall and TCC reset sessions
- [docs/BETA_SIGNUP_PLAYBOOK.md](docs/BETA_SIGNUP_PLAYBOOK.md) for the landing-page beta signup flow, Discord webhook, and post-submit response process
- [app/README.md](app/README.md) for the shipped macOS app
- [server/README.md](server/README.md) for the backend
- [site/README.md](site/README.md) for the landing page

## Current Product Shape

Blink is an early-stage local-first Mac assistant. The current shipped surface is the TL;DR + reply-suggestions loop in `app/`; the original intelligent copy-paste tester app is archived under `experiments/blink-copy-paste/`.

Keep protocol compatibility in mind: deployed clients still use `/v1/tldr` and `tldr_*` storage/token names. Do not rename those surfaces unless the task explicitly calls for a breaking protocol migration.

## Common Commands

```bash
python3 -m unittest discover app/python/tests
python3 -m compileall app/python
bash app/scripts/install_local_app.sh
cd server && pytest
cd site && npm run build
```

For public Sparkle releases, use `app/scripts/release.sh` and verify the log contains both `[blink] stamping SUFeedURL=...` and `[blink] stamping SUPublicEDKey ...`.

## Branches & deploys

`main` is the source of truth. Land changes via short-lived branches → PR to `main`. `staging` exists only as a Railway deploy mirror — fast-set it from `main` after merge (`git push origin +origin/main:staging`). Don't commit directly to `staging`; see [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md#branch-strategy) for the full anti-pattern this avoids.

Rebuilds and deploys are **independent**:

- `bash app/scripts/install_local_app.sh` rebuilds the macOS app only — does NOT redeploy the server.
- Pushing `staging` redeploys the server only — does NOT update the bundled app.

When a change touches both sides, you need both.

## Common edit-the-fallback gotchas

A few values exist in two places. The runtime-loaded copy beats the in-code default:

- **Prompt:** edit `server/prompt.txt` and `app/Resources/prompt.txt` together (byte-parity enforced). `DEFAULT_PROMPT` in `blink_once.py` is only a missing-file fallback.
- **Sampling params (`temperature`, `max_output_tokens`, `thinking_level`):** server-owned. Tune in `server/gemini.py:DEFAULT_SETTINGS` (or the `_for_model` overrides) and redeploy. The bundled `app/Resources/settings.json` only matters for the local-Gemini fallback path; `server/main.py:_selected_settings` ignores client-supplied sampling.
- **Gemini 3 `thinking_level` + `max_output_tokens`:** the two share one budget on Gemini 3 models. `high` thinking greedily fills the budget and truncates JSON output for short-response tasks. We're on `"low"` with `max_output_tokens=4096` for this reason.
