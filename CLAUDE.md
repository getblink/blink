# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

Start with:

- [README.md](README.md) for the public repo entrypoint
- [AGENTS.md](AGENTS.md) for agent-facing guardrails
- [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md) for internal workflows, Conductor setup/archive behavior, env-var sync across workspaces, scratchpad capture, sweeps, and release notes
- [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md) for clean Blink.app reinstall and TCC reset sessions
- [docs/BETA_SIGNUP_PLAYBOOK.md](docs/BETA_SIGNUP_PLAYBOOK.md) for the landing-page beta signup flow, Discord webhook, and post-submit response process
- [docs/CONTENT_PLAYBOOK.md](docs/CONTENT_PLAYBOOK.md) for the blog content flywheel — publishing a post and the monthly metrics check
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

`staging` is the **trunk** — the always-current branch where all work lands and accumulates. `main` is **downstream of `staging`**: it is advanced *from* `staging` at release time (`main` ← `staging`), never the reverse, so between releases `main` legitimately **lags** `staging` by however many commits haven't been promoted yet. That lag is normal, not drift. Two rules follow: **branch new work off `staging`, never off `main`** (a stale `main` is expected), and **never move `staging` backward to match `main`** — `git push origin +origin/main:staging` force-resets the trunk to a usually-behind `main` and silently drops everything accumulated on it. A push to `staging` or `main` runs the [`deploy-server.yml`](.github/workflows/deploy-server.yml) GitHub Action, which deploys `server/` to **Google Cloud Run** (project `blink-497308`, region `us-west1`): `staging` → service `blink-server-staging` at `https://api-staging.useblink.dev`, `main` → `blink-server` at `https://api.useblink.dev`. The deploy fires **only when files under `server/**` change**. To dogfood a server change, land it on `staging` (branch off `origin/staging`, then fast-forward: `git push origin HEAD:staging`) and dogfood against api-staging; promote to production by opening a PR to `main` (`gh pr create --base main`) once validated. Confirm a deploy landed with `curl -s https://api-staging.useblink.dev/v1/healthz` — the `version` field is the deployed commit SHA. See [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md#branch-strategy) for the full workflow and the anti-patterns to avoid.

Rebuilds and deploys are **independent**:

- `bash app/scripts/install_local_app.sh` rebuilds the macOS app only — does NOT redeploy the server.
- Pushing `staging` redeploys the server only, and only when `server/**` changed — does NOT update the bundled app.

When a change touches both sides, you need both.

## Common edit-the-fallback gotchas

A few values exist in two places. The runtime-loaded copy beats the in-code default:

- **Prompt:** edit `server/prompt.txt` and `app/Resources/prompt.txt` together (byte-parity enforced). `DEFAULT_PROMPT` in `blink_once.py` is only a missing-file fallback.
- **Sampling params (`temperature`, `max_output_tokens`):** server-owned. Tune in `server/gemini.py:DEFAULT_SETTINGS` (or the `_for_model` overrides) and redeploy. `server/main.py:_selected_settings` ignores client-supplied values for these.
- **`thinking_level`:** the one sampling knob the client controls. The macOS "Reasoning" picker (`ReasoningLevels`) sends `low`/`medium`/`high` in `preferences.thinking_level`; the server validates against that allowlist and forwards to Gemini. Unset falls back to `thinking_level_for_model` (currently `"low"` on Gemini 3). If you touch the proxy path in `blink_once.py`, don't strip `preferences.thinking_level` before upload — the Swift app puts it there and stomping the dict re-introduces the "Reasoning picker does nothing" bug.
- The bundled `app/Resources/settings.json` only matters for the local-Gemini fallback path.
- **Gemini 3 `thinking_level` + `max_output_tokens`:** the two share one budget on Gemini 3 models. `high` thinking greedily fills the budget and truncates JSON output for short-response tasks. The default is `"low"` with `max_output_tokens=4096`; a user opting into `medium`/`high` via the Reasoning picker accepts this tradeoff.
