# Internal Contributor Notes

These notes preserve the repo-internal workflow guidance that used to live in the public README layer.

## Mission

Build toward a trustworthy, local-first cross-app assistant, starting with one validated capability: intelligent copy-paste.

## Operating Principles

- Source of truth: GitHub-first repository state.
- Clean structure first: keep module and folder ownership obvious.
- Experiments over builds: learning signal beats feature count.
- Manual before automation: validate outputs by hand before adding plumbing.
- Single-focus discipline: deeply validate one magical moment before expanding scope.
- Profile before optimizing: measure actual bottlenecks.

## Local Research Loop

Put `GEMINI_API_KEY=...` in `.env` at the repo root, then create the scratchpad virtualenv:

```bash
python3.11 -m venv scratchpad/.venv
scratchpad/.venv/bin/pip install -r scratchpad/requirements.txt
```

Run the resident capture loop:

```bash
./capture
```

While the runner is active, `ctrl+shift+c` captures a source window and `ctrl+shift+v` captures a target fixture. Saved fixtures land under `scratchpad/fixtures/`.

Sweep saved fixtures against config variants:

```bash
./sweep --fixtures 'scratchpad/fixtures/*' --configs 'scratchpad/eval_configs/*.json' --out scratchpad/sweeps/<name>
```

Review `compare.html` and `summary.md` in the sweep output.

## Blink.app Dogfood Loop

`Blink.app` is the shipped surface. The root `./blink` wrapper remains a scratchpad harness.

Useful commands:

```bash
python3 -m unittest discover app/python/tests
python3 -m compileall app/python
bash app/scripts/install_local_app.sh
bash app/scripts/make_dmg.sh
```

The canonical local app is `~/Applications/Blink.app`, with bundle ID `com.henryz2004.blink`. Runtime config and secrets live in `~/.blink/`; run artifacts live under `~/Library/Application Support/Blink/runs/`.

Use `bash app/scripts/install_local_app.sh` for local validation. The installer resets TCC by default so Accessibility, Input Monitoring, and Screen Recording attach to the fresh binary. Follow [DOGFOOD_PLAYBOOK.md](DOGFOOD_PLAYBOOK.md) for a full clean-build and TCC-reset session.

## Release Notes

Cutting a public Sparkle release goes through `app/scripts/release.sh`. Bump `app/project.yml`'s `CFBundleShortVersionString`; XcodeGen rewrites `Info.plist` from `project.yml`, so editing `Info.plist` directly is wiped.

One-time host prerequisite: install Sparkle's CLI tools so `release.sh` can sign the update. The Homebrew cask `sparkle` no longer ships them as of 2.9 — pull them from the official tarball:

```bash
cd /tmp && gh release download 2.9.1 --repo sparkle-project/Sparkle -p 'Sparkle-*.tar.xz' && tar -xf Sparkle-2.9.1.tar.xz
sudo install /tmp/bin/sign_update      /usr/local/bin/sign_update
sudo install /tmp/bin/generate_appcast /usr/local/bin/generate_appcast
which sign_update   # /usr/local/bin/sign_update
```

Without this, `release.sh` exits with `error: set BLINK_SPARKLE_SIGN_UPDATE to Sparkle's sign_update tool` because its sign-tool check runs before `build.sh` resolves the SPM package that would otherwise produce a workspace-local copy.

Export the repo-root `.env` before invoking the script:

```bash
set -a && source .env && set +a
bash app/scripts/release.sh
```

The build log must contain `[blink] stamping SUFeedURL=...` and `[blink] stamping SUPublicEDKey ...`. A missing line means the new build cannot discover or verify future updates and must not be uploaded.

## Conductor Workspaces

New Conductor workspaces bootstrap via `conductor.json` and `.conductor/setup.sh`. Setup creates the virtualenv, installs dependencies, validates `scratchpad/settings.json`, links `scratchpad/fixtures` to the shared fixture pool, copies `.env` from the shared source repo, and writes `.context/conductor/setup-receipt.json`.

If a workspace captured fixtures before setup ran, or if it intentionally has a populated local `scratchpad/fixtures/` directory, run:

```bash
bash .conductor/migrate_fixtures.sh
```

Archive runs preserve `scratchpad/sweeps/` and `scratchpad/runs/`, dereference shared fixtures when needed so archived `compare.html` and `summary.md` outputs stay navigable, append `~/conductor/archive/blink/_archive_runs.jsonl`, and write `archive-receipt.json` into preserved bundles.

### Env-var sync model

The `.env` copy is **one-time, at workspace creation** — there is no automatic re-sync. Each workspace's `.env` then drifts independently. Treat `$CONDUCTOR_ROOT_PATH/.env` (i.e. `~/conductor/repos/blink/.env`) as the canonical source of truth for local credentials and rotated secrets.

When you rotate credentials or add a new env var, edit central first, then propagate to existing workspaces:

```bash
~/conductor/repos/blink/.conductor/sync_env.sh             # actually sync
~/conductor/repos/blink/.conductor/sync_env.sh --dry-run   # preview only
```

The script backs up each workspace's existing `.env` to `.env.bak.<timestamp>` before overwrite and skips workspaces already byte-identical to central. New workspaces created via Conductor still inherit central's `.env` automatically through `setup.sh:67-79` — `sync_env.sh` only covers the "central changed, existing workspaces need to catch up" case.

`.env` and `.env.bak.*` files are gitignored under the root `.gitignore` `.env*` rule and are intentionally **not** preserved by `.conductor/archive.sh` when a workspace is torn down. They get rebuilt from central on the next workspace creation.

## Repository Map

- `docs/` contains product, artifact, dogfood, manual-playbook, and experiment records.
- `scratchpad/` contains the research hotkey runner, Gemini helpers, OCR wrapper, provider adapters, sweep runner, evaluation configs, and `field_runs/` import bridge.
- `scratchpad/tldr_reply/` contains the single-screenshot TL;DR + reply-suggestions experiment.
- `server/` contains the standalone Blink backend.
- `app/` contains the shipped Blink.app Swift surface and bundled Python runner.
- `experiments/blink-copy-paste/` contains the archived intelligent copy-paste tester app.
- `site/` contains the Astro marketing site.

## Documentation Expectations

Record experiment outcomes in `docs/EXPERIMENT_LOG.md` with date, hypothesis, setup, result, decision, and next step.

Document new top-level folders in `README.md`; document nested modules in a local README when the purpose is not obvious.

