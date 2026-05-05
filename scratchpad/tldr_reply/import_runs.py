#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any

SHARED_POOL_ROOT = Path("~/conductor/shared").expanduser()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def warn(message: str) -> None:
    print(f"[import-runs] warning: {message}", file=sys.stderr)


def value_at(payload: Any, *keys: str) -> Any:
    current = payload
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def first_dict(*values: Any) -> dict[str, Any] | None:
    for value in values:
        if isinstance(value, dict):
            return value
    return None


def load_optional(run_dir: Path, name: str) -> Any:
    path = run_dir / name
    if not path.exists():
        return None
    try:
        return load_json(path)
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"{run_dir.name}: skipping unreadable {name}: {exc}")
        return None


def run_dirs(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted(path for path in root.iterdir() if path.is_dir())


def capture_from_run(
    *,
    request: dict[str, Any] | None,
    meta: dict[str, Any] | None,
) -> dict[str, Any]:
    request = request or {}
    meta = meta or {}
    capture = first_dict(meta.get("capture")) or {}
    frontmost_app = first_dict(
        request.get("frontmost_app"),
        value_at(request, "capture", "frontmost_app"),
        value_at(request, "client", "frontmost_app"),
        capture.get("frontmost_app"),
    )
    focused_context = first_dict(
        request.get("focused_context"),
        value_at(request, "capture", "focused_context"),
        capture.get("focused_context"),
    )
    result: dict[str, Any] = {}
    if frontmost_app is not None:
        result["frontmost_app"] = frontmost_app
    if focused_context is not None:
        result["focused_context"] = focused_context
    if capture:
        for key in ("status", "bbox", "window_title", "duration_ms", "display_scale"):
            if capture.get(key) is not None and key not in result:
                result[key] = capture[key]
    return result


def response_from_run(
    *,
    run: dict[str, Any] | None,
    response: dict[str, Any] | None,
    meta: dict[str, Any] | None,
) -> dict[str, Any] | None:
    run = run or {}
    response = response or {}
    meta = meta or {}
    response_summary = first_dict(run.get("response"))
    source = response if response else response_summary
    if not isinstance(source, dict):
        return None
    tldr = source.get("tldr")
    suggestions = source.get("suggestions")
    if not isinstance(tldr, str) or not isinstance(suggestions, list):
        return None
    return {
        "tldr": tldr,
        "suggestions": [str(item) for item in suggestions],
        "model": source.get("model") or run.get("model") or meta.get("model"),
        "usage": source.get("usage"),
        "duration_ms": source.get("duration_ms")
        or value_at(run, "response", "duration_ms")
        or meta.get("gemini_ms"),
        "settings": first_dict(source.get("settings"), run.get("settings"), meta.get("settings")) or {},
    }


def captured_at_for_run(
    *,
    run_dir: Path,
    run: dict[str, Any] | None,
    meta: dict[str, Any] | None,
) -> str | None:
    run = run or {}
    meta = meta or {}
    return (
        run.get("started_at")
        or meta.get("started_at")
        or meta.get("hotkey_at")
        or None
    )


def label_for_run(run_dir: Path, capture: dict[str, Any]) -> str:
    frontmost_app = first_dict(capture.get("frontmost_app"))
    if frontmost_app:
        for key in ("app_name", "name", "localized_name", "bundle_id"):
            value = frontmost_app.get(key)
            if isinstance(value, str) and value.strip():
                return f"{value.strip()} ({run_dir.name})"
    return run_dir.name.replace("-", " ").replace("_", " ")


def path_is_under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def is_shared_pool_path(path: Path) -> bool:
    resolved_path = path.expanduser().resolve()
    resolved_shared = SHARED_POOL_ROOT.resolve()
    return path_is_under(resolved_path, resolved_shared)


def refuse_shared_pool_out(out_root: Path) -> None:
    if is_shared_pool_path(out_root):
        raise ValueError(
            "Refusing to import personal TLDR screenshots into ~/conductor/shared. "
            "Use a local ignored directory such as scratchpad/tldr_reply/fixtures/from_runs."
        )


def import_run(run_dir: Path, out_root: Path) -> bool:
    screenshot = run_dir / "screenshot.png"
    if not screenshot.exists():
        warn(f"{run_dir.name}: skipping because screenshot.png is missing")
        return False
    run = load_optional(run_dir, "run.json")
    meta = load_optional(run_dir, "meta.json")
    request = load_optional(run_dir, "request.json")
    response = load_optional(run_dir, "response.json")
    if not isinstance(run, dict):
        run = None
    if not isinstance(meta, dict):
        meta = None
    if not isinstance(request, dict):
        request = None
    if not isinstance(response, dict):
        response = None

    expected = response_from_run(run=run, response=response, meta=meta)
    if expected is None:
        warn(f"{run_dir.name}: skipping because no usable TLDR response was found")
        return False
    capture = capture_from_run(request=request, meta=meta)
    if not capture.get("frontmost_app") and not capture.get("focused_context"):
        warn(
            f"{run_dir.name}: importing without frontmost_app/focused_context; "
            "this usually means the run came from the scratchpad harness."
        )

    out_dir = out_root / run_dir.name
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(screenshot, out_dir / "screenshot.png")
    manifest = {
        "slug": run_dir.name,
        "label": label_for_run(run_dir, capture),
        "captured_at": captured_at_for_run(run_dir=run_dir, run=run, meta=meta),
        "notes": "Imported from a local TLDR run artifact.",
        "screenshot": "screenshot.png",
        "capture": capture,
        "source_run_dir": str(run_dir),
    }
    save_json(out_dir / "tldr_fixture.json", manifest)
    save_json(out_dir / "expected.json", expected)
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Import TLDR run artifacts as sweep fixtures.")
    parser.add_argument("runs_root", help="Directory containing TLDR run subdirectories.")
    parser.add_argument(
        "--out",
        default="scratchpad/tldr_reply/fixtures/from_runs",
        help="Output fixture directory. Defaults to scratchpad/tldr_reply/fixtures/from_runs.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runs_root = Path(args.runs_root).expanduser()
    out_root = Path(args.out).expanduser()
    if not out_root.is_absolute():
        out_root = (Path.cwd() / out_root).resolve()
    try:
        refuse_shared_pool_out(out_root)
    except ValueError as exc:
        print(f"[import-runs] error: {exc}", file=sys.stderr)
        return 2
    out_root.mkdir(parents=True, exist_ok=True)
    imported = 0
    skipped = 0
    for run_dir in run_dirs(runs_root):
        if import_run(run_dir, out_root):
            imported += 1
        else:
            skipped += 1
    print(f"[import-runs] imported={imported} skipped={skipped} out={out_root}")
    return 0 if imported else 1


if __name__ == "__main__":
    raise SystemExit(main())
