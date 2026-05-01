# Dogfood Playbook

How to set up a workspace for a clean `Blink.app` dogfood session: clean build,
clean permissions, and reusable fixtures + profiling + debug logs captured for
every trial.

When the user says "do a clean build" or "reinstall Blink for dogfood", this is
the procedure. See also:

- [`README.md`](../README.md) — repo entrypoint and quickstart
- [`CLAUDE.md`](../CLAUDE.md) — repo layout and implementation guide
- [`app/README.md`](../app/README.md) — tester-deployment channel overview
- [`docs/ARTIFACT_SCHEMA.md`](ARTIFACT_SCHEMA.md) — v1 bundle contract emitted per trial
- [`scratchpad/import_field_runs.py`](../scratchpad/import_field_runs.py) — bridge back to the research loop

## TL;DR

```bash
bash app/scripts/install_local_app.sh --reset-tcc
```

On relaunch, Blink opens its permissions window and immediately requests Screen
Recording so it appears in System Settings. Re-grant Input Monitoring,
Accessibility, and Screen Recording before trusting a dogfood run.

Use `--reset-tcc` after Swift app-code changes, or when System Settings still
shows Blink enabled but the new build behaves like it lost Accessibility /
Input Monitoring access anyway.

Drop `--reset-tcc` only when the installed binary and current grants are known
good.

## What the workspace already has

`.conductor/setup.sh` runs automatically on workspace creation and leaves you
with:

- `scratchpad/.venv` + deps installed
- `scratchpad/fixtures` symlinked to `~/conductor/shared/blink/fixtures/` (the
  shared pool — captures from any workspace land here)
- `.env` copied from `$CONDUCTOR_ROOT_PATH/.env`, so `GEMINI_API_KEY` is present
- `.context/conductor/setup-receipt.json` as proof the hook fired

None of that needs to be redone per dogfood session.

## What `install_local_app.sh --reset-tcc` does

1. `pkill -x Blink` — stop any running instance.
2. Fetch `app/python-dist/` (python-build-standalone 3.11 + `google-genai`) if
   missing. ~92 MB, per-workspace, cached within the workspace after first run.
3. `xcodegen generate` + `xcodebuild` a self-contained Release `Blink.app`.
4. Copy `python-dist/` and `app/python/*` into `Blink.app/Contents/Resources/`.
5. With `--reset-tcc`: kill Blink, remove the old canonical
   `~/Applications/Blink.app`, reset TCC entries for
   `com.blink.tester.Blink` (All, Accessibility, ScreenCapture, ListenEvent,
   PostEvent, AppleEvents, SystemPolicyAllFiles), and nudge LaunchServices to
   forget the old binary. This is the safe default after Swift app-code changes,
   because macOS can keep permissions visually enabled while still binding the
   grant to an older Blink build.
6. Install the build to `~/Applications/Blink.app` (this is the canonical
   install; there is only one per machine — rebuilds from any workspace
   overwrite it).
7. Stash duplicate `Blink.app` bundles from `app/build/`, `/Applications/`, and
   `DerivedData/` into `.context/disabled-apps/*.app.disabled` so Spotlight,
   LaunchServices, and TCC only see one install.
8. Relaunch `~/Applications/Blink.app`.

On launch, Blink calls the real Screen Recording request API and opens the
in-app permissions window. This is intentional: `CGPreflightScreenCaptureAccess`
can report an existing state, but it does not create the System Settings row.

Pass `--no-launch` to install without relaunching.

## Verify the install

```bash
pgrep -lf 'Applications/Blink.app/Contents/MacOS/Blink'
ls ~/Applications/Blink.app/Contents/Resources/run_once.py
ls ~/Applications/Blink.app/Contents/Resources/python/bin/python3
ls .context/disabled-apps/    # should contain any stashed duplicates
```

## Where artifacts land (machine-wide, not per-workspace)

Every trial writes a v1 bundle to:

```
~/Library/Application Support/Blink/runs/<YYYYMMDD-HHMMSS-mmm>/
  fixture.json          # sweep-replayable manifest
  source.png            # source screenshot
  target.png            # target screenshot
  target_metadata.json  # accessibility tree
  settings.json         # capture settings snapshot
  run.json              # request/response log + Python timings (+ mirrored host_* timings)
  host_profile.json     # Swift-side wall-clock profiling for capture / prep / Python / paste
  output.txt            # generated text
  stderr.log            # run_once.py stderr (added by PythonRunner.swift)
```

Nothing in the workspace needs to be configured for this — capture is on by
default. `run.json` already includes `request_build_ms`,
`source/target_image_prepare_ms`, `ttft_ms`, `stream_duration_ms`,
`model_latency_ms`, and `end_to_end_ms`, plus mirrored `host_*` timing keys once
the Swift side finishes the trial. `host_profile.json` is the fuller wall-clock
breakdown for source capture, target capture, artifact prep, Python wall time,
and paste insertion. No profiling flag exists or is needed.

Because the runs directory is machine-wide, bundles from multiple workspaces
interleave by timestamp. Fixture IDs stay unique so sweeps don't collide, but
worktree provenance is not tracked automatically — note it at export time if
you need it.

## Pulling a run back into the research loop

From the Blink menubar: "Export last N runs…" → `~/Desktop/Blink-runs-<ts>.zip`.
Then, in the workspace you want to replay from:

```bash
python scratchpad/import_field_runs.py ~/Desktop/Blink-runs-<ts>.zip
./sweep --fixtures 'scratchpad/field_runs/*' \
        --configs 'scratchpad/eval_configs/*.json' \
        --out scratchpad/sweeps/<name>
```

`compare.html` and `summary.md` land in the sweep out-dir.

## Troubleshooting

- **Hotkeys silently do nothing after install**: TCC may still be pointing at
  the old Blink binary even if System Settings says Blink is enabled. Re-run
  with `--reset-tcc` after Swift app-code changes, then re-grant the three
  permissions on first use.
- **Blink is missing from Screen Recording**: quit/relaunch the canonical
  `~/Applications/Blink.app`. Blink requests Screen Recording on startup so
  macOS creates the row; `CGPreflightScreenCaptureAccess` alone is not enough.
- **`GEMINI_API_KEY is not set` in `run.json`**: `.env` didn't copy. Check
  `.context/conductor/setup-receipt.json` for `env_status: "copied"`. If
  missing, seed the canonical `.env` once at `$CONDUCTOR_ROOT_PATH/.env`, then
  re-run `.conductor/setup.sh`.
- **Spotlight shows two Blinks / TCC shows a stale entry**: look in
  `.context/disabled-apps/`. If a stash is missing, re-run the installer —
  `disable_app_bundle` only runs on install.
- **`stderr.log` is empty or missing**: only written when `run_once.py` actually
  emits stderr. A successful run with no progress lines (e.g. very old build
  from before the sidecar wiring) leaves no file. Rebuild to pick up
  `PythonRunner.swift`'s stderr persistence.
- **You need the full live timing breakdown**: open `run.json` for the mirrored
  `host_*` summary fields or `host_profile.json` for the full phase-by-phase
  record. Control Center also shows the mirrored `host_*` timings in the run
  summary for recent runs.
