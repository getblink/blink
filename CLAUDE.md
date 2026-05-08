# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See also:

- `README.md` for the repo-level quickstart and documentation tree
- `AGENTS.md` for operating principles that apply to all coding agents
- `docs/PROJECT_BRIEF.md` for product scope and success criteria
- `docs/ARTIFACT_SCHEMA.md` for the versioned bundle contract shared across the research and tester-deployment loops
- `docs/DOGFOOD_PLAYBOOK.md` for the "clean build + clean permissions + capture everything" procedure when reinstalling `Blink.app` for a dogfood session
- `scratchpad/README.md` for the current capture and sweep workflow
- `app/README.md` for the Swift tester-deployment channel (`Blink.app` + bundled Python)
- `tldr_app/README.md` for the shipped TLDR.app surface (`TLDR.app` + bundled Python)

## What is Blink

Blink is an early-stage experiment exploring a local, cross-app AI assistant that carries context between applications. The current focus is **intelligent copy-paste**: given a source screenshot and a target field screenshot, a vision model suggests the correct text to paste.

This project is in **experiments-over-builds** mode. Manual validation comes before automation. Do not add polished UI, background daemons, or broad infrastructure unless explicitly asked.

## Repository layout

- `README.md` — repo-level entrypoint and documentation map
- `AGENTS.md` — operating principles and documentation requirements for agents
- `conductor.json` — Conductor repo config, wires setup/archive scripts
- `.conductor/`
  - `setup.sh` — creates venv, installs deps, validates `scratchpad/settings.json`, links `scratchpad/fixtures` into the shared fixture pool, copies `.env` from the shared source repo on new-workspace creation, and writes `.context/conductor/setup-receipt.json`
  - `archive.sh` — preserves `scratchpad/{sweeps,runs}` and copies fixtures into self-contained archive bundles before Conductor deletes the workspace, while appending `~/conductor/archive/blink/_archive_runs.jsonl` and writing `archive-receipt.json` into preserved bundles
  - `migrate_fixtures.sh` — one-shot helper that moves a pre-existing local `scratchpad/fixtures/` directory into the shared pool, then replaces it with a symlink
- `docs/`
  - `PROJECT_BRIEF.md` — product scope, constraints, and success criteria
  - `MANUAL_COPY_PASTE_PLAYBOOK.md` — manual evaluation protocol
  - `EXPERIMENT_LOG.md` — durable record of experiments and outcomes
  - `ARTIFACT_SCHEMA.md` — versioned fixture/run bundle contract shared by the research and tester-deployment loops
  - `DEMO_FIXTURE_PLAN.md` — capture checklist for the one-source / many-targets demo portfolio
  - `DOGFOOD_PLAYBOOK.md` — clean-build + TCC reset + artifact-capture procedure for `Blink.app` dogfood sessions
- `capture` — repo-root wrapper for the resident hotkey runner
- `sweep` — repo-root wrapper for the offline fixture sweep
- `tldr` — repo-root wrapper for the isolated TL;DR + reply-suggestions experiment
- `scratchpad/`
  - `README.md` — scratchpad-specific workflow and artifact layout
  - `run_gemini_trial.py` — primary resident capture runner; also owns `normalize_for_paste()` for clipboard-side post-processing
  - `gemini_runner.py` — shared Gemini request-building and generation helpers
  - `ocr.py` — Vision OCR wrapper used during fixture capture
  - `eval_sweep.py` — offline fixture x config sweep runner
  - `env_loader.py` — loads `.env` and `.env.local` from repo root
  - `eval_configs/` — small JSON config variants for sweeps
  - `providers/` — sweep-only provider adapters (Gemini + OpenAI-compatible); the live runner stays Gemini-only
  - `hotkey.py` — macOS Quartz-based global hotkey listener used by the runner
  - `make_trial.py` — optional standalone packet generator kept for older/manual flows
  - `prompt.txt` — current base prompt template for the clipboard assistant
  - `import_field_runs.py` — ingests tester-exported zip/dir bundles from `Blink.app` into `field_runs/`
  - `field_runs/` — landing zone for imported tester bundles; replayable by `./sweep` like any fixture
  - `tldr_reply/` — single-screenshot TL;DR + reply-suggestions experiment with its own hotkey loop and overlay
  - `tests/` — unit tests (e.g. `test_normalize_for_paste.py`); run with `scratchpad/.venv/bin/python -m unittest discover scratchpad/tests`
  - `fixtures` — symlink to `~/conductor/shared/blink/fixtures/` in the default shared-pool workflow, or a real directory in deliberately forked workspaces
  - `.venv/` — Python 3.11 virtualenv (gitignored)
- `server/` — Railway-ready TLDR backend. `server/main.py` exposes `/healthz`, `/v1/tldr`, `/v1/tldr/events`, and the legacy `/tldr` wrapper; `server/gemini.py` is a deliberate fork of `scratchpad/tldr_reply/gemini.py`, and `server/README.md` documents deploy + local dev.
- `app/` — Swift tester-deployment channel (`Blink.app`) paired with a forked production Python runtime in `app/python/` and a canonical local installer at `app/scripts/install_local_app.sh`; see `app/README.md` and the bundle contract in `docs/ARTIFACT_SCHEMA.md`. No runtime coupling with `scratchpad/` — `app/python/gemini_runner.py` is a deliberate fork at a pinned SHA.
- `tldr_app/` — shipped TLDR.app surface paired with a focused Python runner in `tldr_app/python/`. Swift owns the menubar, `ctrl+shift+t` hotkey, ScreenCaptureKit capture, request envelope + event diagnostics, pending-run tracking, non-activating overlay, expand-first numbered choices, copy, and Return-to-insert behavior; Python owns request execution plus run artifacts under `~/Library/Application Support/TLDR/runs/`. Single press submits instantly; a second press within ~400ms promotes the run into multi-frame collecting mode that accepts any frontmost window or app per frame (`capture_mode: multi_window`), with per-frame `frontmost_app` metadata in the request envelope.
- `site/` — Standalone marketing landing page. Astro, static output, deploys to Cloudflare Pages with no adapter (see `site/README.md`). Independent from the research and tester channels.

## Development setup

New workspaces created in Conductor bootstrap themselves via `conductor.json` → `.conductor/setup.sh`: it creates the venv, installs deps, verifies `scratchpad/settings.json` still uses `fixtures_dir: "fixtures"`, points `scratchpad/fixtures` at the shared pool in `~/conductor/shared/blink/fixtures/`, and copies `.env` from `$CONDUCTOR_ROOT_PATH/.env` (the shared source repo, typically `~/conductor/repos/blink/.env`). Seed that canonical `.env` once on the machine and every future workspace inherits the key.

Successful setup runs leave a receipt at `.context/conductor/setup-receipt.json`, which is the fastest way to confirm the repo-level Conductor `setup` hook actually fired in a workspace.

If a workspace captured fixtures before setup ran, or if you intentionally kept a populated local `scratchpad/fixtures/` directory, run `bash .conductor/migrate_fixtures.sh` to move that corpus into the shared pool. If you need a schema-incompatible fixture fork, replace the symlink with a real directory copy; `setup.sh` will leave populated local fixture directories alone, and `archive.sh` will preserve them verbatim on archive.

For a plain (non-Conductor) clone, do it by hand:

```bash
python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install -r scratchpad/requirements.txt
```

Key dependencies: `google-genai` (Gemini API), `pyobjc-framework-Quartz` (macOS event tap for hotkeys), and `pyobjc-framework-Vision` (OCR during fixture capture).

When a Conductor workspace is archived, `.conductor/archive.sh` always preserves `scratchpad/sweeps/` and `scratchpad/runs/`, then copies fixtures into the archive when needed so archived `compare.html` and `summary.md` outputs still resolve their relative fixture image links. Forked workspaces with a real `scratchpad/fixtures/` directory are preserved as-is. Every archive run also appends a receipt to `~/conductor/archive/blink/_archive_runs.jsonl`, and preserved bundles include their own `archive-receipt.json`.

## Running scripts

Store `GEMINI_API_KEY=...` in the repo-root `.env` file or export it in the shell, then use the current workflow:

```bash
./capture
```

While the runner is active:

- `ctrl+shift+c` captures a new source window
- `ctrl+shift+v` captures a target fixture and optionally runs a live Gemini preview
- `ctrl+c` in the terminal quits the runner

To compare saved fixtures offline:

```bash
./sweep --fixtures 'scratchpad/fixtures/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/<name>
```

Open `compare.html` and `summary.md` in the output directory to review the sweep.

To run the isolated TL;DR + reply-suggestions experiment:

```bash
./tldr
```

While it is active, `ctrl+shift+t` captures a selected window, asks Gemini for a
one-line summary plus three candidate replies, and shows a small overlay where
`1` / `2` / `3` expand a suggestion first; pressing the same number again copies
it to the clipboard.

For TLDR compression/OCR sweeps, capture fixtures with
`./tldr --save-fixture scratchpad/tldr_reply/fixtures/<slug>`, then run
`python scratchpad/tldr_reply/eval_sweep.py --fixtures 'scratchpad/tldr_reply/fixtures/*' --configs 'scratchpad/eval_configs/tldr_*.json' --out scratchpad/sweeps/tldr_{auto-timestamp}`.

`make_trial.py` is still available, but it is now a secondary/manual path rather than the primary workflow.

To build and dogfood the shipped TLDR app:

```bash
python3 -m unittest discover tldr_app/python/tests
python3 -m compileall tldr_app/python
bash tldr_app/scripts/install_local_app.sh
```

The canonical local app is `~/Applications/TLDR.app`, with bundle ID
`com.henryz2004.tldr`. Runtime overrides and secrets live in `~/.tldr/`
(`runtime-config.json`, `settings.json`, `prompts/prompt.txt`, `.env`), and
local DMGs are produced with `bash tldr_app/scripts/make_dmg.sh`. Pending run
records for crash recovery live under `~/Library/Application Support/TLDR/pending/`.
If `BLINK_PROXY_URL` + `BLINK_PROXY_TOKEN` are present in `~/.tldr/.env`, the
packaged flow calls the standalone TLDR server and uploads request/event
diagnostics; otherwise it falls back to direct Gemini. Set
`TLDR_DISABLE_PROXY=1` in `~/.tldr/.env` to force direct-Gemini routing even
when proxy credentials are populated (or supplied via a bundled
`Resources/proxy.env`); useful when iterating on the bundled prompt locally
without redeploying the server. The installer resets TCC
on every rebuild so permissions attach to the fresh canonical binary; use
`--skip-tcc-reset` only for non-dogfood script checks.

Public Sparkle releases (signed/notarized DMG + appcast uploaded to Cloudflare
R2) go through `tldr_app/scripts/release.sh`. Bump
`tldr_app/project.yml`'s `CFBundleShortVersionString` (xcodegen rewrites
`Info.plist` from this on every build, so editing `Info.plist` directly is
wiped), export the repo-root `.env` so the scripts inherit the credentials
(`set -a && source .env && set +a`), then run the script. The build log must
show `[tldr] stamping SUFeedURL=...` and `[tldr] stamping SUPublicEDKey ...`
— if either line is missing, `TLDR_SPARKLE_FEED_URL` / `TLDR_SPARKLE_PUBLIC_ED_KEY`
were unset and the build will ship as a Sparkle dead-end. See
`tldr_app/README.md` → Sparkle Releases for the full env-var list, the
`sign_update` chicken-and-egg on first run in a fresh workspace, and the
`TLDR_SIGN_IDENTITY` SHA-1 pin needed when keychain holds duplicate
"Developer ID Application" certs for the same team.

Tester-deployment bundles (the `app/` channel) are produced by `app/python/run_once.py`, either spawned from `Blink.app` or invoked directly. It emits schema-v1 bundles (`fixture.json` + `source.png` + `target.png` + `run.json` + `output.txt`, plus `target_metadata.json` and `settings.json`) that `./sweep` replays unchanged. Tester zips exported from `Blink.app` land under `scratchpad/field_runs/` via `python scratchpad/import_field_runs.py <zip-or-dir>`.

For Blink.app local testing or profiling, prefer the canonical installer:

```bash
bash app/scripts/install_local_app.sh
```

That script fetches `app/python-dist` on first run, builds a self-contained
Release app, installs it to `~/Applications/Blink.app`, and moves duplicate
Blink bundles from `DerivedData` / `app/build` into `.context/disabled-apps/`
so Spotlight and TCC do not get confused by multiple local installs. After
Swift app-code changes, pass `--reset-tcc` before trusting the next launch's
Accessibility/Input Monitoring state; the System Settings toggle can stay on
while the grant is still effectively tied to the older binary.

When the user asks for a "clean build" or a Blink.app dogfood reinstall,
follow `docs/DOGFOOD_PLAYBOOK.md` — it covers the one-command install, TCC
reset, verification, and where fixtures / profiling / `host_profile.json` /
debug logs land.

## Key conventions

- Record experiment outcomes in `docs/EXPERIMENT_LOG.md` with: date, hypothesis, setup, result, decision, next step.
- Keep changes minimal, reversible, and well-scoped. Avoid premature abstraction.
- Favor additive iteration; do not delete prior learning artifacts unless explicitly asked.
- New folders/modules need a README or documentation in `README.md`.
- Treat `README.md`, `CLAUDE.md`, and `AGENTS.md` as the root documentation layer. If one changes meaningfully, check whether the others need matching updates.
- `scratchpad/prompt.txt` is the live runner prompt; if prompt changes alter the manual packet-generator story, update `make_trial.py:render_prompt()` and `docs/MANUAL_COPY_PASTE_PLAYBOOK.md` deliberately rather than assuming they stay in sync automatically.
