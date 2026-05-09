# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with this repository.

Start with:

- [README.md](README.md) for the public repo entrypoint
- [AGENTS.md](AGENTS.md) for agent-facing guardrails
- [docs/CONTRIBUTING_INTERNAL.md](docs/CONTRIBUTING_INTERNAL.md) for internal workflows, Conductor setup/archive behavior, env-var sync across workspaces, scratchpad capture, sweeps, and release notes
- [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md) for clean Blink.app reinstall and TCC reset sessions
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
