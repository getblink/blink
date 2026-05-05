"""Focused tests for TLDR runner event dispatch."""

from __future__ import annotations

import sys
import threading
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRATCHPAD_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRATCHPAD_DIR.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scratchpad.tldr_reply.runner import TldrReplyApp, save_tldr_fixture  # noqa: E402


def _make_app(panel: object | None, suggestions: list[str]) -> TldrReplyApp:
    app = object.__new__(TldrReplyApp)
    app._lock = threading.Lock()
    app._panel = panel
    app._panel_open = True
    app._current_suggestions = suggestions
    app._expanded_choice_index = None
    app._dispatched: list = []
    app._dispatch_main = lambda cb: app._dispatched.append(cb)  # type: ignore[attr-defined]
    return app


class DispatchMainTests(unittest.TestCase):
    def test_dispatch_main_wraps_non_none_callback_return(self) -> None:
        queued_blocks = []

        class FakeQueue:
            def addOperationWithBlock_(self, block):
                queued_blocks.append(block)

        app = object.__new__(TldrReplyApp)
        app._main_queue = lambda: FakeQueue()
        callback = mock.Mock(return_value=True)
        app._dispatch_main(callback)

        self.assertEqual(len(queued_blocks), 1)
        self.assertIsNone(queued_blocks[0]())
        callback.assert_called_once_with()


class ChoiceHotkeyTests(unittest.TestCase):
    def test_first_press_expands_second_press_copies(self) -> None:
        panel = mock.Mock(spec=["expand_suggestion"])
        app = _make_app(panel, ["a reply"])

        first = app._on_choice_hotkey(0)
        self.assertTrue(first)
        self.assertTrue(app._panel_open)
        self.assertEqual(app._expanded_choice_index, 0)
        # First press should dispatch a panel.expand_suggestion call.
        self.assertEqual(len(app._dispatched), 1)
        app._dispatched[0]()
        panel.expand_suggestion.assert_called_once_with(0)

        second = app._on_choice_hotkey(0)
        self.assertTrue(second)
        self.assertFalse(app._panel_open)
        # Second press should have dispatched a finish_choice callback.
        self.assertEqual(len(app._dispatched), 2)


class EnterHotkeyTests(unittest.TestCase):
    def test_enter_with_no_selection_passes_through(self) -> None:
        app = _make_app(mock.Mock(), ["a", "b"])

        result = app._on_enter_hotkey()

        self.assertFalse(result)
        self.assertTrue(app._panel_open)
        self.assertEqual(len(app._dispatched), 0)

    def test_enter_with_selection_inserts(self) -> None:
        app = _make_app(mock.Mock(), ["first", "second"])
        app._expanded_choice_index = 1
        app._finish_insert = mock.Mock()  # type: ignore[method-assign]
        app._finish_choice = mock.Mock()  # type: ignore[method-assign]

        result = app._on_enter_hotkey()

        self.assertTrue(result)
        self.assertFalse(app._panel_open)
        self.assertIsNone(app._expanded_choice_index)
        self.assertEqual(len(app._dispatched), 1)

        # The dispatched callback should call _finish_insert (paste path),
        # not _finish_choice (clipboard-only).
        app._dispatched[0]()
        app._finish_insert.assert_called_once_with(1, "second")
        app._finish_choice.assert_not_called()

    def test_enter_without_panel_open_passes_event_through(self) -> None:
        app = _make_app(None, [])
        app._panel_open = False

        result = app._on_enter_hotkey()

        self.assertFalse(result)
        self.assertEqual(len(app._dispatched), 0)


class FixtureCaptureTests(unittest.TestCase):
    def test_save_tldr_fixture_writes_manifest_and_screenshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            screenshot = root / "capture.png"
            screenshot.write_bytes(b"png-bytes")
            fixture_dir = root / "fixtures" / "slack-thread"

            manifest = save_tldr_fixture(
                fixture_dir=fixture_dir,
                screenshot_path=screenshot,
                capture={"status": "ok", "duration_ms": 12},
                hotkey_at="2026-05-04T12:00:00.000+00:00",
            )

            self.assertEqual((fixture_dir / "screenshot.png").read_bytes(), b"png-bytes")
            self.assertEqual(manifest["slug"], "slack-thread")
            self.assertEqual(manifest["screenshot"], "screenshot.png")
            self.assertIsNone(manifest["display_scale"])
            self.assertEqual(manifest["capture"]["status"], "ok")
            self.assertTrue((fixture_dir / "tldr_fixture.json").exists())

    def test_save_tldr_fixture_surfaces_display_scale_from_capture_bbox(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            screenshot = root / "capture.png"
            screenshot.write_bytes(b"png-bytes")

            manifest = save_tldr_fixture(
                fixture_dir=root / "fixtures" / "mail-thread",
                screenshot_path=screenshot,
                capture={"status": "ok", "bbox": {"display_scale": 2}},
                hotkey_at="2026-05-04T12:00:00.000+00:00",
            )

            self.assertEqual(manifest["display_scale"], 2)

    @mock.patch("scratchpad.tldr_reply.runner.capture_active_window")
    def test_save_fixture_mode_does_not_create_stub_run_dir(
        self,
        mock_capture,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)

            def fake_capture(path: Path) -> dict:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"png-bytes")
                return {"status": "ok", "duration_ms": 4}

            mock_capture.side_effect = fake_capture
            app = object.__new__(TldrReplyApp)
            app.save_fixture_dir = root / "fixtures" / "chat"
            app._notify = mock.Mock()  # type: ignore[method-assign]

            app._run_once("2026-05-04T12:00:00.000+00:00")

            self.assertFalse((root / "runs").exists())
            self.assertTrue((root / "fixtures" / "chat" / "screenshot.png").exists())


if __name__ == "__main__":
    unittest.main()
