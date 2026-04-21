#!/usr/bin/env python3

from __future__ import annotations

import json
import mimetypes
import os
import queue
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

from hotkey import HotkeyListener


PROMPT_PATH = BASE_DIR / "prompt.txt"
SETTINGS_PATH = BASE_DIR / "settings.json"
LAST_OUTPUT_PATH = BASE_DIR / "last_output.txt"
LAST_RUN_PATH = BASE_DIR / "last_run.json"
STATE_DIR = BASE_DIR / "state"
SOURCE_IMAGE_PATH = STATE_DIR / "current_source.png"
SOURCE_STATE_PATH = STATE_DIR / "current_source.json"

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
    "hotkeys": {
        "set_source": "ctrl+shift+c",
        "run_target": "ctrl+shift+v",
        "reset_source": "ctrl+option+r",
        "quit": "ctrl+option+q",
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


@dataclass
class QueuedAction:
    name: str
    hotkey_detected_perf: float
    hotkey_detected_at: str


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def duration_ms(start_perf: float, end_perf: float | None = None) -> float:
    final = end_perf if end_perf is not None else time.perf_counter()
    return round((final - start_perf) * 1000, 2)


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


def guess_mime_type(path: Path) -> str:
    mime_type, _ = mimetypes.guess_type(path.name)
    if mime_type and mime_type.startswith("image/"):
        return mime_type
    return "image/png"


def ax_error_name(code: int) -> str:
    return AX_ERROR_NAMES.get(code, f"ax_error_{code}")


def plain_data(value: Any) -> Any:
    if value is None:
        return None
    if hasattr(value, "model_dump"):
        return value.model_dump(exclude_none=True)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(key): plain_data(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain_data(item) for item in value]
    if isinstance(value, (str, int, float, bool)):
        return value
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            break
    else:
        return str(value)

    payload: dict[str, Any] = {}
    for attr in ("x", "y", "width", "height"):
        if hasattr(value, attr):
            payload[attr] = float(getattr(value, attr))
    return payload


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
    if value is None:
        return None
    if AS.AXValueGetType(value) != AS.kAXValueCGPointType:
        return None
    ok, point = AS.AXValueGetValue(value, AS.kAXValueCGPointType, None)
    if not ok:
        return None
    return {"x": float(point.x), "y": float(point.y)}


def ax_value_to_size(value: Any) -> dict[str, float] | None:
    if value is None:
        return None
    if AS.AXValueGetType(value) != AS.kAXValueCGSizeType:
        return None
    ok, size = AS.AXValueGetValue(value, AS.kAXValueCGSizeType, None)
    if not ok:
        return None
    return {"width": float(size.width), "height": float(size.height)}


class ScratchpadApp:
    def __init__(self) -> None:
        self.settings = load_settings()
        self.prompt_text = read_prompt()
        self.log_dir = BASE_DIR / self.settings["log_dir"]
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
        self._print_banner()
        self.worker_thread.start()
        self.listener.start()

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
        self.listener.register(
            self.settings["hotkeys"]["set_source"],
            lambda: self.enqueue_action("set_source"),
        )
        self.listener.register(
            self.settings["hotkeys"]["run_target"],
            lambda: self.enqueue_action("run_target"),
        )
        self.listener.register(
            self.settings["hotkeys"]["reset_source"],
            lambda: self.enqueue_action("reset_source"),
        )
        self.listener.register(
            self.settings["hotkeys"]["quit"],
            self.request_quit,
        )

    def _ensure_layout(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def _print_banner(self) -> None:
        source_state = self._load_source_state()
        source_status = "loaded" if source_state else "not set"
        print("Blink scratchpad is running.")
        print(f"- source: {source_status}")
        print(f"- set source: {self.settings['hotkeys']['set_source']}")
        print(f"- run target: {self.settings['hotkeys']['run_target']}")
        print(f"- reset source: {self.settings['hotkeys']['reset_source']}")
        print(f"- quit: {self.settings['hotkeys']['quit']}")
        print("- logs:", self.log_dir)
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

    def _handle_set_source(self, action: QueuedAction) -> None:
        print(self._capture_instruction("source", "reusable source context"))
        pending_path = STATE_DIR / "pending_source.png"
        capture = self._capture_screenshot(pending_path)
        if capture["status"] != "ok":
            detail = capture.get("stderr") or capture.get("stdout") or "no details"
            print(f"[source] Capture {capture['status']}: {detail}")
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
        print(f"[source] Saved source snapshot ({source_state['bytes']} bytes).")

    def _handle_reset_source(self, action: QueuedAction) -> None:
        if SOURCE_IMAGE_PATH.exists():
            SOURCE_IMAGE_PATH.unlink()
        if SOURCE_STATE_PATH.exists():
            SOURCE_STATE_PATH.unlink()
        print("[source] Source state cleared.")

    def _handle_run_target(self, action: QueuedAction) -> None:
        run_dir = self._make_run_dir()
        run_log = {
            "run_id": run_dir.name,
            "status": "started",
            "settings": self.settings,
            "prompt_path": str(PROMPT_PATH),
            "hotkey_detected_at": action.hotkey_detected_at,
            "timings": {},
            "errors": [],
        }

        source_state = self._load_source_state()
        if not source_state or not SOURCE_IMAGE_PATH.exists():
            run_log["status"] = "missing_source"
            run_log["errors"].append("No source capture is set. Use the set-source hotkey first.")
            self._persist_run_artifacts(run_dir, run_log, "")
            print("[target] No source snapshot set. Press the set-source hotkey first.")
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
        target_metadata = self._capture_target_metadata()
        metadata_finished_perf = time.perf_counter()
        run_log["target_metadata"] = target_metadata
        run_log["timings"]["target_metadata_started_at"] = metadata_started_at
        run_log["timings"]["target_metadata_finished_at"] = now_iso()
        run_log["timings"]["target_metadata_ms"] = duration_ms(
            metadata_started_perf, metadata_finished_perf
        )
        run_log["timings"]["queue_delay_ms"] = duration_ms(
            action.hotkey_detected_perf, metadata_started_perf
        )

        target_path = run_dir / "target.png"
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
            print(f"[target] Capture {capture['status']}: {detail}")
            return

        generation = self._generate_completion(
            action=action,
            source_path=source_copy_path,
            target_path=target_path,
            target_metadata=target_metadata,
        )
        run_log.update(generation["run_log"])
        output_text = generation["output_text"]
        self._persist_run_artifacts(run_dir, run_log, output_text)

        if run_log["status"] == "ok":
            print("")
            print(
                f"[target] end_to_end={run_log['timings']['end_to_end_ms']}ms "
                f"ttft={run_log['timings'].get('ttft_ms')}ms "
                f"model={run_log['timings'].get('model_latency_ms')}ms "
                f"output_tps={run_log['response'].get('output_tps')}"
            )
            print(f"[target] Log saved to {run_dir / 'run.json'}")
        else:
            print(f"[target] Generation failed: {run_log['errors'][-1]}")

    def _make_run_dir(self) -> Path:
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
        run_dir = self.log_dir / timestamp
        run_dir.mkdir(parents=True, exist_ok=False)
        return run_dir

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
            final_attempt["fallback_used"] = final_attempt["effective_capture_mode"] != requested_mode
            final_attempt["fallback_reason"] = "window_capture_failed"
        else:
            final_attempt["fallback_used"] = False
        return final_attempt

    def _capture_target_metadata(self) -> dict[str, Any]:
        metadata: dict[str, Any] = {
            "status": "ok",
            "frontmost_app": None,
            "frontmost_window_title": None,
            "focused_role": None,
            "focused_subrole": None,
            "focused_title": None,
            "focused_description": None,
            "focused_label": None,
            "focused_value_preview": None,
            "focused_bounds": None,
            "permission": {
                "accessibility_trusted": bool(AS.AXIsProcessTrusted()),
            },
        }

        frontmost = AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
        if frontmost is not None:
            metadata["frontmost_app"] = frontmost.localizedName()
            metadata["frontmost_pid"] = int(frontmost.processIdentifier())

        if not metadata["permission"]["accessibility_trusted"]:
            metadata["status"] = "permission_denied"
            metadata["error"] = "Accessibility access is not granted."
            return metadata

        system_wide = AS.AXUIElementCreateSystemWide()
        focused_error, focused_element = ax_copy_attribute(
            system_wide, AS.kAXFocusedUIElementAttribute
        )
        if focused_error != AS.kAXErrorSuccess or focused_element is None:
            metadata["status"] = "not_found"
            metadata["error"] = ax_error_name(focused_error)
            return metadata

        if metadata.get("frontmost_pid"):
            app_element = AS.AXUIElementCreateApplication(metadata["frontmost_pid"])
            window_title = self._get_window_title(app_element)
            if window_title:
                metadata["frontmost_window_title"] = window_title

        metadata["focused_role"] = shorten_text(
            self._get_attr_value(focused_element, AS.kAXRoleAttribute)
        )
        metadata["focused_subrole"] = shorten_text(
            self._get_attr_value(focused_element, AS.kAXSubroleAttribute)
        )
        metadata["focused_title"] = shorten_text(
            self._get_attr_value(focused_element, AS.kAXTitleAttribute)
        )
        metadata["focused_description"] = shorten_text(
            self._get_attr_value(focused_element, AS.kAXDescriptionAttribute)
        )
        metadata["focused_value_preview"] = shorten_text(
            self._get_attr_value(focused_element, AS.kAXValueAttribute)
        )
        metadata["focused_label"] = shorten_text(self._resolve_label(focused_element))
        metadata["focused_bounds"] = self._resolve_bounds(focused_element)
        return metadata

    def _get_window_title(self, app_element) -> str | None:
        for attribute in (AS.kAXFocusedWindowAttribute, AS.kAXMainWindowAttribute):
            error, window = ax_copy_attribute(app_element, attribute)
            if error != AS.kAXErrorSuccess or window is None:
                continue
            title = self._get_attr_value(window, AS.kAXTitleAttribute)
            if isinstance(title, str) and title.strip():
                return title.strip()
        return None

    def _get_attr_value(self, element, attribute: str) -> Any:
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
        size = ax_value_to_size(
            self._get_attr_value(focused_element, AS.kAXSizeAttribute)
        )
        if not position or not size:
            return None
        return {
            "x": position["x"],
            "y": position["y"],
            "width": size["width"],
            "height": size["height"],
        }

    def _build_user_parts(
        self,
        source_path: Path,
        target_path: Path,
        target_metadata: dict[str, Any],
    ) -> tuple[list[Any], dict[str, Any]]:
        prepare_started_perf = time.perf_counter()

        metadata_json = json.dumps(target_metadata, indent=2, ensure_ascii=True)
        instruction_text = (
            "TARGET_METADATA_JSON:\n"
            f"{metadata_json}\n\n"
            "Use the source image as the source context and the target image as the destination context."
        )

        source_request_image = self._prepare_request_image(source_path)
        target_request_image = self._prepare_request_image(target_path)

        parts = [
            types.Part.from_text(text=instruction_text),
            types.Part.from_text(text="SOURCE_IMAGE"),
            types.Part.from_bytes(
                data=source_request_image["bytes_data"],
                mime_type=source_request_image["mime_type"],
            ),
            types.Part.from_text(text="TARGET_IMAGE"),
            types.Part.from_bytes(
                data=target_request_image["bytes_data"],
                mime_type=target_request_image["mime_type"],
            ),
        ]

        timings = {
            "request_build_ms": duration_ms(prepare_started_perf),
            "source_image_prepare_ms": source_request_image["duration_ms"],
            "target_image_prepare_ms": target_request_image["duration_ms"],
        }
        inputs = {
            "instruction_chars": len(instruction_text),
            "source_image_bytes": source_request_image["request_bytes"],
            "target_image_bytes": target_request_image["request_bytes"],
            "source_original_image_bytes": source_request_image["original_bytes"],
            "target_original_image_bytes": target_request_image["original_bytes"],
        }
        images = {
            "source": source_request_image["log"],
            "target": target_request_image["log"],
        }
        return parts, {"timings": timings, "inputs": inputs, "images": images}

    def _prepare_request_image(self, image_path: Path) -> dict[str, Any]:
        original_bytes = image_path.stat().st_size
        preprocess_enabled = bool(self.settings.get("preprocess_request_images", True))
        started_perf = time.perf_counter()
        started_at = now_iso()

        if not preprocess_enabled:
            data = image_path.read_bytes()
            finished_at = now_iso()
            return {
                "bytes_data": data,
                "mime_type": guess_mime_type(image_path),
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
                    "request_mime_type": guess_mime_type(image_path),
                },
            }

        request_format = str(self.settings.get("request_image_format", "jpeg")).lower()
        max_dimension = int(self.settings.get("request_image_max_dimension", 1600))
        jpeg_quality = int(self.settings.get("request_image_jpeg_quality", 80))
        extension = ".jpg" if request_format in {"jpeg", "jpg"} else f".{request_format}"
        request_path = image_path.with_name(f"{image_path.stem}.request{extension}")
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
            return {
                "bytes_data": data,
                "mime_type": guess_mime_type(request_path),
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
                    "request_mime_type": guess_mime_type(request_path),
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
        return {
            "bytes_data": data,
            "mime_type": guess_mime_type(image_path),
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
                "request_mime_type": guess_mime_type(image_path),
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

    def _build_generation_config(self) -> Any:
        thinking_level = str(self.settings.get("thinking_level", "MINIMAL")).upper()
        thinking_fields = getattr(types.ThinkingConfig, "model_fields", {})
        thinking_kwargs: dict[str, Any] = {"include_thoughts": False}
        if "thinking_level" in thinking_fields:
            thinking_kwargs["thinking_level"] = thinking_level
        elif thinking_level == "MINIMAL":
            thinking_kwargs["thinking_budget"] = 0
        thinking_config = types.ThinkingConfig(**thinking_kwargs)

        return types.GenerateContentConfig(
            system_instruction=self.prompt_text,
            temperature=self.settings["temperature"],
            max_output_tokens=self.settings["max_output_tokens"],
            response_mime_type="text/plain",
            media_resolution=self.settings["media_resolution"],
            thinking_config=thinking_config,
        )

    def _generate_completion(
        self,
        *,
        action: QueuedAction,
        source_path: Path,
        target_path: Path,
        target_metadata: dict[str, Any],
    ) -> dict[str, Any]:
        output_chunks: list[str] = []
        first_chunk_perf: float | None = None
        final_chunk_perf: float | None = None
        first_chunk_at: str | None = None
        final_chunk_at: str | None = None
        usage_metadata: Any = None
        final_chunk_payload: Any = None

        parts, prep = self._build_user_parts(source_path, target_path, target_metadata)
        contents = [types.Content(role="user", parts=parts)]
        config = self._build_generation_config()

        request_send_perf = time.perf_counter()
        request_send_at = now_iso()
        status = "ok"
        error_message = None
        chunk_count = 0

        try:
            stream = self.client.models.generate_content_stream(
                model=self.settings["model"],
                contents=contents,
                config=config,
            )
            for chunk in stream:
                chunk_count += 1
                chunk_perf = time.perf_counter()
                if first_chunk_perf is None:
                    first_chunk_perf = chunk_perf
                    first_chunk_at = now_iso()
                final_chunk_perf = chunk_perf
                final_chunk_at = now_iso()
                if getattr(chunk, "text", None):
                    text = chunk.text
                    output_chunks.append(text)
                    if self.settings.get("stream_to_terminal", True):
                        print(text, end="", flush=True)
                if getattr(chunk, "usage_metadata", None) is not None:
                    usage_metadata = plain_data(chunk.usage_metadata)
                final_chunk_payload = plain_data(chunk)
        except Exception as exc:
            status = "error"
            error_message = str(exc)

        finished_perf = time.perf_counter()
        if final_chunk_perf is None:
            final_chunk_perf = finished_perf

        output_text = "".join(output_chunks).strip()
        clipboard = {
            "copied": False,
            "started_at": None,
            "finished_at": None,
            "duration_ms": None,
        }
        if status == "ok" and self.settings.get("copy_to_clipboard", True):
            clipboard_started_perf = time.perf_counter()
            clipboard["started_at"] = now_iso()
            self._copy_to_clipboard(output_text)
            clipboard["finished_at"] = now_iso()
            clipboard["duration_ms"] = duration_ms(clipboard_started_perf)
            clipboard["copied"] = True

        clipboard_ready_perf = time.perf_counter()
        clipboard_ready_at = now_iso()
        candidates_token_count = self._extract_usage_number(
            usage_metadata, "candidates_token_count", "candidatesTokenCount"
        )
        stream_duration_ms = None
        output_tps = None
        if first_chunk_perf is not None and final_chunk_perf is not None:
            stream_duration_ms = duration_ms(first_chunk_perf, final_chunk_perf)
            if candidates_token_count and stream_duration_ms and stream_duration_ms > 0:
                output_tps = round(
                    float(candidates_token_count) / (stream_duration_ms / 1000.0), 2
                )

        run_log = {
            "status": status,
            "request": {
                "model": self.settings["model"],
                "request_send_at": request_send_at,
                "prompt_chars": len(self.prompt_text),
                **prep["inputs"],
                "images": prep["images"],
            },
            "response": {
                "usage_metadata": usage_metadata,
                "chunk_count": chunk_count,
                "response_metadata": final_chunk_payload,
                "output_tps": output_tps,
                "output_text": output_text,
                "output_text_length": len(output_text),
            },
            "clipboard": clipboard,
            "timings": {
                **prep["timings"],
                "request_send_at": request_send_at,
                "first_chunk_at": first_chunk_at,
                "final_chunk_at": final_chunk_at,
                "clipboard_ready_at": clipboard_ready_at,
                "ttft_ms": duration_ms(request_send_perf, first_chunk_perf)
                if first_chunk_perf is not None
                else None,
                "stream_duration_ms": stream_duration_ms,
                "model_latency_ms": duration_ms(request_send_perf, final_chunk_perf),
                "end_to_end_ms": duration_ms(action.hotkey_detected_perf, clipboard_ready_perf),
            },
        }
        if error_message:
            run_log["errors"] = [error_message]
        return {"run_log": run_log, "output_text": output_text}

    def _extract_usage_number(self, payload: Any, *keys: str) -> Any:
        if not isinstance(payload, dict):
            return None
        for key in keys:
            if key in payload:
                return payload[key]
        return None

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
    if not os.environ.get("GEMINI_API_KEY"):
        print("Set GEMINI_API_KEY before running this script.", file=sys.stderr)
        return 1

    app = ScratchpadApp()

    def handle_signal(signum, frame) -> None:
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
