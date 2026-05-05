from __future__ import annotations

import json
import os
import signal
import shutil
import subprocess
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import AppKit
import Foundation
import Quartz
from PyObjCTools import AppHelper

from scratchpad.gemini_runner import plain_data
from scratchpad.hotkey import HotkeyListener

from .capture import capture_active_window
from .gemini import (
    DEFAULT_SETTINGS,
    create_client,
    generate_tldr_and_suggestions,
    generate_via_proxy,
    proxy_settings_from_env,
)
from .overlay import show_result_panel


BASE_DIR = Path(__file__).resolve().parents[1]
PACKAGE_DIR = Path(__file__).resolve().parent
PROMPT_PATH = PACKAGE_DIR / "prompt.txt"
SETTINGS_PATH = PACKAGE_DIR / "settings.json"
RUNS_DIR = BASE_DIR / "tldr_runs"
HOTKEY = "ctrl+shift+t"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _run_dir_name() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")


def save_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(plain_data(payload), indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def load_settings() -> dict[str, Any]:
    settings = DEFAULT_SETTINGS.copy()
    if SETTINGS_PATH.exists():
        raw = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        for key in settings:
            if key in raw:
                settings[key] = raw[key]
    return settings


def _display_scale_from_capture(capture: dict[str, Any]) -> Any:
    for key in ("display_scale", "backing_scale_factor", "scale"):
        if capture.get(key) is not None:
            return capture.get(key)
    bbox = capture.get("bbox")
    if isinstance(bbox, dict):
        for key in ("display_scale", "backing_scale_factor", "scale"):
            if bbox.get(key) is not None:
                return bbox.get(key)
    return None


def save_tldr_fixture(
    *,
    fixture_dir: Path,
    screenshot_path: Path,
    capture: dict[str, Any],
    hotkey_at: str,
) -> dict[str, Any]:
    fixture_dir.mkdir(parents=True, exist_ok=True)
    slug = fixture_dir.name
    fixture_screenshot_path = fixture_dir / "screenshot.png"
    shutil.copy2(screenshot_path, fixture_screenshot_path)
    manifest = {
        "slug": slug,
        "label": slug.replace("-", " ").replace("_", " "),
        "captured_at": now_iso(),
        "notes": "",
        "screenshot": "screenshot.png",
        "display_scale": _display_scale_from_capture(capture),
        "capture": capture,
        "hotkey_at": hotkey_at,
    }
    save_json(fixture_dir / "tldr_fixture.json", manifest)
    return manifest


class TldrReplyApp:
    def __init__(self, *, save_fixture_dir: Path | None = None) -> None:
        self.settings = load_settings()
        self.prompt_text = PROMPT_PATH.read_text(encoding="utf-8")
        self.save_fixture_dir = save_fixture_dir
        self.proxy_settings = None if save_fixture_dir is not None else proxy_settings_from_env()
        self.client = None
        if self.proxy_settings is None and self.save_fixture_dir is None:
            self.client = create_client(os.environ.get("GEMINI_API_KEY"), self.settings)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tldr-reply")
        self.listener = HotkeyListener()
        self.listener.register(HOTKEY, self._on_hotkey)
        self.listener.register("1", lambda: self._on_choice_hotkey(0))
        self.listener.register("2", lambda: self._on_choice_hotkey(1))
        self.listener.register("3", lambda: self._on_choice_hotkey(2))
        self.listener.register("return", self._on_enter_hotkey)
        self.listener.register("enter", self._on_enter_hotkey)
        self.listener.register("escape", self._on_escape_hotkey)
        self._lock = threading.Lock()
        self._active_future: Future[None] | None = None
        self._panel = None
        self._panel_open = False
        self._current_meta: dict[str, Any] | None = None
        self._current_meta_path: Path | None = None
        self._current_suggestions: list[str] = []
        self._expanded_choice_index: int | None = None
        self._previous_app: Any = None
        self._signal_timer = None

    def run(self) -> None:
        app = AppKit.NSApplication.sharedApplication()
        # Regular activation policy (matches ui_lab) avoids the AppKit glass
        # outline that the accessory + non-activating-panel context renders
        # around NSGlassEffectView/NSGlassEffectContainerView. Tradeoff: the
        # panel now steals focus from the target app and Blink shows in the
        # dock for the lifetime of the runner.
        app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)
        AppHelper.installMachInterrupt()
        self._signal_timer = (
            Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
                0.25,
                True,
                lambda timer: None,
            )
        )
        RUNS_DIR.mkdir(parents=True, exist_ok=True)
        self.listener.start()
        if self.save_fixture_dir is None:
            print(f"[tldr] Listening for {HOTKEY}. Press ctrl+c here to quit.")
        else:
            print(
                f"[tldr] Listening for {HOTKEY}. Next capture saves fixture to "
                f"{self.save_fixture_dir} without sending."
            )
        app.run()

    def stop(self) -> None:
        if self._signal_timer is not None:
            self._signal_timer.invalidate()
            self._signal_timer = None
        self.listener.stop()
        self.executor.shutdown(wait=False, cancel_futures=True)
        AppKit.NSApp.stop_(None)
        AppKit.NSApp.terminate_(None)

    def _handle_signal(self, signum: int, frame: Any) -> None:
        print(f"[tldr] Received signal {signum}; stopping.")
        self.stop()

    def _on_hotkey(self) -> bool:
        with self._lock:
            if self._active_future is not None and not self._active_future.done():
                print("[tldr] Still working on the previous request; ignoring hotkey.")
                return True
            if self._panel_open:
                print("[tldr] A suggestions panel is already open; ignoring hotkey.")
                return True
            hotkey_at = now_iso()
            print("[tldr] Hotkey detected; choose a window to summarize.")
            self._active_future = self.executor.submit(self._run_once, hotkey_at)
        return True

    def _on_choice_hotkey(self, index: int) -> bool:
        with self._lock:
            if not self._panel_open:
                return False
            if index >= len(self._current_suggestions):
                return True
            if self._expanded_choice_index != index:
                self._expanded_choice_index = index
                panel = self._panel
                if panel is not None:
                    self._dispatch_main(lambda: panel.expand_suggestion(index))
                return True
            text = self._current_suggestions[index]
            self._panel_open = False
            self._expanded_choice_index = None
        self._dispatch_main(lambda: self._finish_choice(index, text))
        return True

    def _on_enter_hotkey(self) -> bool:
        with self._lock:
            if not self._panel_open:
                return False
            index = self._expanded_choice_index
            if index is None:
                # No option highlighted yet — let Enter propagate so the
                # underlying app sees a normal Return keystroke.
                return False
            if index >= len(self._current_suggestions):
                return True
            text = self._current_suggestions[index]
            self._panel_open = False
            self._expanded_choice_index = None
        self._dispatch_main(lambda: self._finish_insert(index, text))
        return True

    def _on_escape_hotkey(self) -> bool:
        with self._lock:
            if not self._panel_open:
                return False
            self._panel_open = False
            self._expanded_choice_index = None
        self._dispatch_main(self._finish_dismiss)
        return True

    def _dispatch_main(self, callback: Any) -> None:
        def run_callback() -> None:
            callback()
            return None

        self._main_queue().addOperationWithBlock_(run_callback)

    def _main_queue(self) -> Any:
        return Foundation.NSOperationQueue.mainQueue()

    def _notify(self, message: str) -> None:
        safe_message = message.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                (
                    f'display notification "{safe_message}" '
                    'with title "Blink TLDR" sound name ""'
                ),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def _close_panel(self) -> None:
        panel = self._panel
        if panel is not None:
            panel.close()
        self._panel = None
        self._restore_previous_app()

    def _restore_previous_app(self) -> None:
        previous_app = self._previous_app
        self._previous_app = None
        if previous_app is None:
            return
        if previous_app.isTerminated():
            return
        own_pid = AppKit.NSRunningApplication.currentApplication().processIdentifier()
        if previous_app.processIdentifier() == own_pid:
            return
        previous_app.activateWithOptions_(
            AppKit.NSApplicationActivateIgnoringOtherApps
        )

    def _finish_choice(self, index: int, text: str) -> None:
        self._close_panel()
        subprocess.run(
            ["/usr/bin/pbcopy"],
            input=text,
            text=True,
            check=True,
        )
        meta = self._current_meta
        meta_path = self._current_meta_path
        if meta is not None and meta_path is not None:
            meta["chosen_index"] = index + 1
            meta["chosen_text"] = text
            meta["chosen_at"] = now_iso()
            save_json(meta_path, meta)
        with self._lock:
            self._current_meta = None
            self._current_meta_path = None
            self._current_suggestions = []
            self._expanded_choice_index = None
        print(f"[tldr] Copied suggestion {index + 1} to clipboard.")

    def _finish_insert(self, index: int, text: str) -> None:
        # Same copy/close/log path as a regular choice, then synthesize Cmd+V
        # into whatever app the panel restored focus to. The 150ms delay
        # gives `_restore_previous_app`'s async activateWithOptions_: time
        # to land before the keystroke is posted.
        self._finish_choice(index, text)
        Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            0.15,
            False,
            lambda _timer: self._synthesize_cmd_v(),
        )

    def _synthesize_cmd_v(self) -> None:
        source = Quartz.CGEventSourceCreate(
            Quartz.kCGEventSourceStateCombinedSessionState
        )
        if source is None:
            print("[tldr] CGEventSource creation failed; paste skipped.")
            return
        v_keycode = 9  # kVK_ANSI_V
        down = Quartz.CGEventCreateKeyboardEvent(source, v_keycode, True)
        up = Quartz.CGEventCreateKeyboardEvent(source, v_keycode, False)
        if down is None or up is None:
            print("[tldr] CGEventCreateKeyboardEvent failed; paste skipped.")
            return
        Quartz.CGEventSetFlags(down, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventSetFlags(up, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, down)
        Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, up)

    def _finish_dismiss(self) -> None:
        self._close_panel()
        meta = self._current_meta
        meta_path = self._current_meta_path
        if meta is not None and meta_path is not None:
            meta["dismissed_at"] = now_iso()
            save_json(meta_path, meta)
        with self._lock:
            self._current_meta = None
            self._current_meta_path = None
            self._current_suggestions = []
            self._expanded_choice_index = None
        print("[tldr] Dismissed without changing clipboard.")

    def _run_once(self, hotkey_at: str) -> None:
        if self.save_fixture_dir is not None:
            fixture_dir = self.save_fixture_dir
            temp_screenshot_path = fixture_dir / ".capture.tmp.png"
            capture = capture_active_window(temp_screenshot_path)
            if capture["status"] != "ok":
                print(f"[tldr] Capture {capture['status']}; no fixture saved.")
                return
            save_tldr_fixture(
                fixture_dir=fixture_dir,
                screenshot_path=temp_screenshot_path,
                capture=capture,
                hotkey_at=hotkey_at,
            )
            temp_screenshot_path.unlink(missing_ok=True)
            print(f"[tldr] Fixture saved to {fixture_dir}; no request sent.")
            self._notify("TLDR fixture saved. No request sent.")
            return

        run_dir = RUNS_DIR / _run_dir_name()
        run_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = run_dir / "screenshot.png"
        meta_path = run_dir / "meta.json"
        response_path = run_dir / "response.json"

        meta: dict[str, Any] = {
            "hotkey_at": hotkey_at,
            "run_dir": str(run_dir),
            "model": None if self.proxy_settings else self.settings["model"],
            "settings": self.settings,
            "proxy_url": None if self.proxy_settings is None else self.proxy_settings["url"],
            "chosen_index": None,
            "chosen_text": None,
            "dismissed_at": None,
        }
        save_json(meta_path, meta)

        capture = capture_active_window(screenshot_path)
        meta["capture"] = capture
        meta["capture_ms"] = capture.get("duration_ms")
        save_json(meta_path, meta)
        if capture["status"] != "ok":
            print(f"[tldr] Capture {capture['status']}; no request sent.")
            return

        self._notify("Screenshot captured. Summarizing...")

        try:
            if self.proxy_settings is None:
                response = generate_tldr_and_suggestions(
                    self.client,
                    self.settings,
                    self.prompt_text,
                    screenshot_path,
                )
            else:
                response = generate_via_proxy(
                    self.settings,
                    screenshot_path,
                    self.proxy_settings,
                )
        except Exception as exc:
            response = {
                "status": "error",
                "tldr": "Gemini request failed.",
                "suggestions": [str(exc)],
                "raw": str(exc),
                "usage": None,
                "duration_ms": None,
                "model": None,
            }
        if response.get("model"):
            meta["model"] = response["model"]
        meta["gemini_ms"] = response.get("duration_ms")
        save_json(response_path, response)
        save_json(meta_path, meta)

        print(
            f"[tldr] Response ready ({response.get('status')}); showing suggestions."
        )
        suggestions = [str(item) for item in response.get("suggestions", [])]
        with self._lock:
            self._panel_open = True
            self._current_meta = meta
            self._current_meta_path = meta_path
            self._current_suggestions = suggestions
            self._expanded_choice_index = None

        def show() -> None:
            # Capture frontmost before show_result_panel calls
            # NSApp.activateIgnoringOtherApps_; that's the app the user was in
            # when picking the screenshot target, and the one to restore focus
            # to once the panel closes.
            self._previous_app = (
                AppKit.NSWorkspace.sharedWorkspace().frontmostApplication()
            )
            self._panel = show_result_panel(
                str(response.get("tldr") or ""),
                suggestions,
            )

        self._dispatch_main(show)
