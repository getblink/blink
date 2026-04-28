"""Standalone AppKit UI lab for the TLDR reply panel.

Runs outside the hotkey + Gemini harness so we can iterate on the panel
design directly. Each layout attempt lives as a ``variant_<name>`` function
and is selected from the CLI:

    ./tldr-ui                 # default variant
    ./tldr-ui v1              # named variant
    ./tldr-ui --list          # list available variants
    ./tldr-ui v1 --long-tldr  # swap in a longer sample TLDR

Variants are intentionally self-contained: do **not** import from
``overlay.py`` or share design helpers between variants. The point is to
explore fresh designs without being constrained by prior choices. Once a
direction wins, we can fold it back into ``overlay.py`` as a deliberate
step.

The one shared helper is ``make_glass_pane`` — it picks ``NSGlassEffectView``
(Liquid Glass, macOS 26+) when the runtime exposes it and falls back to
``NSVisualEffectView`` on older OSes. OS-feature gating belongs in one place
so variants can't accidentally render the new design on one card and the
old one on another.

Press ``Esc`` or ``Cmd+Q`` to quit.
"""
from __future__ import annotations

import argparse
import math
import sys
from typing import Callable

import AppKit
import Foundation
import Quartz
import objc
from PyObjCTools import AppHelper


SAMPLE_TLDR_SHORT = "Marcus wants a one-line answer on whether Q3 slipped because of auth or billing."
SAMPLE_TLDR_LONG = (
    "Marcus is asking whether the Q3 launch slipped because of the auth migration "
    "or the new billing pipeline, and wants a short paragraph he can forward to "
    "the exec team before standup in twenty minutes."
)
SAMPLE_SUGGESTIONS = [
    "Auth migration was the bigger blocker — it pushed the freeze by ~10 days.",
    "Billing pipeline was on track; the slip is squarely on the auth side.",
    "Both contributed, but auth was roughly 80% of the slip — happy to write a longer note that separates dependency risk from implementation work.",
]


class LabPanel(AppKit.NSPanel):
    def canBecomeKeyWindow(self) -> bool:
        return True

    def canBecomeMainWindow(self) -> bool:
        return True

    def keyDown_(self, event):
        if event.keyCode() == 53:  # Esc
            AppKit.NSApp.terminate_(None)
            return
        if event.keyCode() in (18, 19, 20):  # 1, 2, 3
            self.expandSuggestion_(event.keyCode() - 18)
            return
        objc.super(LabPanel, self).keyDown_(event)

    @objc.python_method
    def configureExpansion(
        self,
        background: AppKit.NSView,
        pills: list[AppKit.NSView],
        labels: list[AppKit.NSTextField],
        collapsed_frames: list[Foundation.NSRect],
        expanded_frames: list[Foundation.NSRect],
        summary_frame: Foundation.NSRect,
        hint_frame: Foundation.NSRect,
    ) -> None:
        self._background = background
        self._pills = pills
        self._labels = labels
        self._collapsed_frames = collapsed_frames
        self._expanded_frames = expanded_frames
        self._summary_frame = summary_frame
        self._hint_frame = hint_frame
        frame = self.frame()
        self._base_height = float(frame.size.height)
        self._base_top_y = float(frame.origin.y + frame.size.height)

    @objc.python_method
    def expandSuggestion_(self, index: int) -> None:
        if not hasattr(self, "_pills") or index >= len(self._pills):
            return
        height_delta = (
            self._expanded_frames[index].size.height
            - self._collapsed_frames[index].size.height
        )
        target_height = self._base_height + height_delta
        frame = self.frame()
        self.setFrame_display_animate_(
            Foundation.NSMakeRect(
                frame.origin.x,
                self._base_top_y - target_height,
                frame.size.width,
                target_height,
            ),
            False,
            False,
        )
        self._background.setFrame_(
            Foundation.NSMakeRect(0, 0, frame.size.width, target_height)
        )
        summary = self._background.subviews()[0]
        summary.setFrameOrigin_(
            Foundation.NSMakePoint(
                self._summary_frame.origin.x,
                self._summary_frame.origin.y + height_delta,
            )
        )
        for pill_index, pill in enumerate(self._pills):
            source = self._collapsed_frames[pill_index]
            is_expanded = pill_index == index
            pill_height = (
                self._expanded_frames[pill_index].size.height
                if is_expanded
                else source.size.height
            )
            pill_y = source.origin.y + (height_delta if pill_index < index else 0.0)
            pill.setFrame_(
                Foundation.NSMakeRect(
                    source.origin.x,
                    pill_y,
                    source.size.width,
                    pill_height,
                )
            )
            pill.layer().setCornerRadius_(pill_height / 2.0)
            label = self._labels[pill_index]
            label.setLineBreakMode_(
                AppKit.NSLineBreakByWordWrapping
                if is_expanded
                else AppKit.NSLineBreakByTruncatingTail
            )
            label.setUsesSingleLineMode_(not is_expanded)
            label_y = 14 if is_expanded else (pill_height - 22) / 2
            label_height = pill_height - 28 if is_expanded else 22
            label.setFrame_(
                Foundation.NSMakeRect(
                    52,
                    label_y,
                    source.size.width - 76,
                    label_height,
                )
            )
        hint = self._background.subviews()[-1]
        hint.setFrame_(self._hint_frame)
        self.displayIfNeeded()


def _center_frame(width: float, height: float) -> Foundation.NSRect:
    screen = AppKit.NSScreen.mainScreen().frame()
    origin_x = screen.origin.x + (screen.size.width - width) / 2
    origin_y = screen.origin.y + (screen.size.height - height) / 2
    return Foundation.NSMakeRect(origin_x, origin_y, width, height)


def _make_panel(width: float, height: float) -> LabPanel:
    panel = LabPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        _center_frame(width, height),
        AppKit.NSWindowStyleMaskBorderless,
        AppKit.NSBackingStoreBuffered,
        False,
    )
    panel.setLevel_(AppKit.NSStatusWindowLevel)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(AppKit.NSColor.clearColor())
    panel.setReleasedWhenClosed_(False)
    panel.setHidesOnDeactivate_(False)
    return panel


def _measure_text_height(text: str, width: float, font: AppKit.NSFont) -> float:
    string = Foundation.NSAttributedString.alloc().initWithString_attributes_(
        text,
        {AppKit.NSFontAttributeName: font},
    )
    bounds = string.boundingRectWithSize_options_(
        Foundation.NSMakeSize(width, 1000),
        AppKit.NSStringDrawingUsesLineFragmentOrigin
        | AppKit.NSStringDrawingUsesFontLeading,
    )
    return max(22.0, math.ceil(float(bounds.size.height)) + 2.0)


# ---------------------------------------------------------------------------
# Liquid Glass / fallback helpers
# ---------------------------------------------------------------------------

# NSGlassEffectView ships in macOS 26 (Tahoe). On older OSes the symbol is
# absent from the AppKit bridge, so we feature-detect rather than version-check.
_GLASS_CLASS = getattr(AppKit, "NSGlassEffectView", None)
LIQUID_GLASS_AVAILABLE = _GLASS_CLASS is not None


def make_glass_pane(
    frame: Foundation.NSRect,
    corner_radius: float = 22.0,
    tint_color: AppKit.NSColor | None = None,
) -> tuple[AppKit.NSView, AppKit.NSView]:
    """Return ``(outer, content)`` where ``outer`` is the view to install in
    the hierarchy and ``content`` is the view variants should add subviews to.

    Uses ``NSGlassEffectView`` when available (macOS 26+) so the pane gets
    the system Liquid Glass treatment, including legibility-aware tinting of
    its content. Falls back to a rounded-and-clipped ``NSVisualEffectView``
    on older OSes — close enough visually for a lab harness, and the call
    sites stay identical.
    """
    if _GLASS_CLASS is not None:
        outer = _GLASS_CLASS.alloc().initWithFrame_(frame)
        outer.setCornerRadius_(corner_radius)
        if tint_color is not None:
            outer.setTintColor_(tint_color)
        content = AppKit.NSView.alloc().initWithFrame_(
            Foundation.NSMakeRect(0, 0, frame.size.width, frame.size.height)
        )
        content.setAutoresizingMask_(
            AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
        )
        outer.setContentView_(content)
        return outer, content

    outer = AppKit.NSVisualEffectView.alloc().initWithFrame_(frame)
    outer.setMaterial_(AppKit.NSVisualEffectMaterialHUDWindow)
    outer.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
    outer.setState_(AppKit.NSVisualEffectStateActive)
    outer.setWantsLayer_(True)
    outer.layer().setCornerRadius_(corner_radius)
    outer.layer().setMasksToBounds_(True)
    if tint_color is not None:
        components = tint_color.colorUsingColorSpace_(
            AppKit.NSColorSpace.sRGBColorSpace()
        )
        outer.layer().setBackgroundColor_(
            Quartz.CGColorCreateGenericRGB(
                components.redComponent(),
                components.greenComponent(),
                components.blueComponent(),
                components.alphaComponent(),
            )
        )
    return outer, outer


# ---------------------------------------------------------------------------
# Variants
# ---------------------------------------------------------------------------


def variant_v1(tldr: str, suggestions: list[str]) -> AppKit.NSPanel:
    """Summary in a Liquid Glass card on top, suggestions as separate glass
    pills stacked below it. Each pill is its own ``NSGlassEffectView`` so the
    blur breaks between them and the layout feels like discrete actions
    rather than a list trapped inside one big card."""
    width = 560.0
    summary_height = 132.0
    pill_height = 62.0
    pill_gap = 8.0
    section_gap = 14.0
    hint_height = 20.0
    hint_top_gap = 12.0
    suggestion_font = AppKit.NSFont.systemFontOfSize_(16.0)

    pill_count = len(suggestions)
    total_height = (
        summary_height
        + section_gap
        + pill_count * pill_height
        + max(0, pill_count - 1) * pill_gap
        + hint_top_gap
        + hint_height
    )

    panel = _make_panel(width, total_height)
    background = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, width, total_height)
    )
    background.setWantsLayer_(True)
    background.layer().setBackgroundColor_(
        Quartz.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0)
    )
    panel.setContentView_(background)

    # --- summary card ---------------------------------------------------
    summary_y = total_height - summary_height
    summary_frame = Foundation.NSMakeRect(0, summary_y, width, summary_height)
    summary_glass, summary_content = make_glass_pane(
        summary_frame,
        corner_radius=24.0,
    )
    background.addSubview_(summary_glass)

    status_text = (
        "Liquid Glass: ON (NSGlassEffectView)"
        if LIQUID_GLASS_AVAILABLE
        else "Liquid Glass: OFF — falling back to NSVisualEffectView"
    )
    status = AppKit.NSTextField.alloc().initWithFrame_(
        Foundation.NSMakeRect(24, summary_height - 36, width - 48, 18)
    )
    status.setEditable_(False)
    status.setSelectable_(False)
    status.setBezeled_(False)
    status.setDrawsBackground_(False)
    status.setStringValue_(status_text)
    status.setFont_(
        AppKit.NSFont.monospacedSystemFontOfSize_weight_(11.0, AppKit.NSFontWeightMedium)
    )
    status.setTextColor_(AppKit.NSColor.secondaryLabelColor())
    summary_content.addSubview_(status)

    summary = AppKit.NSTextField.alloc().initWithFrame_(
        Foundation.NSMakeRect(24, 18, width - 48, summary_height - 60)
    )
    summary.setEditable_(False)
    summary.setSelectable_(False)
    summary.setBezeled_(False)
    summary.setDrawsBackground_(False)
    summary.setStringValue_(tldr)
    summary.setFont_(
        AppKit.NSFont.systemFontOfSize_weight_(16.5, AppKit.NSFontWeightSemibold)
    )
    summary.setTextColor_(AppKit.NSColor.labelColor())
    summary.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    summary_content.addSubview_(summary)

    # --- suggestion pills ----------------------------------------------
    y = summary_y - section_gap
    pills: list[AppKit.NSView] = []
    labels: list[AppKit.NSTextField] = []
    collapsed_frames: list[Foundation.NSRect] = []
    expanded_frames: list[Foundation.NSRect] = []
    for index, text in enumerate(suggestions, start=1):
        y -= pill_height
        collapsed_frame = Foundation.NSMakeRect(0, y, width, pill_height)
        expanded_height = max(
            pill_height,
            _measure_text_height(text, width - 76, suggestion_font) + 28,
        )
        expanded_frame = Foundation.NSMakeRect(
            0,
            y - (expanded_height - pill_height),
            width,
            expanded_height,
        )
        pill_glass, pill_content = make_glass_pane(
            collapsed_frame,
            corner_radius=pill_height / 2.0,
        )
        background.addSubview_(pill_glass)
        pills.append(pill_glass)
        collapsed_frames.append(collapsed_frame)
        expanded_frames.append(expanded_frame)

        number = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(20, (pill_height - 22) / 2, 24, 22)
        )
        number.setEditable_(False)
        number.setSelectable_(False)
        number.setBezeled_(False)
        number.setDrawsBackground_(False)
        number.setStringValue_(str(index))
        number.setFont_(
            AppKit.NSFont.systemFontOfSize_weight_(13.0, AppKit.NSFontWeightSemibold)
        )
        number.setTextColor_(AppKit.NSColor.secondaryLabelColor())
        pill_content.addSubview_(number)

        label = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(52, (pill_height - 22) / 2, width - 76, 22)
        )
        label.setEditable_(False)
        label.setSelectable_(False)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        label.setStringValue_(text)
        label.setFont_(suggestion_font)
        label.setTextColor_(AppKit.NSColor.labelColor())
        label.setLineBreakMode_(AppKit.NSLineBreakByTruncatingTail)
        label.setUsesSingleLineMode_(True)
        pill_content.addSubview_(label)
        labels.append(label)

        if index < pill_count:
            y -= pill_gap

    # --- footer hint (no card; floats over whatever is behind) ---------
    hint = AppKit.NSTextField.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, width, hint_height)
    )
    hint.setEditable_(False)
    hint.setSelectable_(False)
    hint.setBezeled_(False)
    hint.setDrawsBackground_(False)
    hint.setStringValue_("Press 1 / 2 / 3 to expand · repeat in the app to copy · Esc to dismiss")
    hint.setFont_(AppKit.NSFont.systemFontOfSize_(12.0))
    hint.setTextColor_(AppKit.NSColor.tertiaryLabelColor())
    hint.setAlignment_(AppKit.NSTextAlignmentCenter)
    background.addSubview_(hint)
    panel.configureExpansion(
        background,
        pills,
        labels,
        collapsed_frames,
        expanded_frames,
        summary_frame,
        hint.frame(),
    )

    return panel


VARIANTS: dict[str, Callable[[str, list[str]], AppKit.NSPanel]] = {
    "v1": variant_v1,
}
DEFAULT_VARIANT = "v1"


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def _install_quit_menu() -> None:
    """Wire up Cmd+Q so the lab is easy to dismiss without the dock icon."""
    menubar = AppKit.NSMenu.alloc().init()
    app_item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(app_item)
    app_menu = AppKit.NSMenu.alloc().init()
    quit_item = AppKit.NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
        "Quit ui_lab", b"terminate:", "q"
    )
    app_menu.addItem_(quit_item)
    app_item.setSubmenu_(app_menu)
    AppKit.NSApp.setMainMenu_(menubar)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Standalone AppKit UI lab for the TLDR reply panel.",
    )
    parser.add_argument(
        "variant",
        nargs="?",
        default=DEFAULT_VARIANT,
        help=f"Variant to render (default: {DEFAULT_VARIANT}).",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List registered variants and exit.",
    )
    parser.add_argument(
        "--long-tldr",
        action="store_true",
        help="Use the longer multi-line sample TLDR instead of the short one.",
    )
    args = parser.parse_args()

    if args.list:
        for name in sorted(VARIANTS):
            print(name)
        return 0

    if args.variant not in VARIANTS:
        print(
            f"unknown variant {args.variant!r}; known: {', '.join(sorted(VARIANTS))}",
            file=sys.stderr,
        )
        return 2

    tldr = SAMPLE_TLDR_LONG if args.long_tldr else SAMPLE_TLDR_SHORT

    app = AppKit.NSApplication.sharedApplication()
    app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyRegular)
    _install_quit_menu()

    panel = VARIANTS[args.variant](tldr, list(SAMPLE_SUGGESTIONS))
    panel.makeKeyAndOrderFront_(None)
    app.activateIgnoringOtherApps_(True)

    AppHelper.runEventLoop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
