# AGENTS.md

This repository is optimized for agent collaboration on early-stage product discovery.

## Mission

Build toward a trustworthy, local-first cross-app assistant, starting with one validated capability:

- **Intelligent copy-paste** (first priority)

## Operating principles

- **Source of truth:** GitHub-first repository state.
- **Clean structure first:** Keep module and folder ownership obvious.
- **Experiments over builds:** Learning signal beats feature count.
- **Manual before automation:** Validate outputs by hand before adding plumbing.
- **Single-focus discipline:** Deeply validate one magical moment before expanding scope.
- **Profile before optimizing:** Measure actual bottlenecks.

## Engineering guidelines

- Keep changes minimal, reversible, and well-scoped.
- Avoid premature abstraction and framework-heavy setups.
- Prefer simple scripts and notes for early validation.
- Do not add background daemons, hotkeys, or polished UI until manual value is proven.
- Favor additive iteration with clear experiment boundaries; do not delete prior learning artifacts unless explicitly requested.

## Documentation requirements

When running experiments, update `docs/EXPERIMENT_LOG.md` with:

- Date
- Hypothesis
- Setup
- Result
- Decision
- Next step

If introducing any new folder/module, document purpose in either:

- `README.md` (for top-level), or
- a local README inside that folder.

## Priority order for upcoming work

1. Validate intelligent copy-paste manually.
2. Build minimal support tooling for repeatable evaluation.
3. Reassess whether to expand into autocomplete or intent.
