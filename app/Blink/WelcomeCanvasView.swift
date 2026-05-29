import AppKit
import SwiftUI

/// The email-mock canvas — header row, dimmable body, growable reply
/// field — plus the floating keycap and overlay panel layered on top.
/// Owns all phase-driven layout (canvas height, reply field height,
/// dim level, shared spring) so children can stay leaf-simple.
struct WelcomeCanvasView: View {
    let phase: WelcomePhase

    var body: some View {
        ZStack(alignment: .center) {
            emailCanvas
                // Keycaps live in the bottom-right corner as a floating
                // "press this" HUD over the email — tucked above the
                // reply field, diagonally far from the overlay's center
                // landing spot so the press and the overlay never
                // occupy the same coordinate.
                .overlay(
                    WelcomeKeycap(phase: phase)
                        .padding(.trailing, 18)
                        .padding(.bottom, keycapBottomInset),
                    alignment: .bottomTrailing
                )
            WelcomeOverlayPanel(phase: phase).offset(y: overlayYOffset)
        }
        // Reserve the tallest (.chose) canvas height and top-anchor the
        // card in it. The card then grows *downward* into the reserved
        // space on the .overlay → .chose transition instead of the whole
        // ZStack re-centering — so the copy, sender, body, and reply-field
        // top all stay put, and only the field unfolds downward. The
        // overlay panel still centers on the actual (shorter) card because
        // the ZStack keeps its natural card size inside this frame.
        .frame(height: maxCanvasHeight, alignment: .top)
    }

    // MARK: Phase-driven layout

    private var showingOverlay: Bool { phase == .overlay }
    private var bodyOpacity: Double { showingOverlay ? 0.5 : 1.0 }
    private var overlayYOffset: CGFloat { -8 }
    private var replyFieldHeight: CGFloat { phase == .chose ? 78 : 36 }
    // Canvas tall enough to fully contain its content (sender + body +
    // reply field) with the Spacer holding real slack — otherwise the
    // content overflows, the Spacer collapses, and the reply field gets
    // pinned flush to the bottom edge no matter what bottom inset we set.
    // The .chose delta (+42) matches the reply field's growth so the
    // body layout stays put as the field expands.

    /// Bottom padding that lifts the keycap HUD clear of the reply
    /// field. The keycap only shows during `.hotkey` and the `.overlay`
    /// press, when the field is its 36pt resting height: canvas bottom
    /// inset (18) + field (36) + a small gap (12).
    private var keycapBottomInset: CGFloat { 18 + 36 + 12 }
    /// Tallest the card ever gets (.chose). Used both as the .chose canvas
    /// height and as the reserved slot height so growth is downward-only.
    private let maxCanvasHeight: CGFloat = 308
    private var canvasHeight: CGFloat { phase == .chose ? maxCanvasHeight : 266 }
    /// Mask height that fully reveals the inserted reply (a touch beyond
    /// the ~50pt content so the last line's caret isn't clipped). The mask
    /// animates 0 → this to wipe the reply in top-to-bottom.
    private let replyRevealHeight: CGFloat = 54

    /// Single shared curve for everything that animates during the
    /// .overlay → .chose handoff (canvas height, reply field height,
    /// content cross-fade, body undim) — and matched by the overlay
    /// panel's exit spring. One physics, one start time, no handoff
    /// delay, so the overlay collapsing and the reply text inserting read
    /// as a single synced motion rather than two sequential shuffles.
    private var choseAnimation: Animation {
        .spring(duration: 0.7, bounce: 0.1)
    }

    // MARK: Email canvas

    private var emailCanvas: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .textBackgroundColor))
            .frame(width: 480, height: canvasHeight)
            // Shadow applied BEFORE the content overlay so it casts only
            // from the card silhouette. If applied after, SwiftUI shadows
            // every inner shape too — the inset reply field would float
            // with its own drop shadow, which it shouldn't.
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .overlay(
                VStack(alignment: .leading, spacing: 8) {
                    senderRow
                    Divider()
                    bodyLines
                    Spacer(minLength: 4)
                    replyField
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                // Larger bottom inset so the gap below the reply field
                // optically matches the side insets — 14 read as cramped
                // against the canvas edge.
                .padding(.bottom, 18),
                alignment: .topLeading
            )
            .animation(choseAnimation, value: phase)
    }

    private var senderRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 0.36, green: 0.45, blue: 0.85))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.6))
                    .frame(width: 90, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.25))
                    .frame(width: 140, height: 6)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.2))
                .frame(width: 38, height: 6)
        }
    }

    private var bodyLines: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph(widths: [440, 420, 355])
            paragraph(widths: [425, 440, 395, 280])
            paragraph(widths: [410, 220])
        }
        .opacity(bodyOpacity)
        // Same curve as the canvas/field growth so the body brightens on
        // exactly the same timeline — one synced motion, not two.
        .animation(choseAnimation, value: phase)
    }

    private func paragraph(widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.primary.opacity(0.13))
                    .frame(width: w, height: 7)
            }
        }
    }

    // MARK: Reply field

    private var replyField: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.13))
            )
            .overlay(replyFieldContent)
            .frame(height: replyFieldHeight)
            // Same shared curve as canvas height + content swap so
            // field growth and text insertion move together.
            .animation(choseAnimation, value: phase)
    }

    private var replyFieldContent: some View {
        ZStack(alignment: .top) {
            // Empty state — just the caret, vertically centered in the
            // 36pt field (14pt caret → 11pt top inset centers it). Fades
            // out fast as the reply is revealed; it's a thin line, not
            // content, so a quick fade doesn't read as a cross-fade.
            HStack(spacing: 6) {
                caret
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .opacity(phase == .chose ? 0 : 1)
            .animation(.easeOut(duration: 0.18), value: phase)

            // Filled state — inserted reply, top-justified. Instead of a
            // slow opacity cross-fade on the growth spring (which read as
            // the text "materializing"), the reply is *wiped in* top-to-
            // bottom by a growing mask on a quicker curve — so it reads as
            // the reply being inserted as the field opens, and lands
            // sooner. The field/canvas keep their physical spring grow.
            insertedContent
                .mask(alignment: .top) {
                    Rectangle().frame(height: phase == .chose ? replyRevealHeight : 0)
                }
                .animation(.easeOut(duration: 0.42), value: phase)
        }
        // Fill the field height and pin children to the top so the inserted
        // text anchors at the top edge through the grow.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var insertedContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            contentLine(330)
            contentLine(380)
            HStack(spacing: 4) {
                contentLine(170)
                caret
            }
            // Pin the last row to the line height so the taller caret
            // overflows symmetrically instead of inflating this row and
            // pushing the third line down — keeps the line rhythm even.
            .frame(height: 7)
        }
        .padding(.horizontal, 12)
        // Top inset matches the field's left inset so the text block sits
        // in the field's top-left corner with balanced padding.
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func contentLine(_ w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.primary.opacity(0.7))
            .frame(width: w, height: 7)
    }

    private var caret: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(.primary.opacity(0.8))
            .frame(width: 1.5, height: 14)
    }

}
