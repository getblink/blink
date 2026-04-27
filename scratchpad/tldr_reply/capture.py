from __future__ import annotations

import subprocess
import time
from pathlib import Path
from typing import Any


def _duration_ms(started: float, finished: float) -> int:
    return int(round((finished - started) * 1000))


def capture_active_window(out_path: Path) -> dict[str, Any]:
    """Prompt for a window screenshot and return a compact capture record."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    command = ["/usr/sbin/screencapture", "-x", "-t", "png", "-W", str(out_path)]
    started = time.perf_counter()
    result = subprocess.run(command, capture_output=True, text=True)
    finished = time.perf_counter()

    status = "ok"
    if result.returncode != 0 or not out_path.exists():
        stderr_text = (result.stderr or "").strip()
        if stderr_text:
            lowered = stderr_text.lower()
            if "not authorized" in lowered or "not permitted" in lowered:
                status = "permission_denied"
            else:
                status = "error"
        else:
            status = "cancelled"

    payload: dict[str, Any] = {
        "status": status,
        "command": command,
        "duration_ms": _duration_ms(started, finished),
        "returncode": result.returncode,
        "stdout": (result.stdout or "").strip(),
        "stderr": (result.stderr or "").strip(),
    }
    if status == "ok":
        payload["path"] = str(out_path)
        payload["bytes"] = out_path.stat().st_size
    return payload
