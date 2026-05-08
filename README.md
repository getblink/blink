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
./blink
```

`./blink` and `./blink-ui` run the experimental Python loop in
`scratchpad/tldr_reply/`; to run the shipped Blink.app, use
`bash app/scripts/install_local_app.sh`. The experiment listens for
`ctrl+shift+t`, captures one selected window, asks Gemini for a one-line summary
plus three reply candidates, and shows them in a small overlay. Artifacts land
under `scratchpad/tldr_runs/`; if `BLINK_PROXY_URL` and `BLINK_PROXY_TOKEN` are
set, the request routes through the standalone Blink server instead of direct
Gemini. Use `./blink --save-fixture <dir>` plus
`scratchpad/tldr_reply/eval_sweep.py` for compression/OCR fixture sweeps. See
[`scratchpad/tldr_reply/`](scratchpad/tldr_reply/README.md).

## Blink.app (`app/`)

`Blink.app` is the shipped surface for the TL;DR + reply-suggestions loop. It
lives under [`app/`](app/README.md). The older intelligent copy-paste tester app
has been archived under [`experiments/blink-copy-paste/`](experiments/blink-copy-paste/README.md),
and the root `./blink` wrapper remains a scratchpad harness.

The Swift app owns the menubar item, permissions, the configurable summary hotkey (default `ctrl+opt+space`),
ScreenCaptureKit frontmost-window capture, non-activating overlay, numbered
choice handling, copy, and Return-to-insert behavior. It now also emits a
server-oriented request envelope, image diagnostics, focused-context metadata,
pending-run records, and event telemetry. Number keys expand first; pressing
the same number again copies, Return inserts the expanded suggestion, Return
with no expanded suggestion falls through to the focused app, and Esc dismisses.
The bundled Python runner owns the request execution path and per-run artifact
bundle. Local identity is:

- App: `~/Applications/Blink.app`
- Bundle ID: `com.henryz2004.blink`
- Runtime config/secrets: `~/.blink/`
- Runs: `~/Library/Application Support/Blink/runs/`
- Pending run records: `~/Library/Application Support/Blink/pending/`

Useful commands:

```bash
python3 -m unittest discover app/python/tests
python3 -m compileall app/python
bash app/scripts/install_local_app.sh
bash app/scripts/make_dmg.sh
```

The installer resets Blink's TCC permissions on every rebuild so Accessibility,
Input Monitoring, and Screen Recording attach to the fresh binary.

Cutting a Sparkle release (signed, notarized DMG + appcast on Cloudflare R2)
goes through `app/scripts/release.sh`. Bump
`app/project.yml`'s `CFBundleShortVersionString`, export the repo-root
`.env` (which holds Apple/Sparkle/R2 credentials), then run the script. See
[`app/README.md` → Sparkle Releases](app/README.md#sparkle-releases)
for the required env vars and known gotchas (Sparkle `sign_update`
chicken-and-egg, duplicate-cert disambiguation via `BLINK_SIGN_IDENTITY`).

In Conductor workspaces, `scratchpad/fixtures` points at a shared pool in `~/conductor/shared/blink/fixtures/`, so new workspaces inherit the full captured corpus automatically while archived sweeps still remain self-contained.

Conductor hook receipts now make it easy to sanity-check execution: setup writes `.context/conductor/setup-receipt.json`, and archive appends `~/conductor/archive/blink/_archive_runs.jsonl` plus `archive-receipt.json` inside each preserved archive bundle.

## Current focus

- **In scope:** intelligent copy-paste
- **Out of scope for now:** autocomplete, intent feeds, polished UI, background automation
- **Working style:** experiments over builds, manual validation before productization

## Documentation Tree

- [AGENTS.md](AGENTS.md): repo operating rules and documentation expectations for coding agents
- [CLAUDE.md](CLAUDE.md): implementation-oriented repo guide, layout, and current script workflow
- [docs/PROJECT_BRIEF.md](docs/PROJECT_BRIEF.md): product scope, success criteria, constraints, and phase goals
- [docs/ARTIFACT_SCHEMA.md](docs/ARTIFACT_SCHEMA.md): versioned bundle contract shared by the research loop and archived copy-paste tester
- [docs/MANUAL_COPY_PASTE_PLAYBOOK.md](docs/MANUAL_COPY_PASTE_PLAYBOOK.md): manual trial framing, prompt structure, and evaluation protocol
- [docs/DEMO_FIXTURE_PLAN.md](docs/DEMO_FIXTURE_PLAN.md): capture checklist for the one-source / many-targets demo portfolio
- [docs/DOGFOOD_PLAYBOOK.md](docs/DOGFOOD_PLAYBOOK.md): clean-build + TCC reset + artifact-capture procedure for Blink.app dogfood sessions
- [docs/EXPERIMENT_LOG.md](docs/EXPERIMENT_LOG.md): durable experiment history and outcomes
- [scratchpad/README.md](scratchpad/README.md): capture runner, fixture schema, sweep flow, and scratchpad-specific usage
- [scratchpad/tldr_reply/README.md](scratchpad/tldr_reply/README.md): isolated TL;DR + reply-suggestions hotkey experiment
- [server/README.md](server/README.md): Railway-ready Blink backend for server-owned prompt/model/key handling plus request/event diagnostics
- [docs/SERVER_CONTRACT.md](docs/SERVER_CONTRACT.md): HTTP contract for the standalone Blink client
- [scratchpad/eval_configs/README.md](scratchpad/eval_configs/README.md): config override format for offline sweeps
- [scratchpad/providers/README.md](scratchpad/providers/README.md): sweep-only provider adapters (Gemini + OpenAI-compatible)
- [app/README.md](app/README.md): shipped Blink.app surface (Swift app + bundled Python)
- [experiments/blink-copy-paste/README.md](experiments/blink-copy-paste/README.md): archived intelligent copy-paste tester app
- [site/README.md](site/README.md): marketing landing page (Astro, static, Cloudflare Pages)

## Repository Map

- `docs/` contains the product brief, artifact schema, manual playbook, and experiment log
- `scratchpad/` contains the hotkey runner, shared Gemini request helpers, OCR wrapper, sweep runner, evaluation configs, and the `field_runs/` + `import_field_runs.py` bridge from archived copy-paste tester exports
- `scratchpad/tldr_reply/` contains an isolated single-screenshot TL;DR + reply-suggestions experiment
- `server/` contains the standalone Blink backend: FastAPI app, Railway Procfile, Gemini fork, and deploy notes
- `app/` contains the Blink.app Swift surface, bundled Python runner, resources, build/install/DMG scripts, and XcodeGen spec
- `experiments/blink-copy-paste/` contains the archived intelligent copy-paste tester app kept buildable for fixture replay
- `site/` is the standalone marketing landing page (Astro, static, deployed to Cloudflare Pages)
- `capture` is the repo-root wrapper for the resident capture runner
- `sweep` is the repo-root wrapper for the offline fixture sweep
- `blink` is the repo-root wrapper for the TL;DR + reply-suggestions experiment

## Working Expectations

1. Start with a clear experiment hypothesis.
2. Prefer the fixture capture + sweep workflow over ad hoc prompt trials.
3. Keep changes minimal, reversible, and easy to inspect.
4. Record real experiment outcomes in `docs/EXPERIMENT_LOG.md`.
5. Update docs whenever the workflow or folder structure changes.
