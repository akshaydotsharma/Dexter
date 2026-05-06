import SwiftUI
import UIKit

extension View {
    /// Swipe-left-to-delete affordance: the row content slides left
    /// and reveals a fixed-size circular red trash button on the
    /// trailing edge, with a soft gray card fading in behind the
    /// row to differentiate the swiped state.
    ///
    /// The drag uses `.highPriorityGesture` with a 10pt activation
    /// threshold so it preempts the Button-wrapped rows (folders,
    /// list summaries, note rows) — short touches stay below the
    /// threshold and fall through to the Button's tap; deliberate
    /// drags activate the swipe and the Button's tap is cancelled.
    ///
    /// Full-swipe-commit requires a deliberate 70%+ drag (no
    /// velocity-only commit) so a quick flick can never silently
    /// delete a row.
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

    @State private var offset: CGFloat = 0  // change to test reveal states
    @State private var isOpen: Bool = false
    /// Measured row height — used to size the gray fade-in card so
    /// it matches the row, and to vertically center the fixed-size
    /// trash circle inside taller rows like notes with body preview.
    @State private var rowHeight: CGFloat = 0

    /// Fixed circle diameter. Same on every row regardless of row
    /// height, so tasks / lists / notes all reveal an identical
    /// circular action.
    private let buttonSize: CGFloat = 52
    /// Distance the row must travel for the trash to be fully revealed.
    /// Equals buttonSize plus the trailing gap, so at full reveal the
    /// circle sits exactly `pillGap` from the row's right edge.
    private let revealedWidth: CGFloat = 60
    /// Spacing between the row's right edge and the trash circle's
    /// left edge — reads as two distinct objects.
    private let pillGap: CGFloat = Space.sm
    /// Soft corner radius for the gray fade-in card. The trash itself
    /// is a Circle (corner radius doesn't apply).
    private let cardCornerRadius: CGFloat = 14
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
        let outerHeight: CGFloat = rowHeight > 0 ? rowHeight : 44

        ZStack(alignment: .trailing) {
            // 52pt circle, opacity tied to drag distance. Invisible
            // at rest (so the circle's edges can't bleed through
            // gaps in the row's rounded background), fades in over
            // the first 20pt of drag, fully visible by the snap-open
            // point. As content slides left underneath, the circle
            // is revealed purely as a side-effect of the offset —
            // no width animation, the shape stays a circle.
            Button(action: commit) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(trashColor))
            }
            .buttonStyle(.plain)
            .frame(maxHeight: outerHeight, alignment: .center)
            .opacity(min(1.0, dragDistance / 20))
            .allowsHitTesting(dragDistance >= revealedWidth * 0.6)
            .accessibilityLabel("Delete")

            content
                .background(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
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
                // highPriorityGesture so the drag preempts the row's
                // Button tap (folders, list summaries, note rows
                // wrap their content in a Button that navigates on
                // tap). With simultaneousGesture both gestures
                // recognised on release, so the row would snap open
                // AND fire the Button's onTap. highPriority kills
                // the Button's tap once the drag activates, but
                // brief touches that stay below minimumDistance: 10
                // never activate the drag and fall through to the
                // Button as expected.
                .highPriorityGesture(dragGesture)
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
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Vertical drags (List scroll) shouldn't move the row.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let raw = (isOpen ? -revealedWidth : 0) + value.translation.width
                offset = applyRubberBand(to: raw)
            }
            .onEnded { value in
                let endRaw = (isOpen ? -revealedWidth : 0) + value.translation.width
                // Commit only on a deliberate full-swipe past 70% of
                // the screen width. No velocity-based commit — a
                // quick flick must never silently delete a row.
                if -endRaw > UIScreen.main.bounds.width * 0.7 {
                    commit()
                } else if -endRaw > revealedWidth * 0.4 {
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
