from __future__ import annotations

import mimetypes
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# Copied from scratchpad/gemini_runner.py:56 so the shipped Blink Python fork does
# not depend on scratchpad modules at runtime.
def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def duration_ms(started_perf: float) -> int:
    return int(round((time.perf_counter() - started_perf) * 1000))


def guess_mime_type(path: Path) -> str:
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type and mime_type.startswith("image/"):
        return mime_type
    return "image/png"


def prepare_request_image(
    image_path: Path,
    settings: dict[str, Any],
    *,
    dest_dir: Path | None = None,
) -> dict[str, Any]:
    original_bytes = image_path.stat().st_size
    preprocess_enabled = bool(settings.get("preprocess_request_images", True))
    started_perf = time.perf_counter()
    started_at = now_iso()

    if not preprocess_enabled:
        data = image_path.read_bytes()
        finished_at = now_iso()
        mime_type = guess_mime_type(image_path)
        return {
            "bytes_data": data,
            "mime_type": mime_type,
            "original_bytes": original_bytes,
            "request_bytes": len(data),
            "duration_ms": duration_ms(started_perf),
            "log": {
                "status": "original",
                "enabled": False,
                "started_at": started_at,
                "finished_at": finished_at,
                "duration_ms": duration_ms(started_perf),
                "original_path": str(image_path),
                "original_bytes": original_bytes,
                "request_path": str(image_path),
                "request_bytes": len(data),
                "request_mime_type": mime_type,
            },
        }

    request_format = str(settings.get("request_image_format", "jpeg")).lower()
    max_dimension = int(settings.get("request_image_max_dimension", 1600))
    jpeg_quality = int(settings.get("request_image_jpeg_quality", 80))
    extension = ".jpg" if request_format in {"jpeg", "jpg"} else f".{request_format}"
    request_parent = dest_dir if dest_dir is not None else image_path.parent
    request_parent.mkdir(parents=True, exist_ok=True)
    request_path = request_parent / f"{image_path.stem}.request{extension}"
    command = ["/usr/bin/sips"]
    if request_format:
        command += ["-s", "format", request_format]
        if request_format in {"jpeg", "jpg"}:
            command += ["-s", "formatOptions", str(jpeg_quality)]
    if max_dimension > 0:
        command += ["-Z", str(max_dimension)]
    command += [str(image_path), "--out", str(request_path)]

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
    )
    finished_at = now_iso()
    duration = duration_ms(started_perf)

    if result.returncode == 0 and request_path.exists():
        data = request_path.read_bytes()
        mime_type = guess_mime_type(request_path)
        return {
            "bytes_data": data,
            "mime_type": mime_type,
            "original_bytes": original_bytes,
            "request_bytes": len(data),
            "duration_ms": duration,
            "log": {
                "status": "processed",
                "enabled": True,
                "started_at": started_at,
                "finished_at": finished_at,
                "duration_ms": duration,
                "original_path": str(image_path),
                "original_bytes": original_bytes,
                "request_path": str(request_path),
                "request_bytes": len(data),
                "request_mime_type": mime_type,
                "request_format": request_format,
                "request_image_max_dimension": max_dimension,
                "request_image_jpeg_quality": jpeg_quality
                if request_format in {"jpeg", "jpg"}
                else None,
                "command": command,
                "stdout": (result.stdout or "").strip(),
                "stderr": (result.stderr or "").strip(),
            },
        }

    data = image_path.read_bytes()
    mime_type = guess_mime_type(image_path)
    return {
        "bytes_data": data,
        "mime_type": mime_type,
        "original_bytes": original_bytes,
        "request_bytes": len(data),
        "duration_ms": duration,
        "log": {
            "status": "fallback_original",
            "enabled": True,
            "started_at": started_at,
            "finished_at": finished_at,
            "duration_ms": duration,
            "original_path": str(image_path),
            "original_bytes": original_bytes,
            "request_path": str(image_path),
            "request_bytes": len(data),
            "request_mime_type": mime_type,
            "request_format": request_format,
            "request_image_max_dimension": max_dimension,
            "request_image_jpeg_quality": jpeg_quality
            if request_format in {"jpeg", "jpg"}
            else None,
            "command": command,
            "stdout": (result.stdout or "").strip(),
            "stderr": (result.stderr or "").strip(),
        },
    }
