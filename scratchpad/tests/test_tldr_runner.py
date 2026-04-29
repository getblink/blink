"""Focused tests for TLDR runner event dispatch."""

from __future__ import annotations

import sys
import threading
import unittest
from pathlib import Path
from unittest import mock

SCRATCHPAD_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRATCHPAD_DIR.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scratchpad.tldr_reply.runner import TldrReplyApp  # noqa: E402


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
    def test_enter_with_no_selection_is_noop(self) -> None:
        app = _make_app(mock.Mock(), ["a", "b"])

        result = app._on_enter_hotkey()

        self.assertTrue(result)
        self.assertTrue(app._panel_open)
        self.assertEqual(len(app._dispatched), 0)

    def test_enter_with_selection_copies(self) -> None:
        app = _make_app(mock.Mock(), ["first", "second"])
        app._expanded_choice_index = 1

        result = app._on_enter_hotkey()

        self.assertTrue(result)
        self.assertFalse(app._panel_open)
        self.assertIsNone(app._expanded_choice_index)
        self.assertEqual(len(app._dispatched), 1)

    def test_enter_without_panel_open_passes_event_through(self) -> None:
        app = _make_app(None, [])
        app._panel_open = False

        result = app._on_enter_hotkey()

        self.assertFalse(result)
        self.assertEqual(len(app._dispatched), 0)


if __name__ == "__main__":
    unittest.main()
