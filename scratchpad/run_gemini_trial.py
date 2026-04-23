#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


BASE_DIR = Path(__file__).resolve().parent
VENV_PYTHON = BASE_DIR / ".venv" / "bin" / "python"

if (
    VENV_PYTHON.exists()
    and Path(sys.executable).resolve() != VENV_PYTHON.resolve()
    and os.environ.get("BLINK_SKIP_VENV_REEXEC") != "1"
):
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), __file__, *sys.argv[1:]])

try:
    import AppKit
    import ApplicationServices as AS
    import Quartz
    from google import genai
    from google.genai import types
except ImportError as exc:
    print(
        "Missing dependencies. Create a virtualenv and install scratchpad/requirements.txt:\n"
        "  python3.11 -m venv scratchpad/.venv\n"
        "  scratchpad/.venv/bin/pip install -r scratchpad/requirements.txt",
        file=sys.stderr,
    )
    raise SystemExit(1) from exc

from gemini_runner import duration_ms, generate_completion, now_iso, plain_data, prepare_request_image
from env_loader import load_workspace_env
from hotkey import HotkeyListener
from make_trial import slugify
from ocr import recognize_text


PROMPT_PATH = BASE_DIR / "prompt.txt"
SETTINGS_PATH = BASE_DIR / "settings.json"
LAST_OUTPUT_PATH = BASE_DIR / "last_output.txt"
LAST_RUN_PATH = BASE_DIR / "last_run.json"
STATE_DIR = BASE_DIR / "state"
SOURCE_IMAGE_PATH = STATE_DIR / "current_source.png"
SOURCE_STATE_PATH = STATE_DIR / "current_source.json"
PENDING_TARGET_PATH = STATE_DIR / "pending_target.png"

DEFAULT_PROMPT = """You are a precise clipboard assistant.

Use SOURCE_IMAGE as the primary truth for content. Use TARGET_IMAGE plus TARGET_METADATA_JSON to determine the current destination field and any visible formatting constraints.

Return ONLY the text that should be inserted into the intended target field. No explanation, no markdown, no quotes.

If the correct result should be empty, return [[BLANK]].
If you are uncertain, return [[NEEDS_REVIEW: reason in <=12 words]].
"""

DEFAULT_SETTINGS: dict[str, Any] = {
    "model": "gemini-3.1-flash-lite-preview",
    "temperature": 0.0,
    "max_output_tokens": 512,
    "media_resolution": "MEDIA_RESOLUTION_LOW",
    "thinking_level": "MINIMAL",
    "timeout_seconds": 120,
    "stream_to_terminal": True,
    "copy_to_clipboard": True,
    "prompt_accessibility_permissions": True,
    "capture_mode": "window",
    "window_capture_fallback_to_region": True,
    "preprocess_request_images": True,
    "request_image_format": "jpeg",
    "request_image_max_dimension": 1600,
    "request_image_jpeg_quality": 80,
    "log_dir": "runs",
    "fixture_mode": True,
    "fixtures_dir": "fixtures",
    "run_live_gemini_on_capture": True,
    "enable_ocr": True,
    "ocr_language_correction": True,
    "nearby_ax_ancestor_depth": 3,
    "nearby_ax_max_siblings": 12,
    "nearby_ax_value_preview_chars": 120,
    "clipboard_max_chars": 8000,
    "caret_capture": True,
    "notify_on_capture": True,
    "hotkeys": {
        "set_source": "ctrl+shift+c",
        "run_target": "ctrl+shift+v",
    },
}

AX_ERROR_NAMES = {
    AS.kAXErrorSuccess: "success",
    AS.kAXErrorFailure: "failure",
    AS.kAXErrorIllegalArgument: "illegal_argument",
    AS.kAXErrorInvalidUIElement: "invalid_ui_element",
    AS.kAXErrorInvalidUIElementObserver: "invalid_ui_element_observer",
    AS.kAXErrorCannotComplete: "cannot_complete",
    AS.kAXErrorAttributeUnsupported: "attribute_unsupported",
    AS.kAXErrorActionUnsupported: "action_unsupported",
    AS.kAXErrorNotificationUnsupported: "notification_unsupported",
    AS.kAXErrorNotImplemented: "not_implemented",
    AS.kAXErrorNotificationAlreadyRegistered: "notification_already_registered",
    AS.kAXErrorNotificationNotRegistered: "notification_not_registered",
    AS.kAXErrorAPIDisabled: "api_disabled",
    AS.kAXErrorNoValue: "no_value",
    AS.kAXErrorParameterizedAttributeUnsupported: "parameterized_attribute_unsupported",
    AS.kAXErrorNotEnoughPrecision: "not_enough_precision",
}

FIXTURE_SCHEMA_VERSION = 1


@dataclass
class QueuedAction:
    name: str
    hotkey_detected_perf: float
    hotkey_detected_at: str


def load_json_file(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json_file(path: Path, payload: Any) -> None:
    sanitized = plain_data(payload)
    path.write_text(json.dumps(sanitized, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def load_settings() -> dict[str, Any]:
    settings = DEFAULT_SETTINGS.copy()
    if SETTINGS_PATH.exists():
        loaded = load_json_file(SETTINGS_PATH, {})
        settings.update(loaded)
    hotkeys = DEFAULT_SETTINGS["hotkeys"].copy()
    hotkeys.update(settings.get("hotkeys", {}))
    settings["hotkeys"] = hotkeys
    return settings


def read_prompt() -> str:
    if PROMPT_PATH.exists():
        return PROMPT_PATH.read_text(encoding="utf-8").strip()
    return DEFAULT_PROMPT.strip()


def ax_error_name(code: int) -> str:
    return AX_ERROR_NAMES.get(code, f"ax_error_{code}")


def shorten_text(value: Any, limit: int = 240) -> Any:
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        if len(text) <= limit:
            return text
        return text[: limit - 3] + "..."
    return plain_data(value)


def ax_copy_attribute(element, attribute: str) -> tuple[int, Any]:
    return AS.AXUIElementCopyAttributeValue(element, attribute, None)


def ax_value_to_point(value: Any) -> dict[str, float] | None:
    if value is None or AS.AXValueGetType(value) != AS.kAXValueCGPointType:
        return None
    ok, point = AS.AXValueGetValue(value, AS.kAXValueCGPointType, None)
    if not ok:
        return None
    return {"x": float(point.x), "y": float(point.y)}


def ax_value_to_size(value: Any) -> dict[str, float] | None:
    if value is None or AS.AXValueGetType(value) != AS.kAXValueCGSizeType:
        return None
    ok, size = AS.AXValueGetValue(value, AS.kAXValueCGSizeType, None)
    if not ok:
        return None
    return {"width": float(size.width), "height": float(size.height)}


def ax_value_to_rect(value: Any) -> dict[str, float] | None:
    if value is None or AS.AXValueGetType(value) != AS.kAXValueCGRectType:
        return None
    ok, rect = AS.AXValueGetValue(value, AS.kAXValueCGRectType, None)
    if not ok:
        return None
    return {
        "x": float(rect.origin.x),
        "y": float(rect.origin.y),
        "width": float(rect.size.width),
        "height": float(rect.size.height),
    }


def ax_value_to_range(value: Any) -> dict[str, int] | None:
    if value is None or AS.AXValueGetType(value) != AS.kAXValueCFRangeType:
        return None
    ok, selected_range = AS.AXValueGetValue(value, AS.kAXValueCFRangeType, None)
    if not ok:
        return None
    if isinstance(selected_range, tuple) and len(selected_range) >= 2:
        location, length = selected_range[0], selected_range[1]
    elif hasattr(selected_range, "location") and hasattr(selected_range, "length"):
        location, length = selected_range.location, selected_range.length
    else:
        return None
    return {
        "location": int(location),
        "length": int(length),
    }


def normalize_for_paste(
    model_text: str,
    existing_text: str | None,
    caret_pos: int | None,
) -> str:
    """Fix insertion-boundary artifacts before the model output hits the clipboard.

    The model is instructed to emit only the continuation at the caret, but it
    may still repeat the text already in the field (overlap) or emit/drop a
    leading space that collides with what surrounds the caret. This runs after
    generation and handles those cases deterministically so cmd+V lands cleanly.

    caret_pos comes from AX (UTF-16 code units) and is consumed as a Python
    str index (code points). They match for ASCII and BMP text — the content
    these demos target — but can skew by one per astral-plane glyph.
    """
    model_text = model_text.strip("\n")
    if not existing_text:
        return model_text
    before_caret = (
        existing_text[:caret_pos] if caret_pos is not None else existing_text
    )
    for k in range(min(len(before_caret), len(model_text)), 0, -1):
        if model_text.startswith(before_caret[-k:]):
            model_text = model_text[k:]
            break
    if before_caret.endswith((" ", "\n", "\t")):
        model_text = model_text.lstrip(" \t")
    elif (
        model_text
        and before_caret
        and before_caret[-1].isalnum()
        and not model_text[0].isspace()
    ):
        model_text = " " + model_text
    return model_text


def _caret_pos_from_capture(caret: dict[str, Any] | None) -> int | None:
    if not isinstance(caret, dict) or caret.get("status") != "ok":
        return None
    rng = caret.get("range")
    if not isinstance(rng, dict):
        return None
    location = rng.get("location")
    try:
        return int(location) if location is not None else None
    except (TypeError, ValueError):
        return None


TEXT_INPUT_ROLE_NAMES = {
    "AXTextField",
    "AXTextArea",
    "AXComboBox",
    "AXSearchField",
}


class ScratchpadApp:
    def __init__(self) -> None:
        self.settings = load_settings()
        self.prompt_text = read_prompt()
        self.log_dir = BASE_DIR / self.settings["log_dir"]
        self.fixtures_dir = BASE_DIR / self.settings["fixtures_dir"]
        self.action_queue: queue.Queue[QueuedAction] = queue.Queue()
        self.stop_event = threading.Event()
        self.accessibility_prompted = False
        self.client = genai.Client(
            api_key=os.environ.get("GEMINI_API_KEY"),
            http_options=types.HttpOptions(
                timeout=int(self.settings["timeout_seconds"] * 1000)
            ),
        )
        self.worker_thread = threading.Thread(
            target=self._worker_loop,
            name="blink-hotkey-worker",
            daemon=True,
        )
        self.listener = HotkeyListener()
        self._register_hotkeys()

    def start(self) -> None:
        self._ensure_layout()
        self._maybe_prompt_accessibility_permissions()
        self.worker_thread.start()
        self.listener.start()
        self._print_banner()

    def stop(self) -> None:
        self.stop_event.set()
        self.listener.stop()

    def wait(self) -> None:
        while not self.stop_event.is_set():
            time.sleep(0.2)

    def enqueue_action(self, action_name: str) -> bool:
        queued = QueuedAction(
            name=action_name,
            hotkey_detected_perf=time.perf_counter(),
            hotkey_detected_at=now_iso(),
        )
        self.action_queue.put(queued)
        return True

    def request_quit(self) -> bool:
        self.stop_event.set()
        self.listener.stop()
        return True

    def _register_hotkeys(self) -> None:
        hotkeys = self.settings["hotkeys"]
        if hotkeys.get("set_source"):
            self.listener.register(
                hotkeys["set_source"],
                lambda: self.enqueue_action("set_source"),
            )
        if hotkeys.get("run_target"):
            self.listener.register(
                hotkeys["run_target"],
                lambda: self.enqueue_action("run_target"),
            )
        if hotkeys.get("reset_source"):
            self.listener.register(
                hotkeys["reset_source"],
                lambda: self.enqueue_action("reset_source"),
            )
        if hotkeys.get("quit"):
            self.listener.register(
                hotkeys["quit"],
                self.request_quit,
            )

    def _ensure_layout(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.fixtures_dir.mkdir(parents=True, exist_ok=True)

    def _print_banner(self) -> None:
        source_state = self._load_source_state()
        source_status = "loaded" if source_state else "not set"
        permission_snapshot = self._permission_snapshot()
        print("Blink scratchpad is running.")
        print(f"- source: {source_status}")
        print(f"- set source: {self.settings['hotkeys']['set_source']}")
        print(f"- run target: {self.settings['hotkeys']['run_target']}")
        if self.settings["hotkeys"].get("reset_source"):
            print(f"- reset source: {self.settings['hotkeys']['reset_source']}")
        else:
            print("- reset source: capture a new source with ctrl+shift+c")
        if self.settings["hotkeys"].get("quit"):
            print(f"- quit: {self.settings['hotkeys']['quit']}")
        else:
            print("- quit: ctrl+c in the terminal")
        print(f"- fixture mode: {self.settings.get('fixture_mode', True)}")
        print("- permissions:")
        print(
            f"  accessibility_trusted={permission_snapshot['accessibility_trusted']}"
        )
        print(
            f"  screen_capture_access={permission_snapshot['screen_capture_access']}"
        )
        print(
            "  input_monitoring_proxy="
            f"{permission_snapshot['input_monitoring_proxy']}"
        )
        print(
            f"  hotkey_event_tap_started={permission_snapshot['hotkey_event_tap_started']}"
        )
        print(
            f"  hotkey_event_tap_active={permission_snapshot['hotkey_event_tap_active']}"
        )
        if permission_snapshot.get("hotkey_error"):
            print(f"  hotkey_error={permission_snapshot['hotkey_error']}")
        print("- logs:", self.log_dir)
        print("- fixtures:", self.fixtures_dir)
        print("")

    def _worker_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                action = self.action_queue.get(timeout=0.2)
            except queue.Empty:
                continue

            try:
                if action.name == "set_source":
                    self._handle_set_source(action)
                elif action.name == "run_target":
                    self._handle_run_target(action)
                elif action.name == "reset_source":
                    self._handle_reset_source(action)
            except Exception as exc:
                print(f"[worker] Error during {action.name}: {exc}", file=sys.stderr)
            finally:
                self.action_queue.task_done()

    def _status(
        self,
        event: str,
        *,
        detail: str | None = None,
        run_log: dict[str, Any] | None = None,
        prefix: str = "*",
    ) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        message = f"[{timestamp}] {prefix} {event}"
        if detail:
            message = f"{message} ({detail})"
        print(message)
        if run_log is not None:
            run_log.setdefault("status_events", []).append(
                {"at": now_iso(), "event": event, "detail": detail, "prefix": prefix}
            )

    def _notify(self, message: str) -> None:
        if not self.settings.get("notify_on_capture", True):
            return
        safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                f'display notification "{safe_message}" with title "Blink" sound name ""',
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def _format_bytes(self, size_bytes: int | None) -> str:
        if size_bytes is None:
            return "unknown size"
        units = ["B", "KB", "MB", "GB"]
        value = float(size_bytes)
        for unit in units:
            if value < 1024.0 or unit == units[-1]:
                if unit == "B":
                    return f"{int(value)}{unit}"
                return f"{value:.1f}{unit}"
            value /= 1024.0
        return f"{size_bytes}B"

    def _handle_set_source(self, action: QueuedAction) -> None:
        del action
        self._status("source capture...", prefix=">")
        print(self._capture_instruction("source", "reusable source context"))
        pending_path = STATE_DIR / "pending_source.png"
        capture = self._capture_screenshot(pending_path)
        if capture["status"] != "ok":
            detail = capture.get("stderr") or capture.get("stdout") or "no details"
            self._status("source capture failed", detail=detail, prefix="!")
            return

        captured_at = now_iso()
        pending_path.replace(SOURCE_IMAGE_PATH)
        source_state = {
            "captured_at": captured_at,
            "path": str(SOURCE_IMAGE_PATH),
            "bytes": SOURCE_IMAGE_PATH.stat().st_size,
            "capture": capture,
        }
        save_json_file(SOURCE_STATE_PATH, source_state)
        self._status(
            "source captured",
            detail=f"{capture['duration_ms']}ms, {self._format_bytes(source_state['bytes'])}",
            prefix="+",
        )
        self._notify("Source captured")

    def _handle_reset_source(self, action: QueuedAction) -> None:
        del action
        if SOURCE_IMAGE_PATH.exists():
            SOURCE_IMAGE_PATH.unlink()
        if SOURCE_STATE_PATH.exists():
            SOURCE_STATE_PATH.unlink()
        self._status("source cleared", prefix="+")

    def _handle_run_target(self, action: QueuedAction) -> None:
        if self.settings.get("fixture_mode", True):
            self._handle_run_target_fixture(action)
            return
        self._handle_run_target_legacy(action)

    def _base_run_log(self, run_dir: Path, action: QueuedAction) -> dict[str, Any]:
        return {
            "run_id": run_dir.name,
            "status": "started",
            "settings": self.settings,
            "permissions": self._permission_snapshot(),
            "prompt_path": str(PROMPT_PATH),
            "hotkey_detected_at": action.hotkey_detected_at,
            "timings": {},
            "errors": [],
            "warnings": [],
            "status_events": [],
        }

    def _permission_snapshot(self) -> dict[str, Any]:
        listener_status = self.listener.status_snapshot()
        return {
            "accessibility_trusted": bool(AS.AXIsProcessTrusted()),
            "screen_capture_access": bool(Quartz.CGPreflightScreenCaptureAccess()),
            "input_monitoring_proxy": "hotkey_event_tap",
            "hotkey_event_tap_started": bool(listener_status["started"]),
            "hotkey_event_tap_active": bool(listener_status["tap_active"]),
            "hotkey_run_loop_active": bool(listener_status["run_loop_active"]),
            "hotkey_binding_count": int(listener_status["binding_count"]),
            "hotkey_error": listener_status["last_error"],
        }

    def _handle_run_target_legacy(self, action: QueuedAction) -> None:
        run_dir = self._make_run_dir()
        run_log = self._base_run_log(run_dir, action)
        source_state = self._load_source_state()
        if not source_state or not SOURCE_IMAGE_PATH.exists():
            run_log["status"] = "missing_source"
            run_log["errors"].append("No source capture is set. Use the set-source hotkey first.")
            self._persist_run_artifacts(run_dir, run_log, "")
            self._status("missing source", detail="press the set-source hotkey first", run_log=run_log, prefix="!")
            return

        source_copy_path = run_dir / "source.png"
        shutil.copy2(SOURCE_IMAGE_PATH, source_copy_path)
        run_log["source"] = {
            "state": source_state,
            "copied_path": str(source_copy_path),
            "bytes": source_copy_path.stat().st_size,
        }

        metadata_started_perf = time.perf_counter()
        metadata_started_at = now_iso()
        self._status("target metadata...", run_log=run_log, prefix=">")
        target_metadata, _, _ = self._capture_target_metadata()
        metadata_finished_perf = time.perf_counter()
        run_log["target_metadata"] = target_metadata
        run_log["target_metadata_debug"] = target_metadata.get("_debug")
        run_log["timings"]["target_metadata_started_at"] = metadata_started_at
        run_log["timings"]["target_metadata_finished_at"] = now_iso()
        run_log["timings"]["target_metadata_ms"] = duration_ms(
            metadata_started_perf, metadata_finished_perf
        )
        run_log["timings"]["queue_delay_ms"] = duration_ms(
            action.hotkey_detected_perf, metadata_started_perf
        )
        self._status(
            "target metadata captured",
            detail=self._target_metadata_status_detail(target_metadata),
            run_log=run_log,
            prefix="+",
        )
        self._emit_target_metadata_warnings(target_metadata, run_log)

        target_path = run_dir / "target.png"
        self._status("target screenshot...", run_log=run_log, prefix=">")
        print(self._capture_instruction("target", "destination context"))
        capture_started_perf = time.perf_counter()
        run_log["timings"]["target_screenshot_started_at"] = now_iso()
        capture = self._capture_screenshot(target_path)
        capture_finished_perf = time.perf_counter()
        run_log["timings"]["target_screenshot_finished_at"] = now_iso()
        run_log["timings"]["target_screenshot_ms"] = duration_ms(
            capture_started_perf, capture_finished_perf
        )
        run_log["target_capture"] = capture

        if capture["status"] != "ok":
            run_log["status"] = capture["status"]
            self._persist_run_artifacts(run_dir, run_log, "")
            detail = capture.get("stderr") or capture.get("stdout") or "no details"
            self._status("target capture failed", detail=detail, run_log=run_log, prefix="!")
            return

        self._status(
            "target captured",
            detail=f"{capture['duration_ms']}ms, {self._format_bytes(capture.get('bytes'))}",
            run_log=run_log,
            prefix="+",
        )
        self._run_generation(
            run_dir=run_dir,
            run_log=run_log,
            action=action,
            source_path=source_copy_path,
            target_path=target_path,
            target_metadata=target_metadata,
        )

    def _handle_run_target_fixture(self, action: QueuedAction) -> None:
        run_dir = self._make_run_dir()
        run_log = self._base_run_log(run_dir, action)
        source_state = self._load_source_state()
        if not source_state or not SOURCE_IMAGE_PATH.exists():
            run_log["status"] = "missing_source"
            run_log["errors"].append("No source capture is set. Use the set-source hotkey first.")
            self._persist_run_artifacts(run_dir, run_log, "")
            self._status("missing source", detail="press the set-source hotkey first", run_log=run_log, prefix="!")
            return

        if PENDING_TARGET_PATH.exists():
            PENDING_TARGET_PATH.unlink()

        try:
            metadata_started_perf = time.perf_counter()
            metadata_started_at = now_iso()
            run_log["timings"]["queue_delay_ms"] = duration_ms(
                action.hotkey_detected_perf, metadata_started_perf
            )
            self._status("target metadata...", run_log=run_log, prefix=">")
            target_metadata, focused_element, app_element = self._capture_target_metadata()
            metadata_finished_perf = time.perf_counter()
            run_log["target_metadata"] = target_metadata
            run_log["target_metadata_debug"] = target_metadata.get("_debug")
            run_log["timings"]["target_metadata_started_at"] = metadata_started_at
            run_log["timings"]["target_metadata_finished_at"] = now_iso()
            run_log["timings"]["target_metadata_ms"] = duration_ms(
                metadata_started_perf, metadata_finished_perf
            )
            self._status(
                "target metadata captured",
                detail=self._target_metadata_status_detail(target_metadata),
                run_log=run_log,
                prefix="+",
            )
            self._emit_target_metadata_warnings(target_metadata, run_log)

            chrome_ax_empty = self._detect_chrome_ax_empty(
                target_metadata.get("frontmost_app"), app_element
            )
            ax_focused = self._capture_focused_ax(focused_element)

            nearby_started_perf = time.perf_counter()
            nearby_ax = self._capture_nearby_ax(
                focused_element,
                chrome_ax_empty=chrome_ax_empty,
            )
            run_log["timings"]["nearby_ax_ms"] = duration_ms(nearby_started_perf)
            if nearby_ax["status"] == "ok":
                nearby_count = sum(
                    len(item.get("children", [])) for item in nearby_ax.get("ancestors", [])
                )
                self._status(
                    "AX walk",
                    detail=f"focused + {nearby_count} nearby",
                    run_log=run_log,
                    prefix="+",
                )
            else:
                self._status(
                    "AX walk",
                    detail=nearby_ax.get("status", "unavailable"),
                    run_log=run_log,
                    prefix="+",
                )

            caret_started_perf = time.perf_counter()
            caret = self._capture_caret(focused_element)
            run_log["timings"]["caret_ms"] = duration_ms(caret_started_perf)

            geometry_started_perf = time.perf_counter()
            geometry = self._capture_geometry(
                target_metadata.get("frontmost_pid"),
                focused_element,
                app_element,
            )
            run_log["timings"]["geometry_ms"] = duration_ms(geometry_started_perf)

            clipboard_started_perf = time.perf_counter()
            clipboard = self._read_clipboard()
            run_log["timings"]["clipboard_capture_ms"] = duration_ms(clipboard_started_perf)

            self._status("target screenshot...", run_log=run_log, prefix=">")
            print(self._capture_instruction("target", "destination context"))
            capture_started_perf = time.perf_counter()
            run_log["timings"]["target_screenshot_started_at"] = now_iso()
            capture = self._capture_screenshot(PENDING_TARGET_PATH)
            capture_finished_perf = time.perf_counter()
            run_log["timings"]["target_screenshot_finished_at"] = now_iso()
            run_log["timings"]["target_screenshot_ms"] = duration_ms(
                capture_started_perf, capture_finished_perf
            )
            if capture["status"] != "ok":
                run_log["status"] = capture["status"]
                detail = capture.get("stderr") or capture.get("stdout") or "no details"
                run_log["errors"].append(detail)
                self._persist_run_artifacts(run_dir, run_log, "")
                self._status("target capture failed", detail=detail, run_log=run_log, prefix="!")
                return
            self._status(
                "target captured",
                detail=f"{capture['duration_ms']}ms, {self._format_bytes(capture.get('bytes'))}",
                run_log=run_log,
                prefix="+",
            )

            ocr_started_perf = time.perf_counter()
            ocr = self._capture_ocr(PENDING_TARGET_PATH)
            run_log["timings"]["ocr_ms"] = duration_ms(ocr_started_perf)
            if ocr["status"] == "ok":
                self._status(
                    "OCR",
                    detail=f"{len(ocr.get('blocks', []))} blocks",
                    run_log=run_log,
                    prefix="+",
                )
            else:
                self._status(
                    "OCR",
                    detail=ocr.get("status", "unknown"),
                    run_log=run_log,
                    prefix="+",
                )

            fixture_dir = self._make_fixture_dir(
                self._fixture_slug(
                    target_metadata.get("focused_app")
                    or target_metadata.get("frontmost_app"),
                    target_metadata.get("focused_role"),
                )
            )
            fixture_manifest = self._write_fixture(
                fixture_dir=fixture_dir,
                source_state=source_state,
                target_capture=capture,
                target_metadata=target_metadata,
                ax_focused=ax_focused,
                nearby_ax=nearby_ax,
                chrome_ax_empty=chrome_ax_empty,
                caret=caret,
                geometry=geometry,
                clipboard=clipboard,
                ocr=ocr,
            )
            run_log["fixture_id"] = fixture_manifest["fixture_id"]
            run_log["fixture_path"] = str(fixture_dir)
            run_log["fixture_slug"] = fixture_manifest["slug"]
            self._status(
                "fixture saved",
                detail=fixture_dir.name,
                run_log=run_log,
                prefix="+",
            )
            self._notify(f"Fixture saved · {fixture_manifest['slug']}")

            if not self.settings.get("run_live_gemini_on_capture", True):
                run_log["status"] = "captured"
                self._persist_run_artifacts(run_dir, run_log, "")
                return

            self._run_generation(
                run_dir=run_dir,
                run_log=run_log,
                action=action,
                source_path=fixture_dir / "source.png",
                target_path=fixture_dir / "target.png",
                target_metadata=fixture_manifest["target_metadata"],
                caret=caret,
            )
        finally:
            if PENDING_TARGET_PATH.exists():
                PENDING_TARGET_PATH.unlink()

    def _run_generation(
        self,
        *,
        run_dir: Path,
        run_log: dict[str, Any],
        action: QueuedAction,
        source_path: Path,
        target_path: Path,
        target_metadata: dict[str, Any],
        caret: dict[str, Any] | None = None,
    ) -> None:
        generation = generate_completion(
            self.client,
            self.settings,
            self.prompt_text,
            source_path,
            target_path,
            target_metadata,
            status_callback=lambda message: self._status(message, run_log=run_log, prefix=">"),
        )
        generation_log = generation["run_log"]
        run_log["status"] = generation_log["status"]
        run_log["request"] = generation_log["request"]
        run_log["response"] = generation_log["response"]
        run_log.setdefault("timings", {}).update(generation_log["timings"])
        if generation_log.get("errors"):
            run_log.setdefault("errors", []).extend(generation_log["errors"])
        output_text = generation["output_text"]

        existing_text = (
            target_metadata.get("focused_value")
            if isinstance(target_metadata, dict)
            else None
        )
        caret_pos = _caret_pos_from_capture(caret)
        pasted_text = normalize_for_paste(
            output_text,
            existing_text if isinstance(existing_text, str) else None,
            caret_pos,
        )
        run_log["paste"] = {
            "text": pasted_text,
            "model_text": output_text,
            "normalized": pasted_text != output_text,
            "caret_pos": caret_pos,
            "existing_text_length": (
                len(existing_text) if isinstance(existing_text, str) else None
            ),
        }

        clipboard = {
            "copied": False,
            "started_at": None,
            "finished_at": None,
            "duration_ms": None,
        }
        if run_log["status"] == "ok" and self.settings.get("copy_to_clipboard", True):
            clipboard_started_perf = time.perf_counter()
            clipboard["started_at"] = now_iso()
            self._copy_to_clipboard(pasted_text)
            clipboard["finished_at"] = now_iso()
            clipboard["duration_ms"] = duration_ms(clipboard_started_perf)
            clipboard["copied"] = True
        run_log["clipboard"] = clipboard

        clipboard_ready_perf = time.perf_counter()
        run_log["timings"]["clipboard_ready_at"] = now_iso()
        run_log["timings"]["end_to_end_ms"] = duration_ms(
            action.hotkey_detected_perf, clipboard_ready_perf
        )
        self._persist_run_artifacts(run_dir, run_log, output_text)

        if self.settings.get("stream_to_terminal", True):
            print("")
        if run_log["status"] == "ok":
            copied_detail = "copied to clipboard" if clipboard["copied"] else "ready"
            self._status(
                "done",
                detail=f"{copied_detail} · {run_log['timings']['end_to_end_ms']}ms total",
                run_log=run_log,
                prefix="+",
            )
            self._notify("Gemini ready · copied" if clipboard["copied"] else "Gemini ready")
        else:
            error_message = run_log.get("errors", ["unknown error"])[-1]
            self._status("generation failed", detail=error_message, run_log=run_log, prefix="!")

    def _make_run_dir(self) -> Path:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
        run_dir = self.log_dir / timestamp
        run_dir.mkdir(parents=True, exist_ok=False)
        return run_dir

    def _target_metadata_status_detail(self, target_metadata: dict[str, Any]) -> str:
        status = str(target_metadata.get("status", "unknown"))
        if status == "ok":
            app_name = target_metadata.get("frontmost_app")
            role = target_metadata.get("focused_role")
            label = target_metadata.get("focused_label") or target_metadata.get("focused_title")
            if app_name and role and label:
                return f"ok · {app_name} · {role} · {label}"
            if app_name and role:
                return f"ok · {app_name} · {role}"
            if role and label:
                return f"ok · {role} · {label}"
            if role:
                return f"ok · {role}"
            return "ok"
        extra = target_metadata.get("error_detail") or target_metadata.get("error")
        return f"{status} · {extra}" if extra else status

    def _emit_target_metadata_warnings(
        self, target_metadata: dict[str, Any], run_log: dict[str, Any]
    ) -> None:
        warnings = list(target_metadata.get("warnings") or [])
        if not warnings:
            return
        run_log.setdefault("warnings", []).extend(warnings)
        for warning in warnings:
            self._status("metadata warning", detail=warning, run_log=run_log, prefix="~")

    def _make_fixture_dir(self, slug: str) -> Path:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
        fixture_dir = self.fixtures_dir / f"{timestamp}-{slug}"
        fixture_dir.mkdir(parents=True, exist_ok=False)
        return fixture_dir

    def _fixture_slug(self, frontmost_app: Any, focused_role: Any) -> str:
        app_slug = slugify(str(frontmost_app or "unknown-app"))
        role_slug = slugify(str(focused_role or "unknown-role"))
        return f"{app_slug}-{role_slug}"

    def _load_source_state(self) -> dict[str, Any] | None:
        if not SOURCE_STATE_PATH.exists():
            return None
        return load_json_file(SOURCE_STATE_PATH, None)

    def _maybe_prompt_accessibility_permissions(self) -> None:
        if not self.settings.get("prompt_accessibility_permissions", True):
            return
        if self.accessibility_prompted:
            return
        if AS.AXIsProcessTrusted():
            return
        AS.AXIsProcessTrustedWithOptions({AS.kAXTrustedCheckOptionPrompt: True})
        self.accessibility_prompted = True

    def _capture_instruction(self, label: str, purpose: str) -> str:
        capture_mode = self.settings.get("capture_mode")
        if capture_mode == "window":
            return (
                f"[{label}] Select the {purpose} window. "
                "If macOS rejects it, the runner will retry with region selection."
            )
        return f"[{label}] Select a {capture_mode} for the {purpose}."

    def _capture_screenshot(self, output_path: Path) -> dict[str, Any]:
        if output_path.exists():
            output_path.unlink()

        requested_mode = self.settings.get("capture_mode")

        def run_attempt(effective_mode: str) -> dict[str, Any]:
            if output_path.exists():
                output_path.unlink()

            started_perf = time.perf_counter()
            started_at = now_iso()
            command = ["/usr/sbin/screencapture", "-i", "-x", "-t", "png"]
            if effective_mode == "window":
                command.append("-W")
            elif effective_mode == "region":
                command.append("-s")
            command.append(str(output_path))
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
            )
            finished_perf = time.perf_counter()
            finished_at = now_iso()

            status = "ok"
            if result.returncode != 0 or not output_path.exists():
                stderr_text = (result.stderr or "").strip()
                if stderr_text:
                    lowered = stderr_text.lower()
                    if "not authorized" in lowered or "not permitted" in lowered:
                        status = "permission_denied"
                    else:
                        status = "error"
                else:
                    status = "cancelled"

            payload = {
                "status": status,
                "requested_capture_mode": requested_mode,
                "effective_capture_mode": effective_mode,
                "command": command,
                "started_at": started_at,
                "finished_at": finished_at,
                "duration_ms": duration_ms(started_perf, finished_perf),
                "returncode": result.returncode,
                "stdout": (result.stdout or "").strip(),
                "stderr": (result.stderr or "").strip(),
            }
            if status == "ok":
                payload["bytes"] = output_path.stat().st_size
                payload["path"] = str(output_path)
            return payload

        attempts = [run_attempt(requested_mode)]
        first_attempt = attempts[0]
        first_error = (first_attempt.get("stderr") or "").lower()
        should_retry_with_region = (
            requested_mode == "window"
            and self.settings.get("window_capture_fallback_to_region", True)
            and first_attempt["status"] == "error"
            and "could not create image from window" in first_error
        )

        if should_retry_with_region:
            print("[capture] Window snapshot failed; retrying with region selection.")
            attempts.append(run_attempt("region"))

        final_attempt = attempts[-1].copy()
        final_attempt["capture_mode"] = requested_mode
        final_attempt["attempts"] = attempts
        if len(attempts) > 1:
            final_attempt["fallback_used"] = (
                final_attempt["effective_capture_mode"] != requested_mode
            )
            final_attempt["fallback_reason"] = "window_capture_failed"
        else:
            final_attempt["fallback_used"] = False
        return final_attempt

    def _capture_target_metadata(self) -> tuple[dict[str, Any], Any, Any]:
        metadata: dict[str, Any] = {
            "status": "ok",
            "frontmost_app": None,
            "frontmost_window_title": None,
            "frontmost_pid": None,
            "workspace_frontmost_app": None,
            "workspace_frontmost_window_title": None,
            "workspace_frontmost_pid": None,
            "focused_app": None,
            "focused_app_pid": None,
            "focused_app_bundle_id": None,
            "focused_role": None,
            "focused_subrole": None,
            "focused_title": None,
            "focused_description": None,
            "focused_label": None,
            "focused_value_preview": None,
            "focused_bounds": None,
            "permission": self._permission_snapshot(),
            "warnings": [],
            "_full": {},
            "_debug": {},
        }

        frontmost = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        if frontmost is not None:
            metadata["workspace_frontmost_app"] = frontmost.localizedName()
            metadata["workspace_frontmost_pid"] = int(frontmost.processIdentifier())
            metadata["_debug"]["workspace_frontmost_bundle_id"] = frontmost.bundleIdentifier()

        metadata["frontmost_app"] = metadata["workspace_frontmost_app"]
        metadata["frontmost_pid"] = metadata["workspace_frontmost_pid"]
        metadata["_debug"]["frontmost_bundle_id"] = metadata["_debug"].get(
            "workspace_frontmost_bundle_id"
        )

        if not metadata["permission"]["accessibility_trusted"]:
            metadata["status"] = "permission_denied"
            metadata["error"] = "Accessibility access is not granted."
            metadata["_full"] = plain_data(metadata)
            return metadata, None, None

        system_wide = AS.AXUIElementCreateSystemWide()
        focused_error, focused_element = ax_copy_attribute(
            system_wide, AS.kAXFocusedUIElementAttribute
        )

        workspace_app_element = None
        if metadata.get("workspace_frontmost_pid"):
            workspace_app_element = AS.AXUIElementCreateApplication(
                metadata["workspace_frontmost_pid"]
            )
            window_title = self._get_window_title(workspace_app_element)
            if window_title:
                metadata["workspace_frontmost_window_title"] = shorten_text(window_title)

        metadata["frontmost_window_title"] = metadata["workspace_frontmost_window_title"]

        diagnostics = self._build_ax_diagnostics(
            system_wide=system_wide,
            app_element=workspace_app_element,
            focused_error=focused_error,
            focused_element=focused_element,
        )
        metadata["_debug"].update(diagnostics)

        resolved_element = focused_element if focused_error == AS.kAXErrorSuccess else None
        resolve_strategy = "system_wide_focused_ui_element"
        if resolved_element is None and workspace_app_element is not None:
            resolved_element, resolve_strategy = self._resolve_focused_element_with_fallbacks(
                workspace_app_element, diagnostics
            )

        if resolved_element is None:
            metadata["status"] = "not_found"
            metadata["error"] = ax_error_name(focused_error)
            metadata["error_detail"] = diagnostics.get("focus_resolution_summary")
            metadata["_full"] = {
                "status": metadata["status"],
                "frontmost_app": metadata["frontmost_app"],
                "frontmost_window_title": metadata["frontmost_window_title"],
                "frontmost_pid": metadata["frontmost_pid"],
                "workspace_frontmost_app": metadata["workspace_frontmost_app"],
                "workspace_frontmost_window_title": metadata["workspace_frontmost_window_title"],
                "workspace_frontmost_pid": metadata["workspace_frontmost_pid"],
                "focused_app": metadata["focused_app"],
                "focused_app_pid": metadata["focused_app_pid"],
                "focused_app_bundle_id": metadata["focused_app_bundle_id"],
                "focused_role": None,
                "focused_subrole": None,
                "focused_title": None,
                "focused_description": None,
                "focused_value": None,
                "focused_label": None,
                "focused_bounds": None,
                "permission": metadata["permission"],
                "warnings": metadata["warnings"],
            }
            return metadata, None, workspace_app_element

        focused_app_info = self._ax_element_owner_info(resolved_element)
        metadata["_debug"]["focused_element_owner"] = focused_app_info

        app_element = workspace_app_element
        if focused_app_info and focused_app_info.get("pid") is not None:
            metadata["focused_app"] = focused_app_info.get("name")
            metadata["focused_app_pid"] = focused_app_info.get("pid")
            metadata["focused_app_bundle_id"] = focused_app_info.get("bundle_id")
            if metadata["focused_app_pid"] != metadata.get("workspace_frontmost_pid"):
                metadata["warnings"].append(
                    "workspace_frontmost_app="
                    f"{metadata.get('workspace_frontmost_app') or 'unknown'} differs from "
                    "focused_element_owner="
                    f"{metadata.get('focused_app') or metadata.get('focused_app_pid')}"
                )
            app_element = AS.AXUIElementCreateApplication(metadata["focused_app_pid"])
            metadata["frontmost_app"] = metadata["focused_app"] or metadata["frontmost_app"]
            metadata["frontmost_pid"] = metadata["focused_app_pid"]
            metadata["_debug"]["frontmost_bundle_id"] = metadata["focused_app_bundle_id"]

        resolved_window_title = self._get_window_title(app_element)
        if resolved_window_title:
            metadata["frontmost_window_title"] = shorten_text(resolved_window_title)
        metadata["_debug"]["resolved_target_app"] = {
            "name": metadata["frontmost_app"],
            "pid": metadata["frontmost_pid"],
            "bundle_id": metadata["_debug"].get("frontmost_bundle_id"),
            "window_title": metadata["frontmost_window_title"],
        }

        full_metadata = {
            "status": metadata["status"],
            "frontmost_app": metadata["frontmost_app"],
            "frontmost_window_title": (
                self._get_window_title(app_element) if app_element is not None else None
            )
            or metadata["frontmost_window_title"],
            "frontmost_pid": metadata["frontmost_pid"],
            "workspace_frontmost_app": metadata["workspace_frontmost_app"],
            "workspace_frontmost_window_title": metadata["workspace_frontmost_window_title"],
            "workspace_frontmost_pid": metadata["workspace_frontmost_pid"],
            "focused_app": metadata["focused_app"],
            "focused_app_pid": metadata["focused_app_pid"],
            "focused_app_bundle_id": metadata["focused_app_bundle_id"],
            "focused_role": self._get_attr_value(resolved_element, AS.kAXRoleAttribute),
            "focused_subrole": self._get_attr_value(resolved_element, AS.kAXSubroleAttribute),
            "focused_title": self._get_attr_value(resolved_element, AS.kAXTitleAttribute),
            "focused_description": self._get_attr_value(
                resolved_element, AS.kAXDescriptionAttribute
            ),
            "focused_value": self._get_attr_value(resolved_element, AS.kAXValueAttribute),
            "focused_label": self._resolve_label(resolved_element),
            "focused_bounds": self._resolve_bounds(resolved_element),
            "permission": metadata["permission"],
            "warnings": metadata["warnings"],
            "focus_resolution_strategy": resolve_strategy,
        }

        metadata["focused_role"] = shorten_text(full_metadata["focused_role"])
        metadata["focused_subrole"] = shorten_text(full_metadata["focused_subrole"])
        metadata["focused_title"] = shorten_text(full_metadata["focused_title"])
        metadata["focused_description"] = shorten_text(full_metadata["focused_description"])
        metadata["focused_value_preview"] = shorten_text(full_metadata["focused_value"])
        metadata["focused_label"] = shorten_text(full_metadata["focused_label"])
        metadata["focused_bounds"] = full_metadata["focused_bounds"]
        metadata["_full"] = plain_data(full_metadata)
        metadata["_debug"]["focus_resolution_strategy"] = resolve_strategy
        return metadata, resolved_element, app_element

    def _ax_element_pid(self, element) -> int | None:
        if element is None:
            return None
        try:
            error, pid = AS.AXUIElementGetPid(element, None)
        except Exception:
            return None
        if error != AS.kAXErrorSuccess or pid is None:
            return None
        return int(pid)

    def _running_app_info(self, pid: Any) -> dict[str, Any] | None:
        if pid is None:
            return None
        try:
            pid_int = int(pid)
        except (TypeError, ValueError):
            return None
        app = AppKit.NSRunningApplication.runningApplicationWithProcessIdentifier_(pid_int)
        return {
            "pid": pid_int,
            "name": app.localizedName() if app is not None else None,
            "bundle_id": app.bundleIdentifier() if app is not None else None,
        }

    def _ax_element_owner_info(self, element) -> dict[str, Any] | None:
        return self._running_app_info(self._ax_element_pid(element))

    def _ax_attribute_status(self, element, attribute: str) -> dict[str, Any]:
        if element is None:
            return {"attribute": attribute, "status": "missing_element"}
        error, value = ax_copy_attribute(element, attribute)
        payload = {"attribute": attribute, "status": ax_error_name(error)}
        if error == AS.kAXErrorSuccess:
            payload["value_type"] = type(value).__name__
            if isinstance(value, (list, tuple)):
                payload["count"] = len(value)
            elif isinstance(value, str):
                payload["value_preview"] = shorten_text(value, 120)
            elif isinstance(value, (int, float, bool)):
                payload["value"] = value
            elif attribute in (AS.kAXPositionAttribute, AS.kAXSizeAttribute):
                payload["value"] = plain_data(value)
        return payload

    def _element_token(self, element) -> str:
        return str(element)

    def _build_ax_diagnostics(
        self,
        *,
        system_wide,
        app_element,
        focused_error: int,
        focused_element,
    ) -> dict[str, Any]:
        diagnostics: dict[str, Any] = {
            "system_wide": {
                "focused_ui_element": {
                    "status": ax_error_name(focused_error),
                    "resolved": focused_element is not None,
                },
                "focused_application": self._ax_attribute_status(
                    system_wide, AS.kAXFocusedApplicationAttribute
                ),
            },
            "workspace_frontmost_app": {
                "focused_window": self._ax_attribute_status(
                    app_element, AS.kAXFocusedWindowAttribute
                ),
                "main_window": self._ax_attribute_status(
                    app_element, AS.kAXMainWindowAttribute
                ),
                "focused_ui_element": self._ax_attribute_status(
                    app_element, AS.kAXFocusedUIElementAttribute
                ),
                "windows": self._ax_attribute_status(app_element, AS.kAXWindowsAttribute),
            },
        }
        active_attr = getattr(AS, "kAXActiveElementAttribute", None)
        if active_attr:
            diagnostics["workspace_frontmost_app"]["active_element"] = self._ax_attribute_status(
                app_element, active_attr
            )
        shared_focus_attr = getattr(AS, "kAXSharedFocusElementsAttribute", None)
        if shared_focus_attr:
            diagnostics["workspace_frontmost_app"]["shared_focus_elements"] = self._ax_attribute_status(
                app_element, shared_focus_attr
            )

        focused_window = self._get_window_element(app_element)
        if focused_window is not None:
            diagnostics["workspace_frontmost_window"] = {
                "role": self._get_attr_value(focused_window, AS.kAXRoleAttribute),
                "subrole": self._get_attr_value(focused_window, AS.kAXSubroleAttribute),
                "title": shorten_text(
                    self._get_attr_value(focused_window, AS.kAXTitleAttribute), 120
                ),
                "children": self._ax_attribute_status(
                    focused_window, AS.kAXChildrenAttribute
                ),
                "visible_children": self._ax_attribute_status(
                    focused_window, AS.kAXVisibleChildrenAttribute
                )
                if hasattr(AS, "kAXVisibleChildrenAttribute")
                else {"status": "unsupported"},
            }
        diagnostics["focus_resolution_summary"] = "no focused element resolved yet"
        return diagnostics

    def _resolve_focused_element_with_fallbacks(
        self, app_element, diagnostics: dict[str, Any]
    ) -> tuple[Any, str]:
        strategies: list[tuple[str, Any]] = []

        app_focused = self._get_attr_value(app_element, AS.kAXFocusedUIElementAttribute)
        if app_focused is not None:
            strategies.append(("workspace_frontmost_app_focused_ui_element", app_focused))

        active_attr = getattr(AS, "kAXActiveElementAttribute", None)
        if active_attr:
            active_element = self._get_attr_value(app_element, active_attr)
            if active_element is not None:
                strategies.append(("workspace_frontmost_app_active_element", active_element))

        shared_focus_attr = getattr(AS, "kAXSharedFocusElementsAttribute", None)
        if shared_focus_attr:
            shared_focus = self._get_attr_value(app_element, shared_focus_attr)
            if isinstance(shared_focus, (list, tuple)):
                diagnostics.setdefault("fallback_probe", {})["shared_focus_count"] = len(
                    shared_focus
                )
                if shared_focus:
                    strategies.append(
                        ("workspace_frontmost_app_shared_focus_elements[0]", shared_focus[0])
                    )

        for strategy_name, candidate in strategies:
            if candidate is None:
                continue
            if self._looks_like_focus_candidate(candidate):
                diagnostics["focus_resolution_summary"] = f"resolved via {strategy_name}"
                return candidate, strategy_name

        window = self._get_window_element(app_element)
        if window is not None:
            descendant = self._find_focus_candidate_in_subtree(window, diagnostics)
            if descendant is not None:
                diagnostics["focus_resolution_summary"] = "resolved via focused_window_subtree_probe"
                return descendant, "focused_window_subtree_probe"

        diagnostics["focus_resolution_summary"] = "no focused or editable candidate found via fallbacks"
        return None, "not_found"

    def _looks_like_focus_candidate(self, element) -> bool:
        if element is None:
            return False
        focused_flag = self._get_attr_value(element, AS.kAXFocusedAttribute)
        if focused_flag is True:
            return True
        role = self._get_attr_value(element, AS.kAXRoleAttribute)
        if isinstance(role, str) and role in TEXT_INPUT_ROLE_NAMES:
            return True
        selected_range = self._get_attr_value(element, AS.kAXSelectedTextRangeAttribute)
        if selected_range is not None:
            return True
        return False

    def _candidate_score(self, element) -> int:
        score = 0
        focused_flag = self._get_attr_value(element, AS.kAXFocusedAttribute)
        if focused_flag is True:
            score += 100
        role = self._get_attr_value(element, AS.kAXRoleAttribute)
        if isinstance(role, str) and role in TEXT_INPUT_ROLE_NAMES:
            score += 50
        selected_range = self._get_attr_value(element, AS.kAXSelectedTextRangeAttribute)
        if selected_range is not None:
            score += 25
        value = self._get_attr_value(element, AS.kAXValueAttribute)
        if isinstance(value, str):
            score += 10
        description = self._get_attr_value(element, AS.kAXDescriptionAttribute)
        if isinstance(description, str) and "text" in description.lower():
            score += 5
        return score

    def _find_focus_candidate_in_subtree(self, root_element, diagnostics: dict[str, Any]) -> Any:
        max_nodes = 250
        queue_elements = [root_element]
        visited: set[str] = set()
        best_candidate = None
        best_score = -1
        scanned = 0
        top_candidates: list[dict[str, Any]] = []

        while queue_elements and scanned < max_nodes:
            current = queue_elements.pop(0)
            token = self._element_token(current)
            if token in visited:
                continue
            visited.add(token)
            scanned += 1

            score = self._candidate_score(current)
            if score > 0:
                candidate_summary = {
                    "score": score,
                    "role": self._get_attr_value(current, AS.kAXRoleAttribute),
                    "subrole": self._get_attr_value(current, AS.kAXSubroleAttribute),
                    "title": shorten_text(
                        self._get_attr_value(current, AS.kAXTitleAttribute), 80
                    ),
                    "description": shorten_text(
                        self._get_attr_value(current, AS.kAXDescriptionAttribute), 80
                    ),
                    "focused": self._get_attr_value(current, AS.kAXFocusedAttribute),
                    "bounds": self._resolve_bounds(current),
                }
                top_candidates.append(candidate_summary)
                top_candidates = sorted(
                    top_candidates, key=lambda item: item["score"], reverse=True
                )[:5]
                if score > best_score:
                    best_score = score
                    best_candidate = current

            for attr_name in (
                AS.kAXChildrenAttribute,
                getattr(AS, "kAXVisibleChildrenAttribute", None),
            ):
                if not attr_name:
                    continue
                children = self._get_attr_value(current, attr_name) or []
                if isinstance(children, (list, tuple)):
                    queue_elements.extend(children)

        diagnostics["subtree_probe"] = {
            "root_role": self._get_attr_value(root_element, AS.kAXRoleAttribute),
            "root_title": shorten_text(
                self._get_attr_value(root_element, AS.kAXTitleAttribute), 120
            ),
            "scanned_nodes": scanned,
            "max_nodes": max_nodes,
            "best_score": best_score,
            "top_candidates": top_candidates,
        }
        return best_candidate

    def _get_window_element(self, app_element) -> Any:
        if app_element is None:
            return None
        for attribute in (AS.kAXFocusedWindowAttribute, AS.kAXMainWindowAttribute):
            error, window = ax_copy_attribute(app_element, attribute)
            if error == AS.kAXErrorSuccess and window is not None:
                return window
        return None

    def _get_window_title(self, app_element) -> str | None:
        window = self._get_window_element(app_element)
        if window is None:
            return None
        title = self._get_attr_value(window, AS.kAXTitleAttribute)
        if isinstance(title, str) and title.strip():
            return title.strip()
        return None

    def _get_attr_value(self, element, attribute: str) -> Any:
        if element is None:
            return None
        error, value = ax_copy_attribute(element, attribute)
        if error != AS.kAXErrorSuccess:
            return None
        return value

    def _resolve_label(self, focused_element) -> Any:
        title = self._get_attr_value(focused_element, AS.kAXTitleAttribute)
        if isinstance(title, str) and title.strip():
            return title.strip()

        title_ui_element = self._get_attr_value(
            focused_element, AS.kAXTitleUIElementAttribute
        )
        if title_ui_element is None:
            return None
        linked_title = self._get_attr_value(title_ui_element, AS.kAXTitleAttribute)
        if isinstance(linked_title, str) and linked_title.strip():
            return linked_title.strip()
        linked_description = self._get_attr_value(
            title_ui_element, AS.kAXDescriptionAttribute
        )
        if isinstance(linked_description, str) and linked_description.strip():
            return linked_description.strip()
        return None

    def _resolve_bounds(self, focused_element) -> dict[str, float] | None:
        position = ax_value_to_point(
            self._get_attr_value(focused_element, AS.kAXPositionAttribute)
        )
        size = ax_value_to_size(self._get_attr_value(focused_element, AS.kAXSizeAttribute))
        if not position or not size:
            return None
        return {
            "x": position["x"],
            "y": position["y"],
            "width": size["width"],
            "height": size["height"],
        }

    def _describe_ax_node(
        self,
        element,
        *,
        is_focused: bool = False,
        full: bool = False,
    ) -> dict[str, Any]:
        value = self._get_attr_value(element, AS.kAXValueAttribute)
        value_limit = int(self.settings.get("nearby_ax_value_preview_chars", 120))
        return {
            "role": self._get_attr_value(element, AS.kAXRoleAttribute),
            "subrole": self._get_attr_value(element, AS.kAXSubroleAttribute),
            "title": self._get_attr_value(element, AS.kAXTitleAttribute)
            if full
            else shorten_text(self._get_attr_value(element, AS.kAXTitleAttribute)),
            "description": self._get_attr_value(element, AS.kAXDescriptionAttribute)
            if full
            else shorten_text(self._get_attr_value(element, AS.kAXDescriptionAttribute)),
            "label": self._resolve_label(element)
            if full
            else shorten_text(self._resolve_label(element)),
            "value": plain_data(value) if full else shorten_text(value, value_limit),
            "bounds": self._resolve_bounds(element),
            "is_focused": is_focused,
        }

    def _capture_focused_ax(self, focused_element) -> dict[str, Any]:
        if focused_element is None:
            return {"status": "not_found"}
        payload = self._describe_ax_node(focused_element, is_focused=True, full=True)
        payload["status"] = "ok"
        return payload

    def _detect_chrome_ax_empty(self, frontmost_app: Any, app_element) -> bool:
        if frontmost_app != "Google Chrome" or app_element is None:
            return False
        window = self._get_window_element(app_element)
        if window is None:
            return False
        children = self._get_attr_value(window, AS.kAXChildrenAttribute)
        return isinstance(children, (list, tuple)) and len(children) == 0

    def _capture_nearby_ax(self, focused_element, *, chrome_ax_empty: bool) -> dict[str, Any]:
        if chrome_ax_empty:
            return {"status": "empty", "reason": "chrome_ax_tree_empty"}
        if focused_element is None:
            return {"status": "not_found"}

        max_depth = int(self.settings.get("nearby_ax_ancestor_depth", 3))
        max_siblings = int(self.settings.get("nearby_ax_max_siblings", 12))
        focused_children = list(
            self._get_attr_value(focused_element, AS.kAXChildrenAttribute) or []
        )

        ancestors: list[dict[str, Any]] = []
        current = focused_element
        for depth in range(1, max_depth + 1):
            parent = self._get_attr_value(current, AS.kAXParentAttribute)
            if parent is None:
                break
            siblings = list(self._get_attr_value(parent, AS.kAXChildrenAttribute) or [])
            sibling_summaries = [
                self._describe_ax_node(child, is_focused=(child == focused_element))
                for child in siblings[:max_siblings]
            ]
            ancestors.append(
                {
                    "depth_from_focus": depth,
                    "node": self._describe_ax_node(parent),
                    "children": sibling_summaries,
                    "children_truncated": len(siblings) > max_siblings,
                }
            )
            current = parent

        return {
            "status": "ok",
            "focused": self._describe_ax_node(focused_element, is_focused=True),
            "ancestors": ancestors,
            "focused_children": [
                self._describe_ax_node(child) for child in focused_children[:max_siblings]
            ],
            "focused_children_truncated": len(focused_children) > max_siblings,
        }

    def _capture_caret(self, focused_element) -> dict[str, Any]:
        if not self.settings.get("caret_capture", True):
            return {"status": "skipped"}
        if focused_element is None:
            return {"status": "not_found"}
        try:
            selected_range_value = self._get_attr_value(
                focused_element, AS.kAXSelectedTextRangeAttribute
            )
            selected_range = ax_value_to_range(selected_range_value)
            if selected_range_value is not None and selected_range is not None:
                error, bounds_value = AS.AXUIElementCopyParameterizedAttributeValue(
                    focused_element,
                    AS.kAXBoundsForRangeParameterizedAttribute,
                    selected_range_value,
                    None,
                )
                payload = {"status": "ok", "range": selected_range}
                if error == AS.kAXErrorSuccess and bounds_value is not None:
                    payload["bounds"] = ax_value_to_rect(bounds_value)
                else:
                    payload["bounds"] = None
                    payload["bounds_status"] = ax_error_name(error)
                return payload

            line_number = self._get_attr_value(
                focused_element, AS.kAXInsertionPointLineNumberAttribute
            )
            if line_number is not None:
                return {"status": "line_only", "line_number": int(line_number)}
            return {"status": "unsupported"}
        except Exception as exc:
            return {"status": "error", "error": str(exc)}

    def _capture_geometry(self, frontmost_pid: Any, focused_element, app_element) -> dict[str, Any]:
        if not frontmost_pid or app_element is None:
            return {"status": "not_found"}
        try:
            window = self._get_window_element(app_element)
            if window is None:
                return {"status": "not_found"}
            window_position = ax_value_to_point(
                self._get_attr_value(window, AS.kAXPositionAttribute)
            )
            window_size = ax_value_to_size(self._get_attr_value(window, AS.kAXSizeAttribute))
            screen_payload = None
            display_scale = None
            window_center = None
            screens = list(AppKit.NSScreen.screens())
            primary_height = float(screens[0].frame().size.height) if screens else 0.0
            if window_position and window_size:
                window_center = (
                    window_position["x"] + (window_size["width"] / 2.0),
                    window_position["y"] + (window_size["height"] / 2.0),
                )
                for screen in screens:
                    frame = screen.frame()
                    ax_origin_x = float(frame.origin.x)
                    ax_origin_y = primary_height - (
                        float(frame.origin.y) + float(frame.size.height)
                    )
                    ax_max_x = ax_origin_x + float(frame.size.width)
                    ax_max_y = ax_origin_y + float(frame.size.height)
                    in_x = ax_origin_x <= window_center[0] <= ax_max_x
                    in_y = ax_origin_y <= window_center[1] <= ax_max_y
                    if in_x and in_y:
                        screen_payload = {
                            "x": ax_origin_x,
                            "y": ax_origin_y,
                            "width": float(frame.size.width),
                            "height": float(frame.size.height),
                            "cocoa_origin": {
                                "x": float(frame.origin.x),
                                "y": float(frame.origin.y),
                            },
                        }
                        display_scale = float(screen.backingScaleFactor())
                        break
            if display_scale is None:
                main_screen = AppKit.NSScreen.mainScreen()
                if main_screen is not None:
                    display_scale = float(main_screen.backingScaleFactor())

            window_bounds = None
            if window_position and window_size:
                window_bounds = {
                    "x": window_position["x"],
                    "y": window_position["y"],
                    "width": window_size["width"],
                    "height": window_size["height"],
                }

            return {
                "status": "ok",
                "coord_system": "ax_top_left",
                "window_bounds_points": window_bounds,
                "window_center_points": window_center,
                "display_scale": display_scale,
                "screen_frame_points": screen_payload,
                "focused_bounds_points": self._resolve_bounds(focused_element),
                "coord_notes": (
                    "AX coordinates are in display points with a top-left origin. "
                    "Multiply by display_scale to approximate PNG pixel coordinates."
                ),
            }
        except Exception as exc:
            return {"status": "error", "error": str(exc)}

    def _clipboard_token_to_mime(self, token: str) -> str | None:
        normalized = token.strip().strip('"').lower()
        mapping = {
            "utf8": "text/plain",
            "utxt": "text/plain",
            "string": "text/plain",
            "text": "text/plain",
            "pngf": "image/png",
            "tiff": "image/tiff",
            "jpeg": "image/jpeg",
            "jpgf": "image/jpeg",
            "pdf ": "application/pdf",
            "url ": "text/uri-list",
        }
        for key, value in mapping.items():
            if key in normalized:
                return value
        return None

    def _read_clipboard(self) -> dict[str, Any]:
        max_chars = int(self.settings.get("clipboard_max_chars", 8000))
        text_result = subprocess.run(
            ["/usr/bin/pbpaste"],
            capture_output=True,
            check=False,
        )
        raw_text = (
            text_result.stdout.decode("utf-8", errors="replace")
            if text_result.returncode == 0 and text_result.stdout
            else ""
        )
        text = raw_text
        truncated = False
        if len(text) > max_chars:
            text = text[:max_chars]
            truncated = True

        info_result = subprocess.run(
            ["/usr/bin/osascript", "-e", "clipboard info"],
            capture_output=True,
            text=True,
            check=False,
        )
        raw_info = (info_result.stdout or "").strip()
        mime_types: list[str] = []
        if raw_text:
            mime_types.append("text/plain")
        for match in re.findall(r"«class ([^»]+)»|\"([^\"]+)\"", raw_info):
            token = next((item for item in match if item), "")
            mime_type = self._clipboard_token_to_mime(token)
            if mime_type and mime_type not in mime_types:
                mime_types.append(mime_type)

        return {
            "text": text,
            "mime_types": mime_types,
            "length": len(raw_text),
            "truncated": truncated,
            "captured_at": now_iso(),
            "raw_clipboard_info": raw_info,
        }

    def _capture_ocr(self, image_path: Path) -> dict[str, Any]:
        if not self.settings.get("enable_ocr", True):
            return {"status": "skipped"}
        return recognize_text(
            image_path,
            uses_language_correction=bool(
                self.settings.get("ocr_language_correction", True)
            ),
        )

    def _write_fixture(
        self,
        *,
        fixture_dir: Path,
        source_state: dict[str, Any],
        target_capture: dict[str, Any],
        target_metadata: dict[str, Any],
        ax_focused: dict[str, Any],
        nearby_ax: dict[str, Any],
        chrome_ax_empty: bool,
        caret: dict[str, Any],
        geometry: dict[str, Any],
        clipboard: dict[str, Any],
        ocr: dict[str, Any],
    ) -> dict[str, Any]:
        source_path = fixture_dir / "source.png"
        target_path = fixture_dir / "target.png"
        shutil.copy2(SOURCE_IMAGE_PATH, source_path)
        shutil.copy2(PENDING_TARGET_PATH, target_path)

        source_request = prepare_request_image(source_path, self.settings)
        target_request = prepare_request_image(target_path, self.settings)

        capture_payload = {
            "source": source_state.get("capture"),
            "target": target_capture,
        }
        save_json_file(fixture_dir / "ax_focused.json", ax_focused)
        save_json_file(fixture_dir / "ax_nearby.json", nearby_ax)
        save_json_file(fixture_dir / "caret.json", caret)
        save_json_file(fixture_dir / "geometry.json", geometry)
        save_json_file(fixture_dir / "clipboard.json", clipboard)
        save_json_file(fixture_dir / "ocr.json", ocr)
        save_json_file(fixture_dir / "capture.json", capture_payload)

        full_metadata = target_metadata.get("_full", plain_data(target_metadata))
        manifest = {
            "schema_version": FIXTURE_SCHEMA_VERSION,
            "fixture_id": fixture_dir.name,
            "slug": fixture_dir.name.split("-", 3)[-1] if "-" in fixture_dir.name else fixture_dir.name,
            "created_at": now_iso(),
            "labels": [],
            "tags": [],
            "capture_settings": plain_data(self.settings),
            "source": {
                "captured_at": source_state.get("captured_at"),
                "image_path": source_path.name,
                "request_image_path": Path(source_request["log"]["request_path"]).name,
                "bytes": source_path.stat().st_size,
                "request_bytes": source_request["request_bytes"],
            },
            "target": {
                "captured_at": target_capture.get("finished_at"),
                "image_path": target_path.name,
                "request_image_path": Path(target_request["log"]["request_path"]).name,
                "bytes": target_path.stat().st_size,
                "request_bytes": target_request["request_bytes"],
            },
            "app": {
                "frontmost_app": full_metadata.get("frontmost_app"),
                "frontmost_window_title": full_metadata.get("frontmost_window_title"),
                "frontmost_pid": full_metadata.get("frontmost_pid"),
                "workspace_frontmost_app": full_metadata.get("workspace_frontmost_app"),
                "workspace_frontmost_window_title": full_metadata.get(
                    "workspace_frontmost_window_title"
                ),
                "workspace_frontmost_pid": full_metadata.get("workspace_frontmost_pid"),
                "focused_app": full_metadata.get("focused_app"),
                "focused_app_pid": full_metadata.get("focused_app_pid"),
                "focused_app_bundle_id": full_metadata.get("focused_app_bundle_id"),
            },
            "warnings": full_metadata.get("warnings", []),
            "target_metadata": full_metadata,
            "ax": {
                "chrome_ax_empty": chrome_ax_empty,
                "focused_path": "ax_focused.json",
                "nearby_path": "ax_nearby.json",
            },
            "caret": {"path": "caret.json"},
            "geometry": {"path": "geometry.json"},
            "clipboard": {"path": "clipboard.json"},
            "ocr": {"path": "ocr.json"},
            "capture": {"path": "capture.json"},
        }
        save_json_file(fixture_dir / "fixture.json", manifest)
        return manifest

    def _copy_to_clipboard(self, text: str) -> None:
        subprocess.run(
            ["/usr/bin/pbcopy"],
            input=text,
            text=True,
            check=True,
        )

    def _persist_run_artifacts(self, run_dir: Path, run_log: dict[str, Any], output_text: str) -> None:
        output_path = run_dir / "output.txt"
        output_path.write_text(output_text + ("\n" if output_text else ""), encoding="utf-8")
        LAST_OUTPUT_PATH.write_text(output_text + ("\n" if output_text else ""), encoding="utf-8")
        sanitized_log = plain_data(run_log)
        try:
            save_json_file(run_dir / "run.json", sanitized_log)
            save_json_file(LAST_RUN_PATH, sanitized_log)
        except Exception as exc:
            fallback_log = {
                "status": "persistence_error",
                "errors": [f"Failed to persist run log: {exc}"],
                "partial_run_log": sanitized_log,
            }
            save_json_file(run_dir / "run.json", fallback_log)
            save_json_file(LAST_RUN_PATH, fallback_log)


def main() -> int:
    load_workspace_env()
    if not os.environ.get("GEMINI_API_KEY"):
        print("Set GEMINI_API_KEY before running this script.", file=sys.stderr)
        return 1

    app = ScratchpadApp()

    def handle_signal(signum, frame) -> None:
        del signum, frame
        app.stop()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    try:
        app.start()
        app.wait()
    except KeyboardInterrupt:
        app.stop()
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        app.stop()
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
