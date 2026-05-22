#!/usr/bin/env python3
"""Offline latency replay harness for Blink's /v1/tldr hot path.

Reads a captured run bundle from ~/Library/Application Support/Blink/runs/
and replays it against a configurable server URL, measuring per-phase wall
times. Use `--corpus` to run across many bundles and emit CSV + summary.
"""
from __future__ import annotations

import argparse
import csv
import http.client
import io
import json
import mimetypes
import os
import socket
import ssl
import statistics
import subprocess
import sys
import time
import urllib.parse
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable


# --- env loading ---


def load_env(repo_root: Path) -> dict[str, str]:
    env: dict[str, str] = dict(os.environ)
    env_file = repo_root / ".env"
    if env_file.exists():
        for raw in env_file.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            k = k.strip()
            v = v.strip()
            if v.startswith('"') and v.endswith('"'):
                v = v[1:-1]
            env.setdefault(k, v)
    return env


# --- bundle loader ---


@dataclass
class Bundle:
    path: Path
    request_payload: dict[str, Any]
    screenshot_paths: list[Path]
    run_json: dict[str, Any] = field(default_factory=dict)

    @property
    def request_id(self) -> str:
        return str(self.request_payload.get("request_id") or self.path.name)

    @property
    def model(self) -> str:
        prefs = self.request_payload.get("preferences") or {}
        return str(prefs.get("model") or "")

    @property
    def thinking_level(self) -> str:
        prefs = self.request_payload.get("preferences") or {}
        return str(prefs.get("thinking_level") or "")


def load_bundle(path: Path) -> Bundle:
    if not path.is_dir():
        raise ValueError(f"Not a bundle directory: {path}")
    req_file = path / "request.json"
    if not req_file.exists():
        raise ValueError(f"Missing request.json: {req_file}")
    payload = json.loads(req_file.read_text())
    # Prefer screenshot_N.png in order; fall back to screenshot.png
    shots = sorted(path.glob("screenshot_*.png"))
    if not shots:
        primary = path / "screenshot.png"
        if not primary.exists():
            raise ValueError(f"No screenshots in: {path}")
        shots = [primary]
    run_json_path = path / "run.json"
    run_json = json.loads(run_json_path.read_text()) if run_json_path.exists() else {}
    return Bundle(path=path, request_payload=payload, screenshot_paths=shots, run_json=run_json)


# --- image prep (matches app/python/image_prep.py behavior, in-process timing) ---


def prepare_image_sips(
    image_path: Path,
    dest_path: Path,
    *,
    max_dimension: int,
    jpeg_quality: int,
    request_format: str = "jpeg",
) -> tuple[bytes, str, dict[str, Any]]:
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    cmd = [
        "/usr/bin/sips",
        "-s", "format", request_format,
    ]
    if request_format in {"jpeg", "jpg"}:
        cmd += ["-s", "formatOptions", str(jpeg_quality)]
    if max_dimension > 0:
        cmd += ["-Z", str(max_dimension)]
    cmd += [str(image_path), "--out", str(dest_path)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    elapsed_ms = int(round((time.perf_counter() - started) * 1000))
    if result.returncode != 0 or not dest_path.exists():
        # Fall back to original
        data = image_path.read_bytes()
        mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
        return data, mime, {
            "sips_status": "fallback",
            "sips_ms": elapsed_ms,
            "stderr": result.stderr.strip()[:200],
            "request_bytes": len(data),
        }
    data = dest_path.read_bytes()
    mime = "image/jpeg" if request_format in {"jpeg", "jpg"} else "image/png"
    return data, mime, {
        "sips_status": "processed",
        "sips_ms": elapsed_ms,
        "request_bytes": len(data),
    }


def prepare_image_passthrough(image_path: Path) -> tuple[bytes, str, dict[str, Any]]:
    started = time.perf_counter()
    data = image_path.read_bytes()
    elapsed_ms = int(round((time.perf_counter() - started) * 1000))
    mime = "image/png" if image_path.suffix.lower() == ".png" else "image/jpeg"
    return data, mime, {
        "sips_status": "passthrough",
        "sips_ms": elapsed_ms,
        "request_bytes": len(data),
    }


# --- multipart encode ---


def encode_multipart(
    request_payload: dict[str, Any],
    images: list[tuple[bytes, str]],  # (bytes, mime)
) -> tuple[bytes, str]:
    """Mirrors app/python/blink_once.py:_encode_multipart_request."""
    boundary = f"blink-{uuid.uuid4().hex}"
    request_json = json.dumps(request_payload, ensure_ascii=True, sort_keys=True).encode("utf-8")
    parts: list[bytes] = [
        f"--{boundary}\r\n".encode("utf-8"),
        b'Content-Disposition: form-data; name="request"\r\n',
        b"Content-Type: application/json\r\n\r\n",
        request_json,
        b"\r\n",
    ]
    for index, (img_bytes, img_mime) in enumerate(images):
        field_name = "screenshot" if index == 0 else f"screenshot_{index}"
        ext = ".jpg" if img_mime == "image/jpeg" else ".png"
        parts.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                (
                    f'Content-Disposition: form-data; name="{field_name}"; '
                    f'filename="screenshot_{index}{ext}"\r\n'
                ).encode("utf-8"),
                f"Content-Type: {img_mime}\r\n\r\n".encode("utf-8"),
                img_bytes,
                b"\r\n",
            ]
        )
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(parts), boundary


# --- HTTP replay ---


@dataclass
class ReplayResult:
    bundle: str
    model: str
    thinking_level: str
    status: str
    http_status: int | None
    image_prep_ms: int
    image_request_bytes: int
    multipart_build_ms: int
    multipart_bytes: int
    connect_ms: int
    request_sent_ms: int
    ttfb_ms: int
    first_partial_tldr_ms: int | None
    first_partial_suggestions_ms: int | None
    final_event_ms: int | None
    total_wall_ms: int
    server_duration_ms: int | None
    final_tldr: str
    final_suggestions: list[str]
    raw_event_count: int
    sips_status: str
    error: str = ""


def _split_url(url: str) -> tuple[str, str, int, str]:
    parsed = urllib.parse.urlsplit(url)
    scheme = parsed.scheme or "https"
    host = parsed.hostname or ""
    port = parsed.port or (443 if scheme == "https" else 80)
    base_path = parsed.path.rstrip("/")
    return scheme, host, port, base_path


def _iter_sse_lines(reader: io.BufferedReader, timeout: float, t0: float) -> Iterable[tuple[float, bytes]]:
    while True:
        line = reader.readline()
        if not line:
            return
        yield (time.perf_counter() - t0), line


def replay_once(
    bundle: Bundle,
    *,
    url: str,
    token: str,
    override_model: str | None = None,
    override_thinking: str | None = None,
    image_prep_mode: str = "sips",  # sips | passthrough
    max_dimension: int = 1600,
    jpeg_quality: int = 70,
    timeout_seconds: float = 60.0,
    tmp_dir: Path | None = None,
    warm_conn: http.client.HTTPSConnection | None = None,
) -> tuple[ReplayResult, http.client.HTTPSConnection | None]:
    """Replay one bundle, optionally reusing a prewarmed HTTPS connection.

    Returns (result, conn). conn is the connection object (potentially reusable);
    caller should pass it back in `warm_conn` to test connection reuse.
    """
    payload = json.loads(json.dumps(bundle.request_payload))  # deep copy
    prefs = payload.setdefault("preferences", {})
    if override_model:
        prefs["model"] = override_model
    if override_thinking:
        prefs["thinking_level"] = override_thinking

    tmp_dir = tmp_dir or Path("/tmp/blink_latency_replay")
    tmp_dir.mkdir(parents=True, exist_ok=True)

    t_start = time.perf_counter()

    # Phase 1: image prep
    prep_started = time.perf_counter()
    images: list[tuple[bytes, str]] = []
    sips_status = "n/a"
    request_bytes_total = 0
    for i, shot in enumerate(bundle.screenshot_paths):
        if image_prep_mode == "passthrough":
            data, mime, info = prepare_image_passthrough(shot)
        else:
            dest = tmp_dir / f"{bundle.path.name}_{i}.request.jpg"
            data, mime, info = prepare_image_sips(
                shot, dest,
                max_dimension=max_dimension,
                jpeg_quality=jpeg_quality,
            )
        images.append((data, mime))
        request_bytes_total += info["request_bytes"]
        sips_status = info["sips_status"]
    image_prep_ms = int(round((time.perf_counter() - prep_started) * 1000))

    # Phase 2: multipart build
    mp_started = time.perf_counter()
    body, boundary = encode_multipart(payload, images)
    multipart_build_ms = int(round((time.perf_counter() - mp_started) * 1000))

    # Phase 3: HTTP send + stream
    scheme, host, port, base_path = _split_url(url)
    path = base_path + "/v1/tldr"

    conn = warm_conn
    connect_ms = 0
    if conn is None:
        connect_started = time.perf_counter()
        if scheme == "https":
            ctx = ssl.create_default_context()
            conn = http.client.HTTPSConnection(host, port, timeout=timeout_seconds, context=ctx)
        else:
            conn = http.client.HTTPConnection(host, port, timeout=timeout_seconds)  # type: ignore[assignment]
        conn.connect()
        connect_ms = int(round((time.perf_counter() - connect_started) * 1000))

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Accept": "text/event-stream",
        "Content-Length": str(len(body)),
    }

    sent_started = time.perf_counter()
    error_str = ""
    final_event_payload: dict[str, Any] | None = None
    first_partial_tldr_ms: int | None = None
    first_partial_suggestions_ms: int | None = None
    final_event_ms: int | None = None
    raw_event_count = 0
    ttfb_ms = -1
    http_status: int | None = None
    request_sent_ms = 0

    try:
        conn.request("POST", path, body=body, headers=headers)
        request_sent_ms = int(round((time.perf_counter() - sent_started) * 1000))

        ttfb_started = time.perf_counter()
        response = conn.getresponse()
        ttfb_ms = int(round((time.perf_counter() - ttfb_started) * 1000))
        http_status = response.status

        # Parse SSE
        pending: list[str] = []
        stream_t0 = time.perf_counter()
        while True:
            line = response.readline()
            if not line:
                break
            now_ms = int(round((time.perf_counter() - stream_t0) * 1000))
            text = line.decode("utf-8", errors="replace").rstrip("\r\n")
            if text:
                pending.append(text)
                continue
            if not pending:
                continue
            event_name = "message"
            data_lines: list[str] = []
            for raw_line in pending:
                if raw_line.startswith(":"):
                    continue
                if raw_line.startswith("event:"):
                    event_name = raw_line.removeprefix("event:").strip() or "message"
                elif raw_line.startswith("data:"):
                    data_lines.append(raw_line.removeprefix("data:").lstrip())
            pending = []
            if not data_lines:
                continue
            try:
                data = json.loads("\n".join(data_lines))
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            raw_event_count += 1
            if event_name == "partial_tldr" and first_partial_tldr_ms is None:
                first_partial_tldr_ms = now_ms
            elif event_name == "partial_suggestions" and first_partial_suggestions_ms is None:
                first_partial_suggestions_ms = now_ms
            elif event_name == "final":
                final_event_ms = now_ms
                final_event_payload = data
            elif event_name == "error":
                error_str = str(data.get("detail") or "")[:200]
        # Drain final
    except (OSError, http.client.HTTPException, socket.timeout) as exc:
        error_str = f"{type(exc).__name__}: {str(exc)[:200]}"
        try:
            conn.close()
        except Exception:
            pass
        conn = None

    total_wall_ms = int(round((time.perf_counter() - t_start) * 1000))

    final_tldr = ""
    final_suggestions: list[str] = []
    server_duration_ms: int | None = None
    status_str = "error"
    if final_event_payload is not None:
        final_tldr = str(final_event_payload.get("tldr") or "")
        sg = final_event_payload.get("suggestions") or []
        final_suggestions = [str(s) for s in sg if isinstance(s, str)]
        server_duration_ms = final_event_payload.get("duration_ms")
        status_str = str(final_event_payload.get("status") or "ok")

    if error_str and status_str == "error":
        pass
    elif final_event_payload is None and not error_str:
        error_str = "no_final_event"

    result = ReplayResult(
        bundle=bundle.path.name,
        model=override_model or bundle.model,
        thinking_level=override_thinking or bundle.thinking_level,
        status=status_str,
        http_status=http_status,
        image_prep_ms=image_prep_ms,
        image_request_bytes=request_bytes_total,
        multipart_build_ms=multipart_build_ms,
        multipart_bytes=len(body),
        connect_ms=connect_ms,
        request_sent_ms=request_sent_ms,
        ttfb_ms=ttfb_ms,
        first_partial_tldr_ms=first_partial_tldr_ms,
        first_partial_suggestions_ms=first_partial_suggestions_ms,
        final_event_ms=final_event_ms,
        total_wall_ms=total_wall_ms,
        server_duration_ms=server_duration_ms,
        final_tldr=final_tldr[:300],
        final_suggestions=[s[:200] for s in final_suggestions],
        raw_event_count=raw_event_count,
        sips_status=sips_status,
        error=error_str,
    )
    return result, conn


# --- corpus runner ---


def percentile(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] + (ys[c] - ys[f]) * (k - f)


def summarize(results: list[ReplayResult]) -> dict[str, Any]:
    def vals(attr: str) -> list[float]:
        out: list[float] = []
        for r in results:
            v = getattr(r, attr)
            if v is None:
                continue
            out.append(float(v))
        return out

    ok = [r for r in results if r.status == "ok"]
    summary: dict[str, Any] = {
        "n_total": len(results),
        "n_ok": len(ok),
        "n_error": len(results) - len(ok),
    }
    for attr in (
        "image_prep_ms",
        "multipart_build_ms",
        "connect_ms",
        "request_sent_ms",
        "ttfb_ms",
        "first_partial_tldr_ms",
        "first_partial_suggestions_ms",
        "final_event_ms",
        "total_wall_ms",
        "server_duration_ms",
    ):
        xs = [v for v in vals(attr) if v >= 0]
        if xs:
            summary[f"{attr}_p50"] = round(percentile(xs, 0.50), 1)
            summary[f"{attr}_p90"] = round(percentile(xs, 0.90), 1)
            summary[f"{attr}_mean"] = round(statistics.fmean(xs), 1)
            summary[f"{attr}_n"] = len(xs)
    return summary


def write_csv(results: list[ReplayResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not results:
        return
    fieldnames = [k for k in asdict(results[0]).keys()]
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in results:
            row = asdict(r)
            row["final_suggestions"] = " | ".join(row["final_suggestions"])
            w.writerow(row)


# --- CLI ---


def find_recent_bundles(root: Path, limit: int) -> list[Path]:
    candidates = []
    for child in root.iterdir():
        if child.is_dir() and (child / "request.json").exists():
            candidates.append(child)
    candidates.sort(key=lambda p: p.name, reverse=True)
    return candidates[:limit]


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay Blink TL;DR runs and measure latency.")
    parser.add_argument("--bundle", type=str, default=None, help="Single bundle dir")
    parser.add_argument("--corpus", type=str, default=None, help="Directory containing bundle subdirs")
    parser.add_argument("--limit", type=int, default=30, help="Max bundles in --corpus mode")
    parser.add_argument("--url", type=str, default=None, help="Server URL (defaults to BLINK_PROXY_URL)")
    parser.add_argument("--model", type=str, default=None, help="Override preferences.model")
    parser.add_argument("--thinking", type=str, default=None, help="Override preferences.thinking_level")
    parser.add_argument("--image-prep", type=str, default="sips", choices=["sips", "passthrough"], help="Image-prep mode")
    parser.add_argument("--max-dimension", type=int, default=1600)
    parser.add_argument("--jpeg-quality", type=int, default=70)
    parser.add_argument("--out-csv", type=str, default=None, help="Write per-bundle CSV here")
    parser.add_argument("--reuse-conn", action="store_true", help="Reuse one HTTPS conn across bundles")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--repeat", type=int, default=1, help="Replay each bundle N times")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    env = load_env(repo_root)
    url = args.url or env.get("BLINK_PROXY_URL") or env.get("TLDR_PROXY_URL") or "https://blink-staging.up.railway.app"
    token = env.get("BLINK_PROXY_TOKEN") or env.get("TLDR_PROXY_TOKEN") or ""
    if not token:
        print("ERROR: BLINK_PROXY_TOKEN not set in .env or env.", file=sys.stderr)
        return 2

    bundles: list[Bundle] = []
    if args.bundle:
        bundles.append(load_bundle(Path(args.bundle).expanduser()))
    elif args.corpus:
        root = Path(args.corpus).expanduser()
        for p in find_recent_bundles(root, args.limit):
            try:
                bundles.append(load_bundle(p))
            except Exception as exc:
                print(f"skip {p.name}: {exc}", file=sys.stderr)
    else:
        default_root = Path("~/Library/Application Support/Blink/runs").expanduser()
        for p in find_recent_bundles(default_root, args.limit):
            try:
                bundles.append(load_bundle(p))
            except Exception as exc:
                print(f"skip {p.name}: {exc}", file=sys.stderr)

    if not bundles:
        print("ERROR: no bundles to replay.", file=sys.stderr)
        return 2

    print(f"# url={url} bundles={len(bundles)} model_override={args.model or '-'} thinking_override={args.thinking or '-'} image_prep={args.image_prep} reuse_conn={args.reuse_conn}")
    results: list[ReplayResult] = []
    conn: http.client.HTTPSConnection | None = None
    for i, b in enumerate(bundles):
        for rep in range(args.repeat):
            t0 = time.perf_counter()
            try:
                r, conn_after = replay_once(
                    b,
                    url=url,
                    token=token,
                    override_model=args.model,
                    override_thinking=args.thinking,
                    image_prep_mode=args.image_prep,
                    max_dimension=args.max_dimension,
                    jpeg_quality=args.jpeg_quality,
                    timeout_seconds=args.timeout,
                    warm_conn=conn if args.reuse_conn else None,
                )
            except Exception as exc:
                print(f"  [{i+1}/{len(bundles)} r{rep+1}] {b.path.name}: FATAL {type(exc).__name__}: {exc}", file=sys.stderr)
                continue
            if args.reuse_conn:
                conn = conn_after
            else:
                if conn_after is not None:
                    try:
                        conn_after.close()
                    except Exception:
                        pass
            wall = int(round((time.perf_counter() - t0) * 1000))
            tag = "OK" if r.status == "ok" else r.status.upper()
            print(
                f"  [{i+1}/{len(bundles)} r{rep+1}] {b.path.name} model={r.model} "
                f"prep={r.image_prep_ms}ms mp={r.multipart_build_ms}ms "
                f"conn={r.connect_ms}ms ttfb={r.ttfb_ms}ms "
                f"first_tldr={r.first_partial_tldr_ms}ms final={r.final_event_ms}ms "
                f"server={r.server_duration_ms}ms TOTAL={r.total_wall_ms}ms "
                f"events={r.raw_event_count} bytes={r.multipart_bytes} {tag} {r.error}"
            )
            results.append(r)

    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass

    summary = summarize(results)
    print("\n# summary")
    print(json.dumps(summary, indent=2, sort_keys=True))

    if args.out_csv:
        write_csv(results, Path(args.out_csv).expanduser())
        print(f"# wrote {args.out_csv} ({len(results)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
