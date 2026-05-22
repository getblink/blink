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

`main` and `staging` are kept **in sync** — same tip, every release. `staging` is what Railway deploys, so the easiest way to dogfood a change is to fast-set `staging` to your feature branch first (`git push origin +my-branch:staging`), then PR to `main` once it's validated, then fast-set `staging` back to `main` (`git push origin +origin/main:staging`) so the two pointers match again. After every release the invariant `origin/main == origin/staging` should hold; divergence is a bug, not a workflow. See [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md#branch-strategy) for the full workflow and the anti-patterns to avoid.

Rebuilds and deploys are **independent**:

- `bash app/scripts/install_local_app.sh` rebuilds the macOS app only — does NOT redeploy the server.
- Pushing `staging` redeploys the server only — does NOT update the bundled app.

When a change touches both sides, you need both.

## Common edit-the-fallback gotchas

A few values exist in two places. The runtime-loaded copy beats the in-code default:

- **Prompt:** edit `server/prompt.txt` and `app/Resources/prompt.txt` together (byte-parity enforced). `DEFAULT_PROMPT` in `blink_once.py` is only a missing-file fallback.
- **Sampling params (`temperature`, `max_output_tokens`):** server-owned. Tune in `server/gemini.py:DEFAULT_SETTINGS` (or the `_for_model` overrides) and redeploy. `server/main.py:_selected_settings` ignores client-supplied values for these.
- **`thinking_level`:** the one sampling knob the client controls. The macOS "Reasoning" picker (`ReasoningLevels`) sends `low`/`medium`/`high` in `preferences.thinking_level`; the server validates against that allowlist and forwards to Gemini. Unset falls back to `thinking_level_for_model` (currently `"low"` on Gemini 3). If you touch the proxy path in `blink_once.py`, don't strip `preferences.thinking_level` before upload — the Swift app puts it there and stomping the dict re-introduces the "Reasoning picker does nothing" bug.
- The bundled `app/Resources/settings.json` only matters for the local-Gemini fallback path.
- **Gemini 3 `thinking_level` + `max_output_tokens`:** the two share one budget on Gemini 3 models. `high` thinking greedily fills the budget and truncates JSON output for short-response tasks. The default is `"low"` with `max_output_tokens=4096`; a user opting into `medium`/`high` via the Reasoning picker accepts this tradeoff.
