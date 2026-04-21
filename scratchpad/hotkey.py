from __future__ import annotations

import threading
from dataclasses import dataclass
from typing import Callable

import Quartz


MODIFIER_FLAGS = {
    "cmd": Quartz.kCGEventFlagMaskCommand,
    "command": Quartz.kCGEventFlagMaskCommand,
    "ctrl": Quartz.kCGEventFlagMaskControl,
    "control": Quartz.kCGEventFlagMaskControl,
    "opt": Quartz.kCGEventFlagMaskAlternate,
    "option": Quartz.kCGEventFlagMaskAlternate,
    "alt": Quartz.kCGEventFlagMaskAlternate,
    "shift": Quartz.kCGEventFlagMaskShift,
}

RELEVANT_FLAGS = (
    Quartz.kCGEventFlagMaskCommand
    | Quartz.kCGEventFlagMaskControl
    | Quartz.kCGEventFlagMaskAlternate
    | Quartz.kCGEventFlagMaskShift
)

KEYCODES = {
    "a": 0,
    "s": 1,
    "d": 2,
    "f": 3,
    "h": 4,
    "g": 5,
    "z": 6,
    "x": 7,
    "c": 8,
    "v": 9,
    "b": 11,
    "q": 12,
    "w": 13,
    "e": 14,
    "r": 15,
    "y": 16,
    "t": 17,
    "1": 18,
    "2": 19,
    "3": 20,
    "4": 21,
    "6": 22,
    "5": 23,
    "=": 24,
    "9": 25,
    "7": 26,
    "-": 27,
    "8": 28,
    "0": 29,
    "]": 30,
    "o": 31,
    "u": 32,
    "[": 33,
    "i": 34,
    "p": 35,
    "l": 37,
    "j": 38,
    "'": 39,
    "k": 40,
    ";": 41,
    "\\": 42,
    ",": 43,
    "/": 44,
    "n": 45,
    "m": 46,
    ".": 47,
    "tab": 48,
    "space": 49,
    "return": 36,
    "enter": 76,
    "escape": 53,
    "esc": 53,
    "up": 126,
    "down": 125,
    "left": 123,
    "right": 124,
}


@dataclass(frozen=True)
class ParsedHotkey:
    raw: str
    key_name: str
    keycode: int
    flags: int
    modifier_count: int


def normalize_flags(flags: int) -> int:
    return int(flags) & RELEVANT_FLAGS


def parse_hotkey(hotkey: str) -> ParsedHotkey:
    pieces = [piece.strip().lower() for piece in hotkey.split("+") if piece.strip()]
    if not pieces:
        raise ValueError(f"Invalid hotkey: {hotkey!r}")

    key_name = pieces[-1]
    modifiers = pieces[:-1]

    if key_name not in KEYCODES:
        raise ValueError(f"Unsupported hotkey key: {key_name}")

    flags = 0
    normalized_modifiers: set[str] = set()
    for modifier in modifiers:
        if modifier not in MODIFIER_FLAGS:
            raise ValueError(f"Unsupported hotkey modifier: {modifier}")
        normalized_modifiers.add(modifier)
        flags |= MODIFIER_FLAGS[modifier]

    return ParsedHotkey(
        raw=hotkey,
        key_name=key_name,
        keycode=KEYCODES[key_name],
        flags=flags,
        modifier_count=len(normalized_modifiers),
    )


class HotkeyListener:
    def __init__(self) -> None:
        self._bindings: list[tuple[ParsedHotkey, Callable[[], bool]]] = []
        self._thread: threading.Thread | None = None
        self._ready = threading.Event()
        self._tap = None
        self._run_loop = None
        self._error: Exception | None = None
        self._started = False
        self._callback_ref = self._event_callback

    def register(self, hotkey: str, callback: Callable[[], bool]) -> None:
        self._bindings.append((parse_hotkey(hotkey), callback))
        self._bindings.sort(key=lambda item: item[0].modifier_count, reverse=True)

    def start(self) -> None:
        if self._started:
            return
        self._thread = threading.Thread(
            target=self._run_event_loop,
            name="blink-hotkey-listener",
            daemon=True,
        )
        self._thread.start()
        self._ready.wait()
        self._started = True
        if self._error:
            raise RuntimeError(str(self._error)) from self._error

    def stop(self) -> None:
        if self._tap is not None:
            Quartz.CGEventTapEnable(self._tap, False)
        if self._run_loop is not None:
            Quartz.CFRunLoopStop(self._run_loop)
        if self._thread and self._thread.is_alive() and threading.current_thread() is not self._thread:
            self._thread.join(timeout=2)

    def _run_event_loop(self) -> None:
        mask = Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            mask,
            self._callback_ref,
            None,
        )

        if tap is None:
            self._error = RuntimeError(
                "Failed to create Quartz event tap. Grant Input Monitoring/Accessibility access and try again."
            )
            self._ready.set()
            return

        self._tap = tap
        self._run_loop = Quartz.CFRunLoopGetCurrent()
        source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        Quartz.CFRunLoopAddSource(self._run_loop, source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(tap, True)
        self._ready.set()
        Quartz.CFRunLoopRun()

    def _event_callback(self, proxy, event_type, event, refcon):
        if event_type in (
            Quartz.kCGEventTapDisabledByTimeout,
            Quartz.kCGEventTapDisabledByUserInput,
        ):
            if self._tap is not None:
                Quartz.CGEventTapEnable(self._tap, True)
            return event

        if event_type != Quartz.kCGEventKeyDown:
            return event

        keycode = int(
            Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
        )
        flags = normalize_flags(int(Quartz.CGEventGetFlags(event)))

        for parsed, callback in self._bindings:
            if keycode == parsed.keycode and flags == parsed.flags:
                swallow = bool(callback())
                return None if swallow else event

        return event
