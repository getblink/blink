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
LAB_SUGGESTION_LINE_SPACING = 5.0
LAB_COLLAPSED_TEXT_HEIGHT = 24.0
LAB_NUMBER_HEIGHT = 24.0
LAB_PILL_HEIGHT = 62.0
SHADOW_BLEED = 36.0
# Match the natural top/bottom gap of the collapsed pill so the first line of
# text stays at the same screen position when the pill expands downward.
LAB_SUGGESTION_VERTICAL_PADDING = (LAB_PILL_HEIGHT - LAB_COLLAPSED_TEXT_HEIGHT) / 2.0

ENTRANCE_DURATION = 0.18
ENTRANCE_STAGGER = 0.035
ENTRANCE_FOOTER_DELAY_PADDING = 0.04
EXPAND_DURATION = 0.22
BLOB_MERGE_SPACING = 6.0  # < pill_gap (8pt) so final positions separate; stacked (0pt) merge
BLOB_MATERIALIZE_DELAY = 0.03
BLOB_FANOUT_DURATION = 0.22
BLOB_FANOUT_STAGGER = 0.07



class LabPanel(AppKit.NSPanel):
    def canBecomeKeyWindow(self) -> bool:
        return True

    def canBecomeMainWindow(self) -> bool:
        return True

    def keyDown_(self, event):
        if event.keyCode() == 53:  # Esc
            self._invalidate_timers()
            AppKit.NSApp.terminate_(None)
            return
        if event.keyCode() in (18, 19, 20):  # 1, 2, 3
            self.expandSuggestion_(event.keyCode() - 18)
            return
        objc.super(LabPanel, self).keyDown_(event)

    def animationResizeTime_(self, frame):
        # Defensive fallback if a future path animates panel resizing again.
        # The current expansion path sets the panel frame synchronously so the
        # TLDR can be pinned before suggestion rows animate downward.
        return EXPAND_DURATION

    @objc.python_method
    def _register_timer(self, timer: Any) -> None:
        timers = getattr(self, "_show_timers", None)
        if timers is None:
            self._show_timers = [timer]
        else:
            timers.append(timer)

    @objc.python_method
    def _invalidate_timers(self) -> None:
        for timer in getattr(self, "_show_timers", []):
            try:
                timer.invalidate()
            except Exception:
                pass
        self._show_timers = []

    @objc.python_method
    def configureExpansion(
        self,
        background: AppKit.NSView,
        pills: list[AppKit.NSView],
        numbers: list[AppKit.NSTextField],
        labels: list[AppKit.NSTextField],
        suggestion_texts: list[str],
        collapsed_label_texts: list[str],
        collapsed_frames: list[Foundation.NSRect],
        expanded_frames: list[Foundation.NSRect],
        summary_frame: Foundation.NSRect,
        hint_frame: Foundation.NSRect,
        pill_container: AppKit.NSView | None = None,
        base_container_frame: Foundation.NSRect | None = None,
        summary_view: AppKit.NSView | None = None,
        hint_view: AppKit.NSView | None = None,
        pill_contents: list[AppKit.NSView] | None = None,
    ) -> None:
        self._background = background
        self._pills = pills
        self._numbers = numbers
        self._labels = labels
        self._suggestion_texts = suggestion_texts
        self._collapsed_label_texts = collapsed_label_texts
        self._collapsed_frames = collapsed_frames
        self._expanded_frames = expanded_frames
        self._summary_frame = summary_frame
        self._hint_frame = hint_frame
        self._pill_container = pill_container
        self._base_container_frame = base_container_frame
        self._summary_view = summary_view
        self._hint_view = hint_view
        self._pill_contents = pill_contents or []
        frame = self.frame()
        self._base_height = float(frame.size.height)
        self._base_top_y = float(frame.origin.y + frame.size.height)

    @objc.python_method
    def expandSuggestion_(self, index: int) -> None:
        self._invalidate_timers()
        if not hasattr(self, "_pills") or index >= len(self._pills):
            return
        height_delta = (
            self._expanded_frames[index].size.height
            - self._collapsed_frames[index].size.height
        )
        target_height = self._base_height + height_delta
        frame = self.frame()
        new_panel_frame = Foundation.NSMakeRect(
            frame.origin.x,
            self._base_top_y - target_height,
            frame.size.width,
            target_height,
        )

        # If entrance timers were cancelled, bring all views to full opacity.
        summary_view = getattr(self, "_summary_view", None) or self._background.subviews()[0]
        hint_view = getattr(self, "_hint_view", None) or self._background.subviews()[-1]
        summary_view.setAlphaValue_(1.0)
        hint_view.setAlphaValue_(1.0)
        container = getattr(self, "_pill_container", None)
        if container is not None:
            container.setAlphaValue_(1.0)
        for pill in self._pills:
            pill.setAlphaValue_(1.0)
        for content in getattr(self, "_pill_contents", []):
            content.setAlphaValue_(1.0)

        # Compute per-pill geometry and swap label text/mode synchronously
        # before the animation group so text reflows into the correct size
        # during the animated frame interpolation.
        pill_geometries = []
        for pill_index, pill in enumerate(self._pills):
            source = self._collapsed_frames[pill_index]
            is_expanded = pill_index == index
            pill_height = (
                self._expanded_frames[pill_index].size.height
                if is_expanded
                else source.size.height
            )
            pill_y = source.origin.y + (height_delta if pill_index < index else 0.0)
            label = self._labels[pill_index]
            label_text = self._suggestion_texts[pill_index]
            collapsed_text = self._collapsed_label_texts[pill_index]
            label_font = label.font() or AppKit.NSFont.systemFontOfSize_(16.0)
            label.setLineBreakMode_(
                AppKit.NSLineBreakByWordWrapping if is_expanded else AppKit.NSLineBreakByClipping
            )
            label.setUsesSingleLineMode_(not is_expanded)
            if is_expanded:
                _set_label_text(label, label_text, label_font, AppKit.NSColor.labelColor(), LAB_SUGGESTION_LINE_SPACING)
                label_height = _measure_text_height(label_text, source.size.width - 92, label_font, LAB_SUGGESTION_LINE_SPACING)
                label_y = LAB_SUGGESTION_VERTICAL_PADDING
                number_y = label_y + label_height - LAB_NUMBER_HEIGHT
            else:
                label.setStringValue_(collapsed_text)
                label.setFont_(label_font)
                label.setTextColor_(AppKit.NSColor.labelColor())
                label_height = LAB_COLLAPSED_TEXT_HEIGHT
                label_y = (pill_height - label_height) / 2
                number_y = (pill_height - LAB_NUMBER_HEIGHT) / 2
            pill_geometries.append((pill, source, pill_y, pill_height, label, label_y, label_height, self._numbers[pill_index], number_y))

        container_frame = getattr(self, "_base_container_frame", None)
        new_container_frame = None
        if container is not None and container_frame is not None:
            new_container_frame = Foundation.NSMakeRect(
                container_frame.origin.x,
                container_frame.origin.y,
                container_frame.size.width,
                container_frame.size.height + height_delta,
            )

        self.setFrame_display_(new_panel_frame, True)
        self._background.setFrame_(
            Foundation.NSMakeRect(0, 0, frame.size.width, target_height)
        )
        summary_view.setFrameOrigin_(
            Foundation.NSMakePoint(
                self._summary_frame.origin.x,
                self._summary_frame.origin.y + height_delta,
            )
        )
        hint_view.setFrameOrigin_(
            Foundation.NSMakePoint(
                self._hint_frame.origin.x,
                self._hint_frame.origin.y + height_delta,
            )
        )
        if container is not None and new_container_frame is not None:
            container.setFrame_(new_container_frame)
        for pill, source, pill_y, _pill_height, label, _label_y, _label_height, _number, _number_y in pill_geometries:
            start_y = pill_y if pill_y > source.origin.y else source.origin.y + height_delta
            pill.setFrame_(
                Foundation.NSMakeRect(
                    source.origin.x,
                    start_y,
                    source.size.width,
                    source.size.height,
                )
            )
            label.setFrame_(
                Foundation.NSMakeRect(
                    68,
                    (source.size.height - LAB_COLLAPSED_TEXT_HEIGHT) / 2,
                    source.size.width - 92,
                    LAB_COLLAPSED_TEXT_HEIGHT,
                )
            )

        AppKit.NSAnimationContext.beginGrouping()
        try:
            ctx = AppKit.NSAnimationContext.currentContext()
            ctx.setDuration_(EXPAND_DURATION)
            ctx.setTimingFunction_(
                Quartz.CAMediaTimingFunction.functionWithName_(
                    Quartz.kCAMediaTimingFunctionEaseInEaseOut
                )
            )
            for pill, source, pill_y, pill_height, label, label_y, label_height, number, number_y in pill_geometries:
                _set_corner_radius(pill, source.size.height / 2.0)
                pill.animator().setFrame_(
                    Foundation.NSMakeRect(source.origin.x, pill_y, source.size.width, pill_height)
                )
                number.animator().setFrame_(
                    Foundation.NSMakeRect(20, number_y, 28, LAB_NUMBER_HEIGHT)
                )
                label.animator().setFrame_(
                    Foundation.NSMakeRect(68, label_y, source.size.width - 92, label_height)
                )
            hint_view.animator().setFrame_(self._hint_frame)
        finally:
            AppKit.NSAnimationContext.endGrouping()


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


def _set_corner_radius(view: AppKit.NSView, radius: float) -> None:
    if hasattr(view, "setCornerRadius_"):
        view.setCornerRadius_(radius)
        return
    layer = view.layer()
    if layer is not None:
        layer.setCornerRadius_(radius)


def _wrapping_paragraph_style(line_spacing: float) -> AppKit.NSMutableParagraphStyle:
    paragraph = AppKit.NSMutableParagraphStyle.alloc().init()
    paragraph.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    if line_spacing:
        paragraph.setLineSpacing_(line_spacing)
    return paragraph


def _set_label_text(
    label: AppKit.NSTextField,
    text: str,
    font: AppKit.NSFont,
    color: AppKit.NSColor,
    line_spacing: float,
) -> None:
    attributed = Foundation.NSAttributedString.alloc().initWithString_attributes_(
        text,
        {
            AppKit.NSFontAttributeName: font,
            AppKit.NSForegroundColorAttributeName: color,
            AppKit.NSParagraphStyleAttributeName: _wrapping_paragraph_style(line_spacing),
        },
    )
    label.setAttributedStringValue_(attributed)


def _measure_text_height(
    text: str,
    width: float,
    font: AppKit.NSFont,
    line_spacing: float = 0.0,
) -> float:
    # cellSizeForBounds is the same path NSTextField uses to draw, so the
    # measured height matches the rendered height. boundingRectWithSize tends
    # to underestimate slightly per Apple's docs.
    attributed = Foundation.NSAttributedString.alloc().initWithString_attributes_(
        text,
        {
            AppKit.NSFontAttributeName: font,
            AppKit.NSParagraphStyleAttributeName: _wrapping_paragraph_style(line_spacing),
        },
    )
    cell = AppKit.NSTextFieldCell.alloc().init()
    cell.setBezeled_(False)
    cell.setEditable_(False)
    cell.setSelectable_(False)
    cell.setDrawsBackground_(False)
    cell.setWraps_(True)
    cell.setUsesSingleLineMode_(False)
    cell.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    cell.setAttributedStringValue_(attributed)
    size = cell.cellSizeForBounds_(
        Foundation.NSMakeRect(0, 0, width, 1.0e6)
    )
    return math.ceil(float(size.height))


def _measure_text_width(text: str, font: AppKit.NSFont) -> float:
    string = Foundation.NSString.stringWithString_(text)
    size = string.sizeWithAttributes_({AppKit.NSFontAttributeName: font})
    return float(size.width)


def _collapsed_single_line_text(text: str, width: float, font: AppKit.NSFont) -> str:
    if _measure_text_width(text, font) <= width:
        return text
    suffix = "..."
    available = max(0.0, width - _measure_text_width(suffix, font))
    low = 0
    high = len(text)
    best = ""
    while low <= high:
        mid = (low + high) // 2
        candidate = text[:mid].rstrip()
        if _measure_text_width(candidate, font) <= available:
            best = candidate
            low = mid + 1
        else:
            high = mid - 1
    return f"{best}{suffix}" if best else suffix


# ---------------------------------------------------------------------------
# Liquid Glass / fallback helpers
# ---------------------------------------------------------------------------

# NSGlassEffectView ships in macOS 26 (Tahoe). On older OSes the symbol is
# absent from the AppKit bridge, so we feature-detect rather than version-check.
_GLASS_CLASS = getattr(AppKit, "NSGlassEffectView", None)
LIQUID_GLASS_AVAILABLE = _GLASS_CLASS is not None
_GLASS_CONTAINER_CLASS = getattr(AppKit, "NSGlassEffectContainerView", None)
LIQUID_GLASS_CONTAINER_AVAILABLE = _GLASS_CONTAINER_CLASS is not None
# .regular = the more opaque/frosted style; .clear is the more transparent
# variant. Default style isn't documented; setting explicitly is safer.
_GLASS_STYLE_REGULAR = getattr(AppKit, "NSGlassEffectViewStyleRegular", None)


def _suppress_glass_outline(view: AppKit.NSView) -> None:
    if hasattr(view, "hideActiveFirstResponderIndication"):
        view.hideActiveFirstResponderIndication()
    if hasattr(view, "setFocusRingType_") and hasattr(AppKit, "NSFocusRingTypeNone"):
        view.setFocusRingType_(AppKit.NSFocusRingTypeNone)
    if hasattr(view, "setShadow_"):
        shadow = AppKit.NSShadow.alloc().init()
        shadow.setShadowColor_(AppKit.NSColor.clearColor())
        shadow.setShadowBlurRadius_(0.0)
        shadow.setShadowOffset_(Foundation.NSMakeSize(0.0, 0.0))
        view.setShadow_(shadow)
    layer = view.layer() if hasattr(view, "layer") else None
    if layer is not None:
        layer.setBorderWidth_(0.0)
        layer.setBorderColor_(Quartz.CGColorCreateGenericRGB(0, 0, 0, 0))


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
        if _GLASS_STYLE_REGULAR is not None:
            outer.setStyle_(_GLASS_STYLE_REGULAR)
        if tint_color is not None:
            outer.setTintColor_(tint_color)
        _suppress_glass_outline(outer)
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
    _suppress_glass_outline(outer)
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
    pill_height = LAB_PILL_HEIGHT
    pill_gap = 8.0
    section_gap = 14.0
    hint_height = 20.0
    hint_top_gap = 12.0
    suggestion_font = AppKit.NSFont.systemFontOfSize_(16.0)
    number_font = AppKit.NSFont.systemFontOfSize_weight_(
        16.0,
        AppKit.NSFontWeightSemibold,
    )

    pill_count = len(suggestions)
    content_height = (
        summary_height
        + section_gap
        + pill_count * pill_height
        + max(0, pill_count - 1) * pill_gap
        + hint_top_gap
        + hint_height
    )
    panel_width = width + (SHADOW_BLEED * 2.0)
    panel_height = content_height + (SHADOW_BLEED * 2.0)
    content_x = SHADOW_BLEED
    content_bottom = SHADOW_BLEED

    panel = _make_panel(panel_width, panel_height)
    background = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, panel_width, panel_height)
    )
    background.setWantsLayer_(True)
    background.layer().setBackgroundColor_(
        Quartz.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0)
    )
    panel.setContentView_(background)

    # --- compute layout up front so the summary can stay pinned while the
    # suggestion stack gets its own resizing glass container. ---------------
    summary_y = content_bottom + content_height - summary_height
    pills_top_y = summary_y - section_gap
    pills_bottom_y = (
        pills_top_y - pill_count * pill_height - max(0, pill_count - 1) * pill_gap
    )

    container_origin_y = pills_bottom_y
    if LIQUID_GLASS_CONTAINER_AVAILABLE:
        # Keep the TLDR outside the resizing suggestion stack. The container is
        # only for the pills, so expansion can add space below the summary
        # without making the TLDR participate in the glass-stack relayout.
        container_height_initial = pills_top_y - pills_bottom_y
        container_origin_y = pills_bottom_y - SHADOW_BLEED
        container_frame_bg = Foundation.NSMakeRect(
            0,
            container_origin_y,
            panel_width,
            container_height_initial + (SHADOW_BLEED * 2.0),
        )
        pill_container = _GLASS_CONTAINER_CLASS.alloc().initWithFrame_(container_frame_bg)
        pill_container.setSpacing_(BLOB_MERGE_SPACING)
        pill_container.setWantsLayer_(True)
        _suppress_glass_outline(pill_container)
        pill_container.setAlphaValue_(0.0)
        background.addSubview_(pill_container)
        use_container = True
    else:
        pill_container = None
        container_frame_bg = None
        container_height_initial = 0.0
        use_container = False

    # --- summary card ---------------------------------------------------
    summary_frame = Foundation.NSMakeRect(content_x, summary_y, width, summary_height)
    summary_glass, summary_content = make_glass_pane(
        summary_frame,
        corner_radius=24.0,
    )
    summary_glass.setAlphaValue_(0.0)
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
    pill_parent = pill_container if use_container else background

    # Pills start stacked at the top of their own container, just under the
    # TLDR. They fan downward from there, while the summary stays outside the
    # resizing stack.
    if use_container:
        blob_start_local_y = pills_top_y - container_origin_y - pill_height
    else:
        blob_start_local_y = 0.0

    y = pills_top_y
    pills: list[AppKit.NSView] = []
    pill_contents: list[AppKit.NSView] = []
    numbers: list[AppKit.NSTextField] = []
    labels: list[AppKit.NSTextField] = []
    suggestion_texts: list[str] = []
    collapsed_label_texts: list[str] = []
    collapsed_frames: list[Foundation.NSRect] = []
    expanded_frames: list[Foundation.NSRect] = []

    for loop_i, (index, text) in enumerate(enumerate(suggestions, start=1)):
        y -= pill_height
        exp_height = max(
            pill_height,
            _measure_text_height(text, width - 92, suggestion_font, LAB_SUGGESTION_LINE_SPACING)
            + (LAB_SUGGESTION_VERTICAL_PADDING * 2),
        )
        exp_delta = exp_height - pill_height

        if use_container:
            local_y = y - container_origin_y
            collapsed_frame = Foundation.NSMakeRect(content_x, local_y, width, pill_height)
            expanded_frame = Foundation.NSMakeRect(content_x, local_y - exp_delta, width, exp_height)
            # All pills start from the top of the suggestion container.
            initial_frame = Foundation.NSMakeRect(content_x, blob_start_local_y, width, pill_height)
        else:
            collapsed_frame = Foundation.NSMakeRect(content_x, y, width, pill_height)
            expanded_frame = Foundation.NSMakeRect(content_x, y - exp_delta, width, exp_height)
            initial_frame = collapsed_frame

        pill_glass, pill_content = make_glass_pane(
            initial_frame,
            corner_radius=pill_height / 2.0,
        )
        if use_container:
            # Hide the contentView (number + label) until the pill fans into
            # its row. Otherwise stacked labels render on top of each other.
            pill_content.setAlphaValue_(0.0)
        else:
            pill_glass.setAlphaValue_(0.0)
        pill_parent.addSubview_(pill_glass)
        pills.append(pill_glass)
        pill_contents.append(pill_content)
        suggestion_texts.append(text)
        collapsed_frames.append(collapsed_frame)
        expanded_frames.append(expanded_frame)

        number = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(20, (pill_height - LAB_NUMBER_HEIGHT) / 2, 28, LAB_NUMBER_HEIGHT)
        )
        number.setEditable_(False)
        number.setSelectable_(False)
        number.setBezeled_(False)
        number.setDrawsBackground_(False)
        number.setStringValue_(str(index))
        number.setFont_(number_font)
        number.setTextColor_(AppKit.NSColor.secondaryLabelColor())
        number.setAlignment_(AppKit.NSTextAlignmentCenter)
        number.setLineBreakMode_(AppKit.NSLineBreakByClipping)
        number.setUsesSingleLineMode_(True)
        pill_content.addSubview_(number)
        numbers.append(number)

        label = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(68, (pill_height - LAB_COLLAPSED_TEXT_HEIGHT) / 2, width - 92, LAB_COLLAPSED_TEXT_HEIGHT)
        )
        label_width = width - 92
        collapsed_text = _collapsed_single_line_text(text, label_width, suggestion_font)
        label.setEditable_(False)
        label.setSelectable_(False)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        label.setStringValue_(collapsed_text)
        label.setFont_(suggestion_font)
        label.setTextColor_(AppKit.NSColor.labelColor())
        label.setLineBreakMode_(AppKit.NSLineBreakByClipping)
        label.setUsesSingleLineMode_(True)
        pill_content.addSubview_(label)
        labels.append(label)
        collapsed_label_texts.append(collapsed_text)

        if index < pill_count:
            y -= pill_gap

    # --- footer hint (no card; floats over whatever is behind) ---------
    hint = AppKit.NSTextField.alloc().initWithFrame_(
        Foundation.NSMakeRect(content_x, content_bottom, width, hint_height)
    )
    hint.setEditable_(False)
    hint.setSelectable_(False)
    hint.setBezeled_(False)
    hint.setDrawsBackground_(False)
    hint.setStringValue_("Press 1 / 2 / 3 to expand · repeat in the app to copy · Esc to dismiss")
    hint.setFont_(AppKit.NSFont.systemFontOfSize_(12.0))
    hint.setTextColor_(AppKit.NSColor.tertiaryLabelColor())
    hint.setAlignment_(AppKit.NSTextAlignmentCenter)
    hint.setAlphaValue_(0.0)
    background.addSubview_(hint)

    panel.configureExpansion(
        background,
        pills,
        numbers,
        labels,
        suggestion_texts,
        collapsed_label_texts,
        collapsed_frames,
        expanded_frames,
        summary_frame,
        hint.frame(),
        pill_container=pill_container,
        base_container_frame=container_frame_bg,
        summary_view=summary_glass,
        hint_view=hint,
        pill_contents=pill_contents,
    )

    # --- Entrance animation ---
    def _lab_ease_out_fade(view: AppKit.NSView) -> None:
        NSAnimationContext = AppKit.NSAnimationContext
        NSAnimationContext.beginGrouping()
        try:
            ctx = NSAnimationContext.currentContext()
            ctx.setDuration_(ENTRANCE_DURATION)
            ctx.setTimingFunction_(
                Quartz.CAMediaTimingFunction.functionWithName_(Quartz.kCAMediaTimingFunctionEaseOut)
            )
            view.animator().setAlphaValue_(1.0)
        finally:
            NSAnimationContext.endGrouping()

    if use_container:
        # t=0: the summary, pill container, and hint fade in together.
        def _materialize(_t: Any, _pc: AppKit.NSView = pill_container, _h: AppKit.NSView = hint) -> None:
            _lab_ease_out_fade(summary_glass)
            _lab_ease_out_fade(_pc)
            _lab_ease_out_fade(_h)

        mat_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            0.0, False, _materialize
        )
        panel._register_timer(mat_timer)

        # Sequential cascade: pill 0 drops from the top of the stack, then
        # each later pill emerges from the previous pill's final position and
        # drops to its own. Linear timing keeps the speed constant.
        prev_local_y = blob_start_local_y
        cumulative_delay = ENTRANCE_DURATION + BLOB_MATERIALIZE_DELAY
        for fanout_i in range(len(pills)):
            final_local_y = collapsed_frames[fanout_i].origin.y
            pill_to_move = pills[fanout_i]
            content_to_reveal = pill_contents[fanout_i]
            teleport_y = None if fanout_i == 0 else prev_local_y

            def _make_fanout(
                p: AppKit.NSView = pill_to_move,
                fy: float = final_local_y,
                c: AppKit.NSView = content_to_reveal,
                tele_y: float | None = teleport_y,
                w: float = width,
                ph: float = pill_height,
                px: float = content_x,
            ) -> Any:
                def _do_fanout(_t: Any) -> None:
                    if tele_y is not None:
                        p.setFrame_(Foundation.NSMakeRect(px, tele_y, w, ph))
                    NSAnimationContext = AppKit.NSAnimationContext
                    NSAnimationContext.beginGrouping()
                    try:
                        ctx = NSAnimationContext.currentContext()
                        ctx.setDuration_(BLOB_FANOUT_DURATION)
                        ctx.setTimingFunction_(
                            Quartz.CAMediaTimingFunction.functionWithName_(Quartz.kCAMediaTimingFunctionLinear)
                        )
                        p.animator().setFrame_(Foundation.NSMakeRect(px, fy, w, ph))
                        c.animator().setAlphaValue_(1.0)
                    finally:
                        NSAnimationContext.endGrouping()
                return _do_fanout

            fanout_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
                cumulative_delay, False, _make_fanout()
            )
            panel._register_timer(fanout_timer)
            cumulative_delay += BLOB_FANOUT_DURATION
            prev_local_y = final_local_y
    else:
        # Fallback: fade summary and hint, stagger pills individually.
        sum_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            0.0, False, lambda _t, _sg=summary_glass: _lab_ease_out_fade(_sg)
        )
        panel._register_timer(sum_timer)

        for stagger_i, pill in enumerate(pills):
            pill_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
                ENTRANCE_STAGGER * stagger_i,
                False,
                lambda _t, _p=pill: _lab_ease_out_fade(_p),
            )
            panel._register_timer(pill_timer)

        footer_delay = ENTRANCE_STAGGER * len(pills) + ENTRANCE_FOOTER_DELAY_PADDING
        hint_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            footer_delay, False, lambda _t, _h=hint: _lab_ease_out_fade(_h)
        )
        panel._register_timer(hint_timer)

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
    parser.add_argument(
        "--time-scale",
        type=float,
        default=1.0,
        help="Multiplier for all animation durations and delays. e.g. 5 = 5x slower (great for inspecting the blob morph), 0.5 = 2x faster.",
    )
    parser.add_argument(
        "--slow",
        action="store_true",
        help="Shortcut for --time-scale 6.",
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

    time_scale = args.time_scale
    if args.slow and time_scale == 1.0:
        time_scale = 6.0
    if time_scale != 1.0:
        global ENTRANCE_DURATION, ENTRANCE_STAGGER, ENTRANCE_FOOTER_DELAY_PADDING
        global EXPAND_DURATION, BLOB_MATERIALIZE_DELAY, BLOB_FANOUT_DURATION, BLOB_FANOUT_STAGGER
        ENTRANCE_DURATION *= time_scale
        ENTRANCE_STAGGER *= time_scale
        ENTRANCE_FOOTER_DELAY_PADDING *= time_scale
        EXPAND_DURATION *= time_scale
        BLOB_MATERIALIZE_DELAY *= time_scale
        BLOB_FANOUT_DURATION *= time_scale
        BLOB_FANOUT_STAGGER *= time_scale
        print(f"animations scaled to {time_scale}x", file=sys.stderr)

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
