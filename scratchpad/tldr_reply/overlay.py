from __future__ import annotations

import math
from typing import Any

import AppKit
import Foundation
import Quartz
import objc


PANEL_WIDTH = 620.0
CARD_PADDING_X = 20.0
CARD_PADDING_Y = 16.0
CARD_GAP = 10.0
FOOTER_HEIGHT = 32.0
FOOTER_PILL_GAP = 8.0
TLDR_FONT_SIZE = 17.0
SUGGESTION_FONT_SIZE = 16.5
FOOTER_FONT_SIZE = 13.5
TLDR_LINE_SPACING = 5.0
SUGGESTION_COLLAPSED_HEIGHT = 58.0
SUGGESTION_LINE_SPACING = 5.0
SUGGESTION_PADDING_X = 20.0
SUGGESTION_NUMBER_X = 22.0
SUGGESTION_NUMBER_WIDTH = 26.0
SUGGESTION_NUMBER_HEIGHT = 24.0
SUGGESTION_TEXT_X = 66.0
SUGGESTION_COLLAPSED_TEXT_HEIGHT = 24.0
# Match the natural top/bottom gap of the collapsed pill so the first line of
# text stays at the same screen position when the pill expands downward.
SUGGESTION_PADDING_Y = (SUGGESTION_COLLAPSED_HEIGHT - SUGGESTION_COLLAPSED_TEXT_HEIGHT) / 2.0

ENTRANCE_DURATION = 0.18
ENTRANCE_STAGGER = 0.035
ENTRANCE_FOOTER_DELAY_PADDING = 0.04
EXPAND_DURATION = 0.22


def _color(red: float, green: float, blue: float, alpha: float) -> AppKit.NSColor:
    return AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
        red, green, blue, alpha
    )


DARK_TEXT = _color(0.94, 0.94, 0.96, 0.98)
DARK_SECONDARY_TEXT = _color(0.86, 0.86, 0.90, 0.92)
LIGHT_TEXT = _color(0.08, 0.09, 0.11, 0.94)
LIGHT_SECONDARY_TEXT = _color(0.18, 0.19, 0.22, 0.84)
SUMMARY_TINT = Quartz.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.44)
SUGGESTION_TINT = Quartz.CGColorCreateGenericRGB(1.0, 1.0, 1.0, 0.34)
PILL_TINT = Quartz.CGColorCreateGenericRGB(1.0, 1.0, 1.0, 0.42)
DARK_GLASS_APPEARANCE = AppKit.NSAppearance.appearanceNamed_(
    "NSAppearanceNameVibrantDark"
)
LIGHT_GLASS_APPEARANCE = AppKit.NSAppearance.appearanceNamed_(
    "NSAppearanceNameVibrantLight"
)


class ReplyPanel(AppKit.NSPanel):
    def canBecomeKeyWindow(self) -> bool:
        return False

    def canBecomeMainWindow(self) -> bool:
        return False

    def keyDown_(self, event: Any) -> None:
        objc.super(ReplyPanel, self).keyDown_(event)

    @objc.python_method
    def configure_expansion(
        self,
        background: AppKit.NSView,
        option_cards: list[AppKit.NSView],
        option_tints: list[AppKit.NSView],
        option_numbers: list[AppKit.NSTextField],
        option_labels: list[AppKit.NSTextField],
        option_texts: list[str],
        option_collapsed_texts: list[str],
        collapsed_frames: list[Foundation.NSRect],
        expanded_frames: list[Foundation.NSRect],
        footer_views: list[AppKit.NSView],
    ) -> None:
        self._background = background
        self._option_cards = option_cards
        self._option_tints = option_tints
        self._option_numbers = option_numbers
        self._option_labels = option_labels
        self._option_texts = option_texts
        self._option_collapsed_texts = option_collapsed_texts
        self._collapsed_frames = collapsed_frames
        self._expanded_frames = expanded_frames
        self._footer_views = footer_views
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
        self._show_timers: list[Any] = []
        self._expanded_index: int | None = None

    @objc.python_method
    def register_show_timer(self, timer: Any) -> None:
        timers = getattr(self, "_show_timers", None)
        if timers is None:
            self._show_timers = [timer]
        else:
            timers.append(timer)

    @objc.python_method
    def invalidate_show_timers(self) -> None:
        for timer in getattr(self, "_show_timers", []):
            try:
                timer.invalidate()
            except Exception:
                pass
        self._show_timers = []

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
        target_height = self._base_panel_height + height_delta
        target_origin_y = self._base_panel_top_y - target_height

        self.invalidate_show_timers()
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
        footer_id_set = {id(v) for v in self._footer_views}
        card_geometries = []
        for card_index, card in enumerate(option_cards):
            source_frame = collapsed_frames[card_index]
            is_expanded = card_index == index
            card_height = (
                expanded_frames[card_index].size.height
                if is_expanded
                else source_frame.size.height
            )
            card_y = source_frame.origin.y + (
                height_delta if card_index < index else 0.0
            )
            label = self._option_labels[card_index]
            label.setLineBreakMode_(
                AppKit.NSLineBreakByWordWrapping
                if is_expanded
                else AppKit.NSLineBreakByClipping
            )
            label.setUsesSingleLineMode_(not is_expanded)
            number = self._option_numbers[card_index]
            text_width = source_frame.size.width - SUGGESTION_TEXT_X - SUGGESTION_PADDING_X
            label_text = self._option_texts[card_index]
            label_font = AppKit.NSFont.systemFontOfSize_(SUGGESTION_FONT_SIZE)
            if is_expanded:
                _set_label_text(label, label_text, label_font, LIGHT_TEXT, SUGGESTION_LINE_SPACING)
                label_height = _measure_height(label_text, text_width, label_font, SUGGESTION_LINE_SPACING)
                label_y = SUGGESTION_PADDING_Y
                number_y = label_y + label_height - SUGGESTION_NUMBER_HEIGHT
            else:
                label.setStringValue_(self._option_collapsed_texts[card_index])
                label.setFont_(label_font)
                label.setTextColor_(LIGHT_TEXT)
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

        # If entrance timers were cancelled, bring TLDR and footer to full
        # opacity so they aren't invisible during the expansion.
        for subview, _ in self._base_subview_frames:
            if id(subview) not in card_id_set:
                subview.setAlphaValue_(1.0)

        AppKit.NSAnimationContext.beginGrouping()
        try:
            ctx = AppKit.NSAnimationContext.currentContext()
            ctx.setDuration_(EXPAND_DURATION)
            ctx.setTimingFunction_(
                Quartz.CAMediaTimingFunction.functionWithName_(
                    Quartz.kCAMediaTimingFunctionEaseInEaseOut
                )
            )
            self.animator().setFrame_display_(new_frame, True)
            self._background.animator().setFrame_(
                Foundation.NSMakeRect(0, 0, new_frame.size.width, target_height)
            )
            for subview, base_frame in self._base_subview_frames:
                sid = id(subview)
                if sid in card_id_set:
                    continue
                if sid in footer_id_set:
                    subview.animator().setFrameOrigin_(
                        Foundation.NSMakePoint(base_frame.origin.x, 0)
                    )
                else:
                    subview.animator().setFrameOrigin_(
                        Foundation.NSMakePoint(
                            base_frame.origin.x,
                            base_frame.origin.y + height_delta,
                        )
                    )
            for (
                card, source_frame, card_y, card_height,
                label, text_width, label_y, label_height,
                number, number_y,
            ) in card_geometries:
                corner_radius = source_frame.size.height / 2.0
                card.layer().setCornerRadius_(corner_radius)
                tint = self._option_tints[option_cards.index(card)]
                if tint.layer() is not None:
                    tint.layer().setCornerRadius_(corner_radius)
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
        finally:
            AppKit.NSAnimationContext.endGrouping()

        self._expanded_index = index
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


def _make_card(
    frame: Foundation.NSRect,
    text: str,
    font: AppKit.NSFont,
    text_color: AppKit.NSColor,
    material: int,
    padding_x: float = CARD_PADDING_X,
    padding_y: float = CARD_PADDING_Y,
    alignment: int | None = None,
    tint_color: Any = SUMMARY_TINT,
    corner_radius: float = 22.0,
    line_spacing: float = 0.0,
    single_line: bool = False,
    appearance: AppKit.NSAppearance | None = DARK_GLASS_APPEARANCE,
) -> AppKit.NSVisualEffectView:
    card = AppKit.NSVisualEffectView.alloc().initWithFrame_(frame)
    if appearance is not None:
        card.setAppearance_(appearance)
    card.setMaterial_(material)
    card.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
    card.setState_(AppKit.NSVisualEffectStateActive)
    card.setWantsLayer_(True)
    layer = card.layer()
    layer.setCornerRadius_(corner_radius)
    layer.setMasksToBounds_(True)
    layer.setBorderWidth_(0.0)
    layer.setBackgroundColor_(Quartz.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0))

    tint = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, frame.size.width, frame.size.height)
    )
    tint.setWantsLayer_(True)
    tint.layer().setCornerRadius_(corner_radius)
    tint.layer().setMasksToBounds_(True)
    tint.layer().setBackgroundColor_(tint_color)
    tint.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
    )
    card.addSubview_(tint)

    label_width = frame.size.width - (padding_x * 2)
    if single_line:
        label_height = frame.size.height
        label_y = 0.0
    else:
        label_height = min(
            frame.size.height - (padding_y * 2),
            _measure_height(text, label_width, font, line_spacing),
        )
        label_y = padding_y + max(
            0.0,
            (frame.size.height - (padding_y * 2) - label_height) / 2,
        )

    label = _make_label(
        Foundation.NSMakeRect(
            padding_x,
            label_y,
            label_width,
            label_height,
        ),
        text,
        font,
        text_color,
        line_spacing,
        single_line,
    )
    if alignment is not None:
        label.setAlignment_(alignment)
    card.addSubview_(label)
    return card, tint, label


def _make_suggestion_card(
    frame: Foundation.NSRect,
    index: int,
    text: str,
    collapsed_text: str,
    font: AppKit.NSFont,
) -> tuple[AppKit.NSVisualEffectView, AppKit.NSView, AppKit.NSTextField, AppKit.NSTextField]:
    corner_radius = frame.size.height / 2.0
    card = AppKit.NSVisualEffectView.alloc().initWithFrame_(frame)
    card.setAppearance_(LIGHT_GLASS_APPEARANCE)
    card.setMaterial_(AppKit.NSVisualEffectMaterialPopover)
    card.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
    card.setState_(AppKit.NSVisualEffectStateActive)
    card.setWantsLayer_(True)
    layer = card.layer()
    layer.setCornerRadius_(corner_radius)
    layer.setMasksToBounds_(True)
    layer.setBorderWidth_(0.0)
    layer.setBackgroundColor_(Quartz.CGColorCreateGenericRGB(0.0, 0.0, 0.0, 0.0))

    tint = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, frame.size.width, frame.size.height)
    )
    tint.setWantsLayer_(True)
    tint.layer().setCornerRadius_(corner_radius)
    tint.layer().setMasksToBounds_(True)
    tint.layer().setBackgroundColor_(SUGGESTION_TINT)
    tint.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
    )
    card.addSubview_(tint)

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
        LIGHT_SECONDARY_TEXT,
        single_line=True,
    )
    number.setAlignment_(AppKit.NSTextAlignmentCenter)
    card.addSubview_(number)

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
        LIGHT_TEXT,
        single_line=True,
    )
    label.setLineBreakMode_(AppKit.NSLineBreakByClipping)
    card.addSubview_(label)
    return card, tint, number, label


def show_result_panel(
    tldr: str,
    suggestions: list[str],
) -> ReplyPanel:
    display_suggestions = suggestions[:3] or ["No usable suggestion returned."]
    content_width = PANEL_WIDTH
    summary_font = AppKit.NSFont.systemFontOfSize_weight_(
        TLDR_FONT_SIZE,
        AppKit.NSFontWeightMedium,
    )
    suggestion_font = AppKit.NSFont.systemFontOfSize_(SUGGESTION_FONT_SIZE)
    footer_font = AppKit.NSFont.systemFontOfSize_(FOOTER_FONT_SIZE)
    summary_label_width = content_width - (CARD_PADDING_X * 2)
    suggestion_padding_x = SUGGESTION_PADDING_X
    suggestion_padding_y = SUGGESTION_PADDING_Y
    suggestion_label_width = content_width - SUGGESTION_TEXT_X - suggestion_padding_x

    tldr_height = (
        _measure_height(tldr, summary_label_width, summary_font, TLDR_LINE_SPACING)
        + (CARD_PADDING_Y * 2)
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
            + (suggestion_padding_y * 2),
        )
        for index, text in enumerate(display_suggestions, start=1)
    ]
    panel_height = (
        + tldr_height
        + CARD_GAP
        + sum(row_heights)
        + (CARD_GAP * max(0, len(row_heights) - 1))
        + CARD_GAP
        + FOOTER_HEIGHT
    )

    screen_frame = AppKit.NSScreen.mainScreen().frame()
    origin_x = screen_frame.origin.x + (screen_frame.size.width - PANEL_WIDTH) / 2
    origin_y = screen_frame.origin.y + (screen_frame.size.height - panel_height) / 2
    panel_frame = Foundation.NSMakeRect(origin_x, origin_y, PANEL_WIDTH, panel_height)

    style_mask = (
        AppKit.NSWindowStyleMaskNonactivatingPanel
        | AppKit.NSWindowStyleMaskBorderless
        | AppKit.NSWindowStyleMaskFullSizeContentView
    )
    panel = ReplyPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        panel_frame,
        style_mask,
        AppKit.NSBackingStoreBuffered,
        False,
    )
    panel.setLevel_(AppKit.NSStatusWindowLevel)
    panel.setFloatingPanel_(True)
    panel.setWorksWhenModal_(True)
    panel.setHidesOnDeactivate_(False)
    panel.setReleasedWhenClosed_(False)
    panel.setOpaque_(False)
    panel.setBackgroundColor_(AppKit.NSColor.clearColor())

    background = AppKit.NSView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, PANEL_WIDTH, panel_height)
    )
    background.setWantsLayer_(True)
    background.layer().setBackgroundColor_(Quartz.CGColorCreateGenericRGB(0, 0, 0, 0))
    panel.setContentView_(background)

    y = panel_height - tldr_height
    tldr_card, _, _ = _make_card(
        Foundation.NSMakeRect(0, y, content_width, tldr_height),
        tldr,
        summary_font,
        DARK_TEXT,
        AppKit.NSVisualEffectMaterialHUDWindow,
        tint_color=SUMMARY_TINT,
        corner_radius=24.0,
        line_spacing=TLDR_LINE_SPACING,
    )
    tldr_card.setAlphaValue_(0.0)
    background.addSubview_(tldr_card)
    y -= CARD_GAP

    option_cards: list[AppKit.NSView] = []
    option_tints: list[AppKit.NSView] = []
    option_numbers: list[AppKit.NSTextField] = []
    option_labels: list[AppKit.NSTextField] = []
    option_texts: list[str] = []
    option_collapsed_texts: list[str] = []
    collapsed_frames: list[Foundation.NSRect] = []
    expanded_frames: list[Foundation.NSRect] = []
    option_start_y = y
    for index, text in enumerate(display_suggestions, start=1):
        row_height = row_heights[index - 1]
        y -= row_height
        final_frame = Foundation.NSMakeRect(0, y, content_width, row_height)
        expanded_frame = Foundation.NSMakeRect(
            0,
            y - (expanded_row_heights[index - 1] - row_height),
            content_width,
            expanded_row_heights[index - 1],
        )
        collapsed_text = _collapsed_single_line_text(
            text,
            suggestion_label_width,
            suggestion_font,
        )
        card, tint, number, label = _make_suggestion_card(
            final_frame,
            index,
            text,
            collapsed_text,
            suggestion_font,
        )
        card.setAlphaValue_(0.0)
        card.setFrameOrigin_(Foundation.NSMakePoint(0, option_start_y - row_height))
        background.addSubview_(card)
        option_cards.append(card)
        option_tints.append(tint)
        option_numbers.append(number)
        option_labels.append(label)
        option_texts.append(text)
        option_collapsed_texts.append(collapsed_text)
        collapsed_frames.append(final_frame)
        expanded_frames.append(expanded_frame)
        y -= CARD_GAP

    pill_specs = [
        ("Press 1 / 2 / 3 to expand; repeat to copy", 14.0),
        ("Esc to cancel", 12.0),
    ]
    pill_widths = [
        _measure_width(text, footer_font) + (padding_x * 2)
        for text, padding_x in pill_specs
    ]
    total_pills_width = sum(pill_widths) + FOOTER_PILL_GAP
    pill_x = (content_width - total_pills_width) / 2
    footer_views: list[AppKit.NSView] = []
    for (text, padding_x), pill_width in zip(pill_specs, pill_widths):
        pill, _, _ = _make_card(
            Foundation.NSMakeRect(pill_x, 0, pill_width, FOOTER_HEIGHT),
            text,
            footer_font,
            LIGHT_SECONDARY_TEXT,
            AppKit.NSVisualEffectMaterialPopover,
            padding_x=padding_x,
            padding_y=6.0,
            alignment=AppKit.NSTextAlignmentCenter,
            tint_color=PILL_TINT,
            corner_radius=16.0,
            single_line=True,
            appearance=LIGHT_GLASS_APPEARANCE,
        )
        pill.setAlphaValue_(0.0)
        background.addSubview_(pill)
        footer_views.append(pill)
        pill_x += pill_width + FOOTER_PILL_GAP

    panel.configure_expansion(
        background,
        option_cards,
        option_tints,
        option_numbers,
        option_labels,
        option_texts,
        option_collapsed_texts,
        collapsed_frames,
        expanded_frames,
        footer_views,
    )

    def _ease_out_fade(view: AppKit.NSView) -> None:
        NSAnimationContext = AppKit.NSAnimationContext
        NSAnimationContext.beginGrouping()
        try:
            context = NSAnimationContext.currentContext()
            context.setDuration_(ENTRANCE_DURATION)
            context.setTimingFunction_(
                Quartz.CAMediaTimingFunction.functionWithName_(
                    Quartz.kCAMediaTimingFunctionEaseOut
                )
            )
            view.animator().setAlphaValue_(1.0)
        finally:
            NSAnimationContext.endGrouping()

    tldr_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
        0.0,
        False,
        lambda _timer, _card=tldr_card: _ease_out_fade(_card),
    )
    panel.register_show_timer(tldr_timer)

    footer_delay = ENTRANCE_STAGGER * len(option_cards) + ENTRANCE_FOOTER_DELAY_PADDING
    footer_timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
        footer_delay,
        False,
        lambda _timer, _views=footer_views: [_ease_out_fade(v) for v in _views],
    )
    panel.register_show_timer(footer_timer)

    for delay_index, (card, final_frame) in enumerate(zip(option_cards, collapsed_frames)):
        def animate_option(
            timer: Any,
            animated_card: AppKit.NSView = card,
            target_frame: Foundation.NSRect = final_frame,
        ) -> None:
            NSAnimationContext = AppKit.NSAnimationContext
            NSAnimationContext.beginGrouping()
            try:
                context = NSAnimationContext.currentContext()
                context.setDuration_(ENTRANCE_DURATION)
                context.setTimingFunction_(
                    Quartz.CAMediaTimingFunction.functionWithName_(
                        Quartz.kCAMediaTimingFunctionEaseOut
                    )
                )
                animated_card.animator().setAlphaValue_(1.0)
                animated_card.animator().setFrame_(target_frame)
            finally:
                NSAnimationContext.endGrouping()

        timer = Foundation.NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
            ENTRANCE_STAGGER * delay_index,
            False,
            animate_option,
        )
        panel.register_show_timer(timer)

    panel.orderFrontRegardless()
    return panel
