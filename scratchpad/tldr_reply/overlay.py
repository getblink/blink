from __future__ import annotations

import math
from typing import Any

import AppKit
import Foundation
import Quartz
import objc


PANEL_WIDTH = 560.0
PANEL_SHADOW_BLEED = 36.0
SUMMARY_MIN_HEIGHT = 132.0
SECTION_GAP = 14.0
SUGGESTION_GAP = 8.0
TLDR_FONT_SIZE = 16.5
SUGGESTION_FONT_SIZE = 16.0
HINT_FONT_SIZE = 12.0
HINT_HEIGHT = 18.0
HINT_INSET_BOTTOM = 16.0
HINT_TO_TEXT_GAP = 12.0
TLDR_TOP_INSET = 22.0
TLDR_LINE_SPACING = 5.0
SUGGESTION_COLLAPSED_HEIGHT = 62.0
SUGGESTION_LINE_SPACING = 5.0
SUGGESTION_PADDING_X = 24.0
SUGGESTION_NUMBER_X = 20.0
SUGGESTION_NUMBER_WIDTH = 28.0
SUGGESTION_NUMBER_HEIGHT = 24.0
SUGGESTION_TEXT_X = 68.0
SUGGESTION_COLLAPSED_TEXT_HEIGHT = 24.0
# Match the natural top/bottom gap of the collapsed pill so the first line of
# text stays at the same screen position when the pill expands downward.
SUGGESTION_PADDING_Y = (SUGGESTION_COLLAPSED_HEIGHT - SUGGESTION_COLLAPSED_TEXT_HEIGHT) / 2.0

# Per-card "↵ Enter to insert" affordance. Shown only on the highlighted
# card. Sits at the bottom-right of the pill in a footer strip that's
# kept clear of the body text by SUGGESTION_BOTTOM_PADDING_EXPANDED.
ENTER_HINT_TEXT = "⏎ Enter to insert"
ENTER_HINT_FONT_SIZE = 12.0
ENTER_HINT_WIDTH = 140.0
ENTER_HINT_HEIGHT = 18.0
ENTER_HINT_RIGHT_INSET = 24.0
ENTER_HINT_BOTTOM_INSET = 4.0
# Multi-line cards grow their bottom padding so wrapped text doesn't
# crowd the hint footer. Top padding stays at SUGGESTION_PADDING_Y.
SUGGESTION_BOTTOM_PADDING_EXPANDED = 28.0

EXPAND_DURATION = 0.22


# Match the UI lab's Liquid Glass feature gating. macOS versions before the
# glass APIs fall back to NSVisualEffectView without changing call sites.
_GLASS_CLASS = getattr(AppKit, "NSGlassEffectView", None)
LIQUID_GLASS_AVAILABLE = _GLASS_CLASS is not None
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


def _timing_function(name: str) -> Any:
    return Quartz.CAMediaTimingFunction.functionWithName_(name)


def _color_to_cgcolor(color: AppKit.NSColor) -> Any:
    components = color.colorUsingColorSpace_(AppKit.NSColorSpace.sRGBColorSpace())
    if components is None:
        components = color
    return Quartz.CGColorCreateGenericRGB(
        components.redComponent(),
        components.greenComponent(),
        components.blueComponent(),
        components.alphaComponent(),
    )


class ReplyPanel(AppKit.NSPanel):
    def canBecomeKeyWindow(self) -> bool:
        return True

    def canBecomeMainWindow(self) -> bool:
        return True

    def keyDown_(self, event: Any) -> None:
        objc.super(ReplyPanel, self).keyDown_(event)

    def animationResizeTime_(self, frame: Foundation.NSRect) -> float:
        # Defensive fallback if a future path animates panel resizing again.
        # The current expansion path sets the panel frame synchronously so the
        # TLDR can be pinned before suggestion rows animate downward.
        return EXPAND_DURATION

    @objc.python_method
    def configure_expansion(
        self,
        background: AppKit.NSView,
        option_cards: list[AppKit.NSView],
        option_contents: list[AppKit.NSView],
        option_tints: list[AppKit.NSView],
        option_numbers: list[AppKit.NSTextField],
        option_labels: list[AppKit.NSTextField],
        option_enter_hints: list[AppKit.NSTextField],
        option_texts: list[str],
        option_collapsed_texts: list[str],
        collapsed_frames: list[Foundation.NSRect],
        expanded_frames: list[Foundation.NSRect],
    ) -> None:
        self._background = background
        self._option_cards = option_cards
        self._option_contents = option_contents
        self._option_tints = option_tints
        self._option_numbers = option_numbers
        self._option_labels = option_labels
        self._option_enter_hints = option_enter_hints
        self._option_texts = option_texts
        self._option_collapsed_texts = option_collapsed_texts
        self._collapsed_frames = collapsed_frames
        self._expanded_frames = expanded_frames
        card_index_by_id = {id(card): i for i, card in enumerate(option_cards)}
        self._base_subview_frames = []
        for subview in background.subviews():
            card_index = card_index_by_id.get(id(subview))
            if card_index is not None:
                self._base_subview_frames.append((subview, collapsed_frames[card_index]))
            else:
                self._base_subview_frames.append((subview, subview.frame()))
        panel_frame = self.frame()
        self._base_panel_height = float(panel_frame.size.height)
        self._base_panel_origin_y = float(panel_frame.origin.y)
        self._base_panel_top_y = (
            self._base_panel_origin_y + self._base_panel_height
        )
        self._expanded_index: int | None = None
        self._selected_index: int | None = None
        self._current_height_delta: float = 0.0

    @objc.python_method
    def expanded_suggestion_index(self) -> int | None:
        return getattr(self, "_expanded_index", None)

    @objc.python_method
    def expand_suggestion(self, index: int) -> bool:
        option_cards = getattr(self, "_option_cards", [])
        if index < 0 or index >= len(option_cards):
            return False

        expanded_frames = self._expanded_frames
        collapsed_frames = self._collapsed_frames
        height_delta = (
            expanded_frames[index].size.height - collapsed_frames[index].size.height
        )
        old_height_delta = float(getattr(self, "_current_height_delta", 0.0))
        # Synchronously, the panel grows downward (top edge pinned). Going
        # from a state with old_height_delta to one with height_delta drops
        # panel.origin.y by this much in screen coords. Cards in panel-local
        # coords would visually jump down by the same amount, then animate
        # back up — that's the flicker. Compensate by adding panel_drop to
        # each card's local origin synchronously so its screen position is
        # preserved through the resize; the animator below then transitions
        # to the final target_y.
        panel_drop = height_delta - old_height_delta
        target_height = self._base_panel_height + height_delta
        target_origin_y = self._base_panel_top_y - target_height
        frame = self.frame()
        new_frame = Foundation.NSMakeRect(
            frame.origin.x,
            target_origin_y,
            frame.size.width,
            target_height,
        )

        # Compute per-card geometry before the animation group so text/mode
        # swaps are synchronous and the label reflows into its final size
        # during the animated frame interpolation.
        card_id_set = {id(c) for c in option_cards}
        card_geometries = []
        for card_index, card in enumerate(option_cards):
            source_frame = collapsed_frames[card_index]
            # A target card only needs to grow when its expanded frame is
            # actually taller than its collapsed frame. Single-line
            # suggestions match the collapsed pill exactly, so render them
            # with the collapsed layout to avoid a no-op label re-attribute
            # and number-position shift on first press.
            needs_growth = (
                card_index == index
                and expanded_frames[card_index].size.height
                > source_frame.size.height
            )
            card_height = (
                expanded_frames[card_index].size.height
                if needs_growth
                else source_frame.size.height
            )
            card_y = source_frame.origin.y + (
                height_delta if card_index < index else 0.0
            )
            label = self._option_labels[card_index]
            label.setLineBreakMode_(
                AppKit.NSLineBreakByWordWrapping
                if needs_growth
                else AppKit.NSLineBreakByClipping
            )
            label.setUsesSingleLineMode_(not needs_growth)
            number = self._option_numbers[card_index]
            text_width = source_frame.size.width - SUGGESTION_TEXT_X - SUGGESTION_PADDING_X
            label_text = self._option_texts[card_index]
            label_font = AppKit.NSFont.systemFontOfSize_(SUGGESTION_FONT_SIZE)
            if needs_growth:
                _set_label_text(
                    label,
                    label_text,
                    label_font,
                    AppKit.NSColor.labelColor(),
                    SUGGESTION_LINE_SPACING,
                )
                label_height = _measure_height(label_text, text_width, label_font, SUGGESTION_LINE_SPACING)
                # Bottom of card reserves SUGGESTION_BOTTOM_PADDING_EXPANDED
                # for the hint footer; the label sits above it. Top padding
                # comes out as SUGGESTION_PADDING_Y because the card's height
                # is sized to label_height + top + bottom padding.
                label_y = SUGGESTION_BOTTOM_PADDING_EXPANDED
                number_y = label_y + label_height - SUGGESTION_NUMBER_HEIGHT
            else:
                label.setStringValue_(self._option_collapsed_texts[card_index])
                label.setFont_(label_font)
                label.setTextColor_(AppKit.NSColor.labelColor())
                label_height = SUGGESTION_COLLAPSED_TEXT_HEIGHT
                label_y = (card_height - label_height) / 2.0
                number_y = (card_height - SUGGESTION_NUMBER_HEIGHT) / 2.0
            card_geometries.append((
                card,
                source_frame,
                card_y,
                card_height,
                label,
                text_width,
                label_y,
                label_height,
                number,
                number_y,
            ))

        self.setFrame_display_(new_frame, True)
        self._background.setFrame_(
            Foundation.NSMakeRect(0, 0, new_frame.size.width, target_height)
        )

        for subview, base_frame in self._base_subview_frames:
            sid = id(subview)
            if sid in card_id_set:
                continue
            subview.setFrameOrigin_(
                Foundation.NSMakePoint(
                    base_frame.origin.x,
                    base_frame.origin.y + height_delta,
                )
            )

        # Pin each card's on-screen position through the synchronous panel
        # resize (see comment near panel_drop above). Without this, going
        # from a 1-line selection to a multi-line one would briefly drop the
        # top card before the animator pulled it back up.
        if panel_drop != 0.0:
            for card in option_cards:
                current = card.frame()
                card.setFrameOrigin_(
                    Foundation.NSMakePoint(
                        current.origin.x,
                        current.origin.y + panel_drop,
                    )
                )

        # Toggle the light-blue selection wash synchronously: the previous
        # selection's tint clears and the new one's appears immediately, while
        # the card frame change still animates below.
        for tint_index, tint in enumerate(getattr(self, "_option_tints", [])):
            tint.setAlphaValue_(1.0 if tint_index == index else 0.0)
        # The "↵ Enter to insert" hint follows the same toggle.
        for hint_index, hint_view in enumerate(getattr(self, "_option_enter_hints", [])):
            hint_view.setAlphaValue_(1.0 if hint_index == index else 0.0)

        AppKit.NSAnimationContext.beginGrouping()
        try:
            ctx = AppKit.NSAnimationContext.currentContext()
            ctx.setDuration_(EXPAND_DURATION)
            ctx.setTimingFunction_(
                _timing_function(Quartz.kCAMediaTimingFunctionEaseInEaseOut)
            )
            enter_hints = getattr(self, "_option_enter_hints", [])
            for ci, (
                card, source_frame, card_y, card_height,
                label, text_width, label_y, label_height,
                number, number_y,
            ) in enumerate(card_geometries):
                corner_radius = source_frame.size.height / 2.0
                _set_corner_radius(card, corner_radius)
                card.animator().setFrame_(
                    Foundation.NSMakeRect(
                        source_frame.origin.x,
                        card_y,
                        source_frame.size.width,
                        card_height,
                    )
                )
                number.animator().setFrame_(
                    Foundation.NSMakeRect(
                        SUGGESTION_NUMBER_X,
                        number_y,
                        SUGGESTION_NUMBER_WIDTH,
                        SUGGESTION_NUMBER_HEIGHT,
                    )
                )
                label.animator().setFrame_(
                    Foundation.NSMakeRect(
                        SUGGESTION_TEXT_X,
                        label_y,
                        text_width,
                        label_height,
                    )
                )
                if ci < len(enter_hints):
                    enter_hints[ci].animator().setFrame_(
                        Foundation.NSMakeRect(
                            source_frame.size.width
                            - ENTER_HINT_RIGHT_INSET
                            - ENTER_HINT_WIDTH,
                            ENTER_HINT_BOTTOM_INSET,
                            ENTER_HINT_WIDTH,
                            ENTER_HINT_HEIGHT,
                        )
                    )
        finally:
            AppKit.NSAnimationContext.endGrouping()

        self._expanded_index = index
        self._selected_index = index
        self._current_height_delta = float(height_delta)
        return True


def _make_label(
    frame: Foundation.NSRect,
    text: str,
    font: AppKit.NSFont,
    color: AppKit.NSColor,
    line_spacing: float = 0.0,
    single_line: bool = False,
) -> AppKit.NSTextField:
    label = AppKit.NSTextField.alloc().initWithFrame_(frame)
    label.setEditable_(False)
    label.setSelectable_(False)
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setLineBreakMode_(
        AppKit.NSLineBreakByTruncatingTail
        if single_line
        else AppKit.NSLineBreakByWordWrapping
    )
    label.setUsesSingleLineMode_(single_line)
    if line_spacing:
        # Encode the line break mode in the paragraph style: the attributed
        # string's paragraph style overrides any label-level setLineBreakMode_.
        paragraph = AppKit.NSMutableParagraphStyle.alloc().init()
        paragraph.setLineBreakMode_(
            AppKit.NSLineBreakByTruncatingTail
            if single_line
            else AppKit.NSLineBreakByWordWrapping
        )
        paragraph.setLineSpacing_(line_spacing)
        attributed = Foundation.NSAttributedString.alloc().initWithString_attributes_(
            text,
            {
                AppKit.NSFontAttributeName: font,
                AppKit.NSForegroundColorAttributeName: color,
                AppKit.NSParagraphStyleAttributeName: paragraph,
            },
        )
        label.setAttributedStringValue_(attributed)
    else:
        label.setStringValue_(text)
        label.setFont_(font)
        label.setTextColor_(color)
    return label


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


def _measure_height(
    text: str,
    width: float,
    font: AppKit.NSFont,
    line_spacing: float = 0.0,
) -> float:
    # Measure with the same cell that NSTextField uses to draw, so the
    # height we reserve matches what actually renders. boundingRectWithSize
    # tends to underestimate slightly (per Apple's docs and the objc.io
    # string-rendering writeup); cellSizeForBounds is the renderer-of-record.
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


def _measure_width(text: str, font: AppKit.NSFont) -> float:
    string = Foundation.NSString.stringWithString_(text)
    size = string.sizeWithAttributes_({AppKit.NSFontAttributeName: font})
    return float(size.width)


def _collapsed_single_line_text(text: str, width: float, font: AppKit.NSFont) -> str:
    if _measure_width(text, font) <= width:
        return text
    suffix = "..."
    available = max(0.0, width - _measure_width(suffix, font))
    low = 0
    high = len(text)
    best = ""
    while low <= high:
        mid = (low + high) // 2
        candidate = text[:mid].rstrip()
        if _measure_width(candidate, font) <= available:
            best = candidate
            low = mid + 1
        else:
            high = mid - 1
    return f"{best}{suffix}" if best else suffix


def _make_glass_pane(
    frame: Foundation.NSRect,
    corner_radius: float = 22.0,
    tint_color: AppKit.NSColor | None = None,
) -> tuple[AppKit.NSView, AppKit.NSView]:
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


def _set_corner_radius(view: AppKit.NSView, radius: float) -> None:
    if hasattr(view, "setCornerRadius_"):
        view.setCornerRadius_(radius)
        return
    layer = view.layer()
    if layer is not None:
        layer.setCornerRadius_(radius)


def _make_suggestion_card(
    frame: Foundation.NSRect,
    index: int,
    text: str,
    collapsed_text: str,
    font: AppKit.NSFont,
) -> tuple[
    AppKit.NSView,
    AppKit.NSView,
    AppKit.NSView,
    AppKit.NSTextField,
    AppKit.NSTextField,
    AppKit.NSTextField,
]:
    corner_radius = frame.size.height / 2.0
    card, content = _make_glass_pane(
        frame,
        corner_radius=corner_radius,
    )

    # Light-blue selection wash. Sits behind number/label so text stays
    # legible. Autoresizes with the card so it tracks during the expand
    # animation. The tint owns its own rounded clip matching the card's
    # corner radius — without it, the rectangular layer draws past the
    # glass pill's rounded corners. Hidden until the card is the active
    # selection.
    tint = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, frame.size.width, frame.size.height)
    )
    tint.setWantsLayer_(True)
    tint.layer().setCornerRadius_(corner_radius)
    tint.layer().setMasksToBounds_(True)
    tint.layer().setBackgroundColor_(
        _color_to_cgcolor(
            AppKit.NSColor.systemBlueColor().colorWithAlphaComponent_(0.22)
        )
    )
    tint.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
    )
    tint.setAlphaValue_(0.0)
    content.addSubview_(tint)

    number = _make_label(
        Foundation.NSMakeRect(
            SUGGESTION_NUMBER_X,
            (frame.size.height - SUGGESTION_NUMBER_HEIGHT) / 2.0,
            SUGGESTION_NUMBER_WIDTH,
            SUGGESTION_NUMBER_HEIGHT,
        ),
        str(index),
        AppKit.NSFont.systemFontOfSize_weight_(
            SUGGESTION_FONT_SIZE,
            AppKit.NSFontWeightSemibold,
        ),
        AppKit.NSColor.secondaryLabelColor(),
        single_line=True,
    )
    number.setAlignment_(AppKit.NSTextAlignmentCenter)
    content.addSubview_(number)

    text_width = frame.size.width - SUGGESTION_TEXT_X - SUGGESTION_PADDING_X
    label = _make_label(
        Foundation.NSMakeRect(
            SUGGESTION_TEXT_X,
            (frame.size.height - SUGGESTION_COLLAPSED_TEXT_HEIGHT) / 2.0,
            text_width,
            SUGGESTION_COLLAPSED_TEXT_HEIGHT,
        ),
        collapsed_text,
        font,
        AppKit.NSColor.labelColor(),
        single_line=True,
    )
    label.setLineBreakMode_(AppKit.NSLineBreakByClipping)
    content.addSubview_(label)

    enter_hint = _make_label(
        Foundation.NSMakeRect(
            frame.size.width - ENTER_HINT_RIGHT_INSET - ENTER_HINT_WIDTH,
            ENTER_HINT_BOTTOM_INSET,
            ENTER_HINT_WIDTH,
            ENTER_HINT_HEIGHT,
        ),
        ENTER_HINT_TEXT,
        AppKit.NSFont.systemFontOfSize_(ENTER_HINT_FONT_SIZE),
        AppKit.NSColor.secondaryLabelColor(),
        single_line=True,
    )
    enter_hint.setAlignment_(AppKit.NSTextAlignmentRight)
    enter_hint.setAlphaValue_(0.0)
    enter_hint.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    content.addSubview_(enter_hint)
    return card, content, tint, number, label, enter_hint


def show_result_panel(
    tldr: str,
    suggestions: list[str],
) -> ReplyPanel:
    display_suggestions = suggestions[:3] or ["No usable suggestion returned."]
    content_width = PANEL_WIDTH
    summary_font = AppKit.NSFont.systemFontOfSize_weight_(
        TLDR_FONT_SIZE,
        AppKit.NSFontWeightSemibold,
    )
    suggestion_font = AppKit.NSFont.systemFontOfSize_(SUGGESTION_FONT_SIZE)
    hint_font = AppKit.NSFont.systemFontOfSize_(HINT_FONT_SIZE)
    suggestion_padding_x = SUGGESTION_PADDING_X
    suggestion_padding_y = SUGGESTION_PADDING_Y
    suggestion_label_width = content_width - SUGGESTION_TEXT_X - suggestion_padding_x

    summary_label_width = content_width - 48.0
    tldr_text_y = HINT_INSET_BOTTOM + HINT_HEIGHT + HINT_TO_TEXT_GAP
    summary_height = max(
        SUMMARY_MIN_HEIGHT,
        _measure_height(
            tldr,
            summary_label_width,
            summary_font,
            TLDR_LINE_SPACING,
        )
        + tldr_text_y
        + TLDR_TOP_INSET,
    )
    row_heights = [SUGGESTION_COLLAPSED_HEIGHT for _ in display_suggestions]
    expanded_row_heights = [
        max(
            SUGGESTION_COLLAPSED_HEIGHT,
            _measure_height(
                text,
                suggestion_label_width,
                suggestion_font,
                SUGGESTION_LINE_SPACING,
            )
            + suggestion_padding_y
            + SUGGESTION_BOTTOM_PADDING_EXPANDED,
        )
        for text in display_suggestions
    ]
    stack_height = (
        sum(row_heights)
        + (SUGGESTION_GAP * max(0, len(row_heights) - 1))
    )
    content_height = summary_height + SECTION_GAP + stack_height
    panel_width = PANEL_WIDTH + (PANEL_SHADOW_BLEED * 2.0)
    panel_height = content_height + (PANEL_SHADOW_BLEED * 2.0)
    content_x = PANEL_SHADOW_BLEED
    content_bottom = PANEL_SHADOW_BLEED

    screen_frame = AppKit.NSScreen.mainScreen().frame()
    origin_x = screen_frame.origin.x + (screen_frame.size.width - panel_width) / 2
    origin_y = screen_frame.origin.y + (screen_frame.size.height - panel_height) / 2
    panel_frame = Foundation.NSMakeRect(origin_x, origin_y, panel_width, panel_height)

    # Borderless (no NSWindowStyleMaskNonactivatingPanel) plus a Regular
    # activation policy on the app side avoids the AppKit-drawn glass outline
    # that appears around NSGlassEffectView/NSGlassEffectContainerView in a
    # non-activating accessory context.
    panel = ReplyPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        panel_frame,
        AppKit.NSWindowStyleMaskBorderless,
        AppKit.NSBackingStoreBuffered,
        False,
    )
    panel.setLevel_(AppKit.NSStatusWindowLevel)
    panel.setHidesOnDeactivate_(False)
    panel.setReleasedWhenClosed_(False)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(AppKit.NSColor.clearColor())

    background = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, panel_width, panel_height)
    )
    background.setWantsLayer_(True)
    background.layer().setBackgroundColor_(Quartz.CGColorCreateGenericRGB(0, 0, 0, 0))
    panel.setContentView_(background)

    summary_y = content_bottom + content_height - summary_height
    stack_top_y = summary_y - SECTION_GAP

    tldr_card, tldr_content = _make_glass_pane(
        Foundation.NSMakeRect(content_x, summary_y, content_width, summary_height),
        corner_radius=24.0,
    )

    hint = _make_label(
        Foundation.NSMakeRect(
            24.0,
            HINT_INSET_BOTTOM,
            content_width - 48.0,
            HINT_HEIGHT,
        ),
        "Press 1 / 2 / 3 to expand · repeat in the app to copy · Esc to dismiss",
        hint_font,
        AppKit.NSColor.tertiaryLabelColor(),
        single_line=True,
    )
    hint.setAlignment_(AppKit.NSTextAlignmentCenter)
    tldr_content.addSubview_(hint)

    tldr_label = _make_label(
        Foundation.NSMakeRect(
            24.0,
            tldr_text_y,
            content_width - 48.0,
            summary_height - tldr_text_y - TLDR_TOP_INSET,
        ),
        tldr,
        summary_font,
        AppKit.NSColor.labelColor(),
        TLDR_LINE_SPACING,
    )
    tldr_content.addSubview_(tldr_label)
    background.addSubview_(tldr_card)

    option_cards: list[AppKit.NSView] = []
    option_contents: list[AppKit.NSView] = []
    option_tints: list[AppKit.NSView] = []
    option_numbers: list[AppKit.NSTextField] = []
    option_labels: list[AppKit.NSTextField] = []
    option_enter_hints: list[AppKit.NSTextField] = []
    option_texts: list[str] = []
    option_collapsed_texts: list[str] = []
    collapsed_frames: list[Foundation.NSRect] = []
    expanded_frames: list[Foundation.NSRect] = []

    y = stack_top_y
    for index, text in enumerate(display_suggestions, start=1):
        row_height = row_heights[index - 1]
        y -= row_height
        row_y = y
        final_frame = Foundation.NSMakeRect(
            content_x,
            row_y,
            content_width,
            row_height,
        )
        expanded_frame = Foundation.NSMakeRect(
            content_x,
            row_y - (expanded_row_heights[index - 1] - row_height),
            content_width,
            expanded_row_heights[index - 1],
        )
        collapsed_text = _collapsed_single_line_text(
            text,
            suggestion_label_width,
            suggestion_font,
        )
        card, content, tint, number, label, enter_hint = _make_suggestion_card(
            final_frame,
            index,
            text,
            collapsed_text,
            suggestion_font,
        )
        background.addSubview_(card)
        option_cards.append(card)
        option_contents.append(content)
        option_tints.append(tint)
        option_numbers.append(number)
        option_labels.append(label)
        option_enter_hints.append(enter_hint)
        option_texts.append(text)
        option_collapsed_texts.append(collapsed_text)
        collapsed_frames.append(final_frame)
        expanded_frames.append(expanded_frame)
        if index < len(display_suggestions):
            y -= SUGGESTION_GAP

    panel.configure_expansion(
        background,
        option_cards,
        option_contents,
        option_tints,
        option_numbers,
        option_labels,
        option_enter_hints,
        option_texts,
        option_collapsed_texts,
        collapsed_frames,
        expanded_frames,
    )

    AppKit.NSApp.activateIgnoringOtherApps_(True)
    panel.makeKeyAndOrderFront_(None)
    return panel
