from __future__ import annotations

from typing import Any

import AppKit
import Foundation
import Quartz
import objc


PANEL_WIDTH = 620.0
CARD_PADDING_X = 20.0
CARD_PADDING_Y = 16.0
CARD_GAP = 10.0
FOOTER_HEIGHT = 24.0
TEXT_FONT_SIZE = 16.0


def _color(red: float, green: float, blue: float, alpha: float) -> AppKit.NSColor:
    return AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
        red, green, blue, alpha
    )


class ReplyPanel(AppKit.NSPanel):
    def canBecomeKeyWindow(self) -> bool:
        return False

    def canBecomeMainWindow(self) -> bool:
        return False

    def keyDown_(self, event: Any) -> None:
        objc.super(ReplyPanel, self).keyDown_(event)


def _make_label(
    frame: Foundation.NSRect,
    text: str,
    font: AppKit.NSFont,
    color: AppKit.NSColor,
) -> AppKit.NSTextField:
    label = AppKit.NSTextField.alloc().initWithFrame_(frame)
    label.setStringValue_(text)
    label.setFont_(font)
    label.setTextColor_(color)
    label.setEditable_(False)
    label.setSelectable_(False)
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    label.setUsesSingleLineMode_(False)
    return label


def _measure_height(text: str, width: float, font: AppKit.NSFont) -> float:
    field = _make_label(
        Foundation.NSMakeRect(0, 0, width, 10),
        text,
        font,
        AppKit.NSColor.labelColor(),
    )
    field.cell().setWraps_(True)
    field.cell().setScrollable_(False)
    size = field.cell().cellSizeForBounds_(Foundation.NSMakeRect(0, 0, width, 1000))
    return max(24.0, float(size.height) + 8.0)


def _make_card(
    frame: Foundation.NSRect,
    text: str,
    font: AppKit.NSFont,
    text_color: AppKit.NSColor,
    material: int,
) -> AppKit.NSVisualEffectView:
    card = AppKit.NSVisualEffectView.alloc().initWithFrame_(frame)
    card.setMaterial_(material)
    card.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
    card.setState_(AppKit.NSVisualEffectStateActive)
    card.setWantsLayer_(True)
    layer = card.layer()
    layer.setCornerRadius_(14.0)
    layer.setMasksToBounds_(True)
    layer.setBorderWidth_(1.0)
    layer.setBorderColor_(Quartz.CGColorCreateGenericRGB(1.0, 1.0, 1.0, 0.18))

    label = _make_label(
        Foundation.NSMakeRect(
            CARD_PADDING_X,
            CARD_PADDING_Y,
            frame.size.width - (CARD_PADDING_X * 2),
            frame.size.height - (CARD_PADDING_Y * 2),
        ),
        text,
        font,
        text_color,
    )
    card.addSubview_(label)
    return card


def show_result_panel(
    tldr: str,
    suggestions: list[str],
) -> ReplyPanel:
    display_suggestions = suggestions[:3] or ["No usable suggestion returned."]
    content_width = PANEL_WIDTH
    label_width = content_width - (CARD_PADDING_X * 2)
    text_font = AppKit.NSFont.systemFontOfSize_(TEXT_FONT_SIZE)

    tldr_height = _measure_height(tldr, label_width, text_font) + (CARD_PADDING_Y * 2)
    row_heights = [
        max(
            66.0,
            _measure_height(f"{index}.  {text}", label_width, text_font)
            + (CARD_PADDING_Y * 2),
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
    background.addSubview_(
        _make_card(
            Foundation.NSMakeRect(0, y, content_width, tldr_height),
            tldr,
            text_font,
            _color(0.94, 0.94, 0.96, 0.98),
            AppKit.NSVisualEffectMaterialHUDWindow,
        )
    )
    y -= CARD_GAP

    for index, text in enumerate(display_suggestions, start=1):
        row_height = row_heights[index - 1]
        y -= row_height
        background.addSubview_(
            _make_card(
                Foundation.NSMakeRect(0, y, content_width, row_height),
                f"{index}.  {text}",
                text_font,
                AppKit.NSColor.whiteColor(),
                AppKit.NSVisualEffectMaterialPopover,
            )
        )
        y -= CARD_GAP

    footer = _make_label(
        Foundation.NSMakeRect(0, 0, content_width, FOOTER_HEIGHT),
        "1 / 2 / 3 to copy   /   esc to dismiss",
        text_font,
        _color(0.82, 0.82, 0.86, 0.86),
    )
    footer.setAlignment_(AppKit.NSTextAlignmentCenter)
    background.addSubview_(footer)

    panel.orderFrontRegardless()
    return panel
