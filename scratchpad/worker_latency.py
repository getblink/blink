#!/usr/bin/env python3
"""Prototype harness for the persistent blink_once worker (`--serve`).

Validates the keep-alive worker end-to-end against the real staging proxy,
WITHOUT touching the Swift app, and isolates the client-side latency win:

  * CLI path   - spawn `blink_once.py` fresh per capture (today's behavior:
                 cold Python start + a fresh TLS handshake every time).
  * Worker path- one long-lived `blink_once.py --serve` process; captures
                 after the first reuse the process AND the TLS connection.

For each capture we checkpoint:
  dispatch -> run_started   (~Python spawn+import for CLI; ~0 for warm worker)
  dispatch -> first token   (TTFT; dominated by server generation, noisy)
  dispatch -> final         (total wall clock)

It also injects one deliberately-broken request to prove the worker survives a
failure and keeps serving (the supervision invariant).

Usage:
  set -a && source .env && set +a
  scratchpad/.venv/bin/python scratchpad/worker_latency.py [--n 5]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PYDIR = REPO / "app" / "python"
SCRIPT = PYDIR / "blink_once.py"
CORPUS = Path.home() / "Library" / "Application Support" / "Blink" / "runs"
RUNTIME = {"version": 1, "auto_paste": True, "model": "gemini-3-flash-preview", "style": None}


def _now() -> float:
    return time.perf_counter()


def recent_runs(n: int) -> list[Path]:
    runs = sorted(
        (p for p in CORPUS.iterdir() if p.is_dir() and (p / "request.json").exists()
         and any(p.glob("screenshot_0.*"))),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return runs[:n]


def build_argv(run: Path, out_dir: Path, runtime_path: Path) -> list[str]:
    """Reconstruct the flags Swift would pass, replaying a real capture with a
    fresh request_id so the server treats each as a new request."""
    payload = json.loads((run / "request.json").read_text())
    payload["request_id"] = str(uuid.uuid4())
    shot = next(iter(run.glob("screenshot_0.*")))
    req_json = out_dir / f"req-{payload['request_id']}.json"
    req_json.write_text(json.dumps(payload))
    return [
        "--runtime", str(runtime_path),
        "--out-dir", str(out_dir),
        "--screenshot", str(shot),
        "--request-json", str(req_json),
        "--stream-events",
    ]


def child_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(PYDIR) + os.pathsep + env.get("PYTHONPATH", "")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


# ---- CLI path: fresh process per capture -----------------------------------

def run_cli(argv: list[str]) -> dict:
    t0 = _now()
    proc = subprocess.Popen(
        [sys.executable, str(SCRIPT), *argv],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=child_env(), cwd=str(PYDIR), text=True,
    )
    marks: dict[str, float] = {}
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line).get("event")
        except json.JSONDecodeError:
            continue
        if ev == "run_started" and "run_started" not in marks:
            marks["run_started"] = _now() - t0
        elif ev in ("partial_tldr", "partial_suggestions") and "first" not in marks:
            marks["first"] = _now() - t0
        elif ev in ("final", "error"):
            marks["final"] = _now() - t0
            marks["status"] = ev
    proc.wait()
    return marks


# ---- Worker path: one persistent --serve process ---------------------------

class Worker:
    def __init__(self) -> None:
        self.proc = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--serve"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=child_env(), cwd=str(PYDIR), text=True, bufsize=1,
        )
        self._events: list[dict] = []
        self._lock = threading.Condition()
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            with self._lock:
                self._events.append((ev, _now()))
                self._lock.notify_all()

    def wait_ready(self, timeout: float = 10) -> None:
        self._await(lambda e: e[0].get("event") == "worker_ready", timeout)

    def _await(self, pred, timeout):
        deadline = _now() + timeout
        with self._lock:
            i = 0
            while True:
                while i < len(self._events):
                    if pred(self._events[i]):
                        return self._events[i]
                    i += 1
                remaining = deadline - _now()
                if remaining <= 0:
                    return None
                self._lock.notify_all()
                self._lock.wait(remaining)

    def capture(self, seq: int, argv: list[str], timeout: float = 120) -> dict:
        with self._lock:
            start_idx = len(self._events)
        t0 = _now()
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps({"seq": seq, "argv": argv}) + "\n")
        self.proc.stdin.flush()
        marks: dict[str, float] = {}

        def collect():
            with self._lock:
                deadline = _now() + timeout
                i = start_idx
                while True:
                    while i < len(self._events):
                        ev, ts = self._events[i]
                        i += 1
                        if ev.get("seq") != seq:
                            continue
                        name = ev.get("event")
                        if name == "run_started" and "run_started" not in marks:
                            marks["run_started"] = ts - t0
                        elif name in ("partial_tldr", "partial_suggestions") and "first" not in marks:
                            marks["first"] = ts - t0
                        elif name == "final":
                            marks["final"] = ts - t0
                            marks["status"] = "final"
                        elif name == "error":
                            marks.setdefault("final", ts - t0)
                            marks["status"] = "error"
                        elif name == "worker_done":
                            marks["done"] = ts - t0
                            return
                    if _now() > deadline:
                        marks["status"] = "timeout"
                        return
                    self._lock.wait(deadline - _now())

        collect()
        return marks

    def close(self) -> None:
        try:
            assert self.proc.stdin is not None
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def fmt(v):
    return f"{v*1000:7.0f}ms" if v is not None else "    n/a"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=5)
    args = ap.parse_args()

    if not os.environ.get("BLINK_PROXY_URL"):
        print("Set BLINK_PROXY_URL/BLINK_PROXY_TOKEN first (source .env).", file=sys.stderr)
        return 2

    runs = recent_runs(args.n)
    if len(runs) < 2:
        print(f"Need >=2 corpus runs with screenshots; found {len(runs)}.", file=sys.stderr)
        return 2
    print(f"Replaying {len(runs)} captures from {CORPUS}\n")

    tmp = Path(tempfile.mkdtemp(prefix="blink-worker-"))
    runtime_path = tmp / "runtime.json"
    runtime_path.write_text(json.dumps(RUNTIME))

    # --- CLI path (cold spawn each time) ---
    print("CLI path (fresh process per capture):")
    cli = []
    for i, run in enumerate(runs):
        outd = tmp / f"cli{i}"
        outd.mkdir(exist_ok=True)
        argv = build_argv(run, outd, runtime_path)
        m = run_cli(argv)
        cli.append(m)
        print(f"  cap {i}: run_started={fmt(m.get('run_started'))}  ttft={fmt(m.get('first'))}  total={fmt(m.get('final'))}  [{m.get('status')}]")

    # --- Worker path (one persistent process + keep-alive connection) ---
    print("\nWorker path (persistent --serve, reused process + connection):")
    w = Worker()
    w.wait_ready()
    work = []
    for i, run in enumerate(runs):
        outd = tmp / f"wk{i}"
        outd.mkdir(exist_ok=True)
        argv = build_argv(run, outd, runtime_path)
        m = w.capture(i, argv)
        work.append(m)
        print(f"  cap {i}: run_started={fmt(m.get('run_started'))}  ttft={fmt(m.get('first'))}  total={fmt(m.get('final'))}  [{m.get('status')}]")

    # --- Supervision: inject a broken request, then a good one ---
    print("\nSupervision check (broken request must not kill the worker):")
    bad = w.capture(900, ["--stream-events"])  # missing required flags
    print(f"  broken: status={bad.get('status')}  done={'yes' if 'done' in bad else 'NO'}")
    outd = tmp / "recover"; outd.mkdir(exist_ok=True)
    good = w.capture(901, build_argv(runs[0], outd, runtime_path))
    print(f"  recovery capture: status={good.get('status')}  total={fmt(good.get('final'))}")
    w.close()

    # --- Summary ---
    def med(rows, key):
        return median([r.get(key) for r in rows])
    print("\n--- medians ---")
    print(f"  run_started:  CLI {fmt(med(cli,'run_started'))}   worker {fmt(med(work,'run_started'))}   (spawn saving)")
    print(f"  ttft:         CLI {fmt(med(cli,'first'))}   worker {fmt(med(work,'first'))}")
    print(f"  total:        CLI {fmt(med(cli,'final'))}   worker {fmt(med(work,'final'))}")
    # worker first capture pays spawn+handshake; later captures are the steady state
    if len(work) > 1:
        print(f"\n  worker cap0 (cold) total={fmt(work[0].get('final'))}  vs cap1+ median total={fmt(median([r.get('final') for r in work[1:]]))}")
        print(f"  worker cap0 run_started={fmt(work[0].get('run_started'))}  vs cap1+ median={fmt(median([r.get('run_started') for r in work[1:]]))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
