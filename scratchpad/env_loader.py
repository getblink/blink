from __future__ import annotations

# Shared env loader for capture and multi-provider sweep scripts.
# It keeps whatever the shell already exported, then fills in any missing
# values from repo-root `.env` and `.env.local`.

import os
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent


def _parse_env_line(raw_line: str) -> tuple[str, str] | None:
    line = raw_line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("export "):
        line = line[len("export ") :].strip()
    if "=" not in line:
        return None
    key, value = line.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not key:
        return None
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        value = value[1:-1]
    return key, value


def load_workspace_env() -> list[Path]:
    loaded_paths: list[Path] = []
    preserved_keys = set(os.environ.keys())
    for candidate in (ROOT_DIR / ".env", ROOT_DIR / ".env.local"):
        if not candidate.exists():
            continue
        for raw_line in candidate.read_text(encoding="utf-8").splitlines():
            parsed = _parse_env_line(raw_line)
            if parsed is None:
                continue
            key, value = parsed
            if key in preserved_keys:
                continue
            os.environ[key] = value
        loaded_paths.append(candidate)
    return loaded_paths
