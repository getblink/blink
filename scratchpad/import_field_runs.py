#!/usr/bin/env python3
"""Import an archived copy-paste tester bundle into scratchpad/field_runs/.

Accepts either:
- a zip file exported via the archived tester app's `BundleExporter`, or
- a single already-unpacked bundle directory (under ~/Library/Application Support/Blink/runs/).

Each bundle lands under scratchpad/field_runs/<fixture_id>/ (or <slug> override via
`--as`). Validates schema_version and that the source/target images referenced by
fixture.json actually exist before moving anything.

Contract: docs/ARTIFACT_SCHEMA.md. Only schema_version == 1 is accepted.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Iterable

SCHEMA_VERSION = 1
BASE_DIR = Path(__file__).resolve().parent
FIELD_RUNS_DIR = BASE_DIR / "field_runs"


def _load_manifest(bundle_dir: Path) -> dict:
    manifest_path = bundle_dir / "fixture.json"
    if not manifest_path.exists():
        raise ValueError(f"{bundle_dir}: missing fixture.json")
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict):
        raise ValueError(f"{manifest_path}: fixture.json is not a JSON object")
    return manifest


def _validate(bundle_dir: Path, manifest: dict) -> list[str]:
    errors: list[str] = []
    version = manifest.get("schema_version")
    if version != SCHEMA_VERSION:
        errors.append(
            f"schema_version={version!r}; importer only accepts {SCHEMA_VERSION}. "
            "Re-pin and update docs/ARTIFACT_SCHEMA.md if you are bumping."
        )
    fixture_id = manifest.get("fixture_id")
    if not fixture_id:
        errors.append("fixture_id is empty")
    source_rel = (manifest.get("source") or {}).get("image_path")
    target_rel = (manifest.get("target") or {}).get("image_path")
    if not source_rel or not (bundle_dir / source_rel).exists():
        errors.append(f"source image missing: {source_rel!r}")
    if not target_rel or not (bundle_dir / target_rel).exists():
        errors.append(f"target image missing: {target_rel!r}")
    if not isinstance(manifest.get("target_metadata"), dict):
        errors.append("target_metadata missing or not an object")
    return errors


def _iter_bundles_in_dir(root: Path) -> Iterable[Path]:
    if (root / "fixture.json").exists():
        yield root
        return
    for child in sorted(root.iterdir()):
        if child.is_dir() and (child / "fixture.json").exists():
            yield child


def _slug_dest_name(manifest: dict, override: str | None) -> str:
    if override:
        return override
    return manifest.get("fixture_id") or manifest.get("slug") or "bundle"


def _copy_bundle(src: Path, dest: Path) -> None:
    if dest.exists():
        raise FileExistsError(f"destination exists: {dest}. Use --as to pick a new name or --force to overwrite.")
    shutil.copytree(src, dest)


def _import_one(bundle_dir: Path, dest_root: Path, *, as_name: str | None, force: bool) -> tuple[Path, dict]:
    manifest = _load_manifest(bundle_dir)
    errors = _validate(bundle_dir, manifest)
    if errors:
        raise ValueError(f"{bundle_dir}: invalid bundle\n  - " + "\n  - ".join(errors))
    dest = dest_root / _slug_dest_name(manifest, as_name)
    if force and dest.exists():
        shutil.rmtree(dest)
    _copy_bundle(bundle_dir, dest)
    return dest, manifest


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Import archived tester bundles into scratchpad/field_runs/")
    parser.add_argument(
        "source",
        type=Path,
        help="A .zip file or a directory. If a directory, may be a single bundle or a parent containing multiple bundles.",
    )
    parser.add_argument(
        "--as",
        dest="as_name",
        default=None,
        help="Rename the imported bundle (only valid when source resolves to a single bundle).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing destination directory under scratchpad/field_runs/.",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=FIELD_RUNS_DIR,
        help=f"Destination parent (default: {FIELD_RUNS_DIR}).",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    dest_root: Path = args.dest.expanduser().resolve()
    dest_root.mkdir(parents=True, exist_ok=True)
    source: Path = args.source.expanduser().resolve()

    if not source.exists():
        print(f"source not found: {source}", file=sys.stderr)
        return 2

    bundles: list[Path] = []
    cleanup_dir: Path | None = None
    if source.is_file() and source.suffix.lower() == ".zip":
        cleanup_dir = Path(tempfile.mkdtemp(prefix="blink-import-"))
        try:
            with zipfile.ZipFile(source, "r") as zf:
                zf.extractall(cleanup_dir)
        except zipfile.BadZipFile as exc:
            shutil.rmtree(cleanup_dir, ignore_errors=True)
            print(f"bad zip: {exc}", file=sys.stderr)
            return 2
        bundles = list(_iter_bundles_in_dir(cleanup_dir))
    elif source.is_dir():
        bundles = list(_iter_bundles_in_dir(source))
    else:
        print(f"source must be a .zip file or a directory: {source}", file=sys.stderr)
        return 2

    if not bundles:
        print(f"no bundles found under {source} (looked for fixture.json)", file=sys.stderr)
        if cleanup_dir:
            shutil.rmtree(cleanup_dir, ignore_errors=True)
        return 1

    if args.as_name and len(bundles) > 1:
        print("--as is only valid when importing exactly one bundle", file=sys.stderr)
        if cleanup_dir:
            shutil.rmtree(cleanup_dir, ignore_errors=True)
        return 2

    rc = 0
    try:
        for bundle in bundles:
            try:
                dest, manifest = _import_one(bundle, dest_root, as_name=args.as_name, force=args.force)
            except (ValueError, FileExistsError) as exc:
                rc = 1
                print(f"SKIP {bundle.name}: {exc}", file=sys.stderr)
                continue
            print(
                f"OK   {manifest.get('fixture_id')!r}  "
                f"bundle_source={manifest.get('bundle_source', 'research')}  "
                f"status={(manifest.get('target_metadata') or {}).get('status')}  "
                f"→ {dest}"
            )
    finally:
        if cleanup_dir:
            shutil.rmtree(cleanup_dir, ignore_errors=True)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
