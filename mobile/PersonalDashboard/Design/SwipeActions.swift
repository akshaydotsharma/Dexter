import SwiftUI
import UIKit

extension View {
    /// Swipe-left-to-delete affordance: the row content slides left
    /// and reveals a fixed-size red square trash button on the
    /// trailing edge, with a curved gray card fading in behind the
    /// row to differentiate the swiped state.
    ///
    /// Designed to coexist with row tap navigation — the drag has a
    /// 10pt activation threshold so brief touches always pass
    /// through to the underlying button. Full-swipe-commit requires
    /// a deliberate 70%+ drag (no velocity-only commit) so a quick
    /// flick can never silently delete the row.
    func swipeToDeleteTrash(perform action: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteWithTint(onDelete: action))
    }
}

private struct SwipeRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SwipeToDeleteWithTint: ViewModifier {
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false
    /// Measured row height — used to size the gray fade-in card so
    /// it matches the row, and to vertically center the fixed-size
    /// trash square inside taller rows like notes with body preview.
    @State private var rowHeight: CGFloat = 0

    /// Fixed square trash button. Same size on every row regardless
    /// of row height, so tasks / lists / notes all reveal an
    /// identical-looking action.
    private let buttonSize: CGFloat = 52
    /// Distance the row must travel for the trash to be fully revealed.
    /// Equals buttonSize plus the trailing gap, so at full reveal the
    /// button sits exactly `pillGap` from the row's right edge.
    private let revealedWidth: CGFloat = 60
    /// Spacing between the row's right edge and the trash square's
    /// left edge — reads as two distinct objects.
    private let pillGap: CGFloat = Space.sm
    /// Soft-square corner radius. Small enough that the trash always
    /// looks like a rounded square (never a pill); large enough that
    /// the gray card behind tall rows reads as soft, not sharp.
    private let cornerRadius: CGFloat = 14
    private let tintColor: Color = Tokens.borderStrong
    /// Vivid iOS-system red used by Reminders / Mail for destructive
    /// swipe actions.
    private let trashColor: Color = Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188, opacity: 1.0)

    func body(content: Content) -> some View {
        let dragDistance = -offset
        // Cosine ease so the gray doesn't pop in — barely visible at
        // the start of the swipe, accelerating toward the snap-open
        // point.
        let linear = min(1.0, max(0.0, Double(dragDistance / revealedWidth)))
        let progress = 0.5 - 0.5 * cos(.pi * linear)
        // Trash button width grows with drag but caps at buttonSize.
        // Past the snap-open point the row keeps moving (rubber-band
        // in dragGesture) but the button stops growing, so it stays
        // a square.
        let buttonWidth = max(0, min(dragDistance - pillGap, buttonSize))
        let outerHeight: CGFloat = rowHeight > 0 ? rowHeight : 44

        ZStack(alignment: .trailing) {
            // Trash square — `.frame(maxHeight:)` set to the measured
            // row height with center alignment, so the button sits
            // vertically centered inside taller rows. ZStack alignment
            // .trailing pins it to the right edge.
            Button(action: commit) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth, height: buttonSize)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(trashColor)
                    )
            }
            .buttonStyle(.plain)
            .frame(maxHeight: outerHeight, alignment: .center)
            .opacity(buttonWidth > 0.5 ? 1 : 0)
            .allowsHitTesting(buttonWidth >= buttonSize * 0.6)
            .accessibilityLabel("Delete")

            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tintColor)
                        .opacity(progress)
                )
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SwipeRowHeightKey.self, value: geo.size.height)
                    }
                )
                .overlay(closeOverlay)
                .offset(x: offset)
                .gesture(dragGesture)
        }
        .onPreferenceChange(SwipeRowHeightKey.self) { rowHeight = $0 }
    }

    @ViewBuilder
    private var closeOverlay: some View {
        if isOpen {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
        }
    }

    private var dragGesture: some Gesture {
        // 10pt activation threshold so brief touches pass through to
        // the row's underlying tap (folder/list rows navigate on tap;
        // a 4pt threshold was hijacking those taps).
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Vertical drags (scroll) shouldn't move the row.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let raw = (isOpen ? -revealedWidth : 0) + value.translation.width
                offset = applyRubberBand(to: raw)
            }
            .onEnded { value in
                let endRaw = (isOpen ? -revealedWidth : 0) + value.translation.width
                // Commit only on a deliberate full-swipe past 70% of
                // the screen width. No velocity-based commit — a
                // quick flick must never silently delete a row, the
                // user has to drag the row almost off the screen to
                // confirm.
                if -endRaw > UIScreen.main.bounds.width * 0.7 {
                    commit()
                } else if -endRaw > revealedWidth * 0.4 {
                    // Snap open: relatively low threshold so a short
                    // deliberate swipe reliably reveals the trash.
                    open()
                } else {
                    close()
                }
            }
    }

    /// Drag freely up to the snap-open point, then add resistance so
    /// over-drag feels weighted instead of just sliding to the edge.
    private func applyRubberBand(to raw: CGFloat) -> CGFloat {
        if raw >= 0 { return 0 }
        if -raw <= revealedWidth { return raw }
        let overshoot = -raw - revealedWidth
        return -(revealedWidth + overshoot * 0.4)
    }

    private func open() {
        isOpen = true
        // Softer spring than before so the snap-open settles rather
        // than hard-clicks into place.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            offset = -revealedWidth
        }
    }

    private func close() {
        isOpen = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            offset = 0
        }
    }

    private func commit() {
        Haptics.destructive()
        withAnimation(.easeOut(duration: 0.22)) {
            offset = -UIScreen.main.bounds.width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDelete()
        }
    }
}
