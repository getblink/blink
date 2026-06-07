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

`release.sh` also asserts that `BLINK_SPARKLE_FEED_URL` matches `https://$BLINK_R2_PUBLIC_DOMAIN/$BLINK_R2_APPCAST_KEY`. If they drift, the script aborts before doing any work — every install built with the old feed URL would otherwise be permanently quarantined from updates (no in-band recovery once shipped). If you ever need to move the appcast URL, publish to the **old** path too as a bridge until the prior install base ages out.

### Cloudflare cache config (`dl.useblink.dev`)

Cache Rules on the R2-fronted hostname must allow origin Cache-Control through, otherwise CF overrides `max-age` on `.dmg` (and possibly other binary types) to its 4-hour default. We saw this on the 0.2.1 release: the script set `Cache-Control: public, max-age=60, must-revalidate` on the DMG upload, but the live response came back as `max-age=14400`. Doesn't break first downloads (each release lives at a unique versioned path), but defeats the dry-run-then-re-upload safety the short TTL was intended to provide. Fix in CF dashboard → Caching → Cache Rules: add a rule matching `dl.useblink.dev` (or `*.dmg`) and set **Edge TTL** to "Use cache-control header if present, use default Cloudflare caching behavior if not". The appcast.xml Cache-Control passes through correctly today (its `cf-cache-status` reflects the `max-age=60` we set), so the override is path- or extension-scoped, not global — diff the response headers between `dl.useblink.dev/appcast.xml` and any `*.dmg` to confirm before touching settings.

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

## Branch strategy

**The invariant:** after every release, `git rev-parse origin/main` and `git rev-parse origin/staging` point at the same commit. They are two names for the same canonical history. Anything that's on `main` is on `staging`, and vice versa. The only time they're allowed to diverge is during an active testing window — and only briefly.

`staging` is the branch the [`deploy-server.yml`](../.github/workflows/deploy-server.yml) GitHub Action deploys to Cloud Run (service `blink-server-staging`, `https://api-staging.useblink.dev`); `main` deploys to production (`blink-server`, `https://api.useblink.dev`). `main` is also what reviewers and humans treat as the source of truth. Both exist; neither is "ahead." Diverging them produces a half-shipped product where dogfood and `main` disagree about what features exist.

Workflow:

1. Branch off `main`: `git checkout -B my-change origin/main`.
2. **Deploy to staging for testing** by fast-setting `staging` to your branch's tip:

   ```bash
   git push origin +my-change:staging
   ```

   The GitHub Action picks up the new tip and redeploys `server/` to Cloud Run (only if `server/**` changed). Dogfood and iterate against `https://api-staging.useblink.dev`.
3. **Promote to `main`** by opening a PR (`gh pr create --base main`) and merging once it's validated.
4. **Re-mirror `staging` to `main`** the moment the PR lands so the two pointers match again:

   ```bash
   git push origin +origin/main:staging
   ```

   Skip this step and you have created drift. The longer you skip it, the more painful the resync.

If a test branch's `staging` deploy gets abandoned (you decide not to promote), do *not* leave `staging` pointing at the abandoned branch. Re-mirror to `main` immediately so the invariant holds. Whatever was on staging-for-testing is then just a dead branch; archive it with a tag if you want to come back to it later (`git tag staging-archive-YYYY-MM-DD <abandoned-sha> && git push origin staging-archive-YYYY-MM-DD`).

Anti-patterns:

- **Pushing WIP directly to `staging`** (no feature branch). Either you forget to PR it to `main`, or you PR it as a giant grab-bag later — either way `staging` accumulates commits `main` never sees.
- **Forgetting the re-mirror step** after merging a PR. `main` moves ahead, `staging` stays behind, and dogfooders are testing a stale build that's missing whatever just landed.
- **Long-lived staging-only branches** ("just keeping it on staging while I poke at it for a week"). That's how the two diverge by a hundred commits. If a test is going to take days, document it; better, finish it quickly so the invariant can be restored.

If you find `staging` has drifted, archive its tip with a tag (`git tag staging-archive-YYYY-MM-DD origin/staging && git push origin staging-archive-YYYY-MM-DD`) before forcing it back to `main`.

## What lives where (so you don't edit the fallback)

A few config and prompt surfaces have *two copies* — the loaded value at runtime is not the in-code default. Edit both or your change won't take effect:

- **Prompt:** `server/prompt.txt` and `app/Resources/prompt.txt` must stay byte-identical (enforced by `app/python/tests/test_prompt_parity.py`). `DEFAULT_PROMPT` in `app/python/blink_once.py` is only a fallback if the file is missing.
- **Settings:** `app/Resources/settings.json` is bundled into the macOS app. `DEFAULT_SETTINGS` in both `app/python/blink_once.py` and `server/gemini.py` is only a fallback. The runtime override at `~/.blink/settings.json` (if present) shadows the bundle.
- **`temperature` and `max_output_tokens` are server-owned.** `server/main.py:_selected_settings` ignores client-supplied values for these. Tuning means editing `server/gemini.py:DEFAULT_SETTINGS` (or the `_for_model` overrides) and redeploying — not bumping `app/Resources/settings.json`. The client-side `settings.json` only matters for the local-Gemini fallback path where the proxy is disabled.
- **`thinking_level` is client-overridable.** The macOS "Reasoning" picker (`ReasoningLevels`, `BlinkCoordinator.requestPreferences`) sends `low` / `medium` / `high` in `preferences.thinking_level`; `_selected_settings` validates against that allowlist and forwards to `gemini._generate_config`. Unset (Default) falls back to `thinking_level_for_model` (currently `"low"` on Gemini 3). If you refactor the proxy path in `blink_once.py`, preserve the inbound `preferences` dict; stomping it re-introduces the silent-picker bug where the UI claimed to change reasoning but every request shipped at the server default.

## Server vs client deploy: they're independent

- `bash app/scripts/install_local_app.sh` only rebuilds the macOS app bundle. It does NOT redeploy the server.
- Pushing to the `staging` branch (with `server/**` changes) triggers a Cloud Run server deploy via the `deploy-server.yml` GitHub Action. It does NOT update the bundled macOS app.
- When a change touches both sides (`server/*` and `app/Resources/*` or `app/python/*`), you need both: push to `staging` (or merge to `main` and re-mirror) AND rebuild the local app. Otherwise dogfood will show a half-deployed mix.

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

