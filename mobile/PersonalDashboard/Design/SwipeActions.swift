import SwiftUI
import UIKit

extension View {
    /// Swipe-left-to-delete affordance: the row content slides left and
    /// reveals an edge-to-edge red rectangle with a white trash icon on
    /// the trailing edge — visually identical to the stock
    /// `.swipeActions(edge: .trailing, allowsFullSwipe: true)` button.
    /// Routed through a custom container (rather than `.swipeActions`)
    /// so we can also fade a curved gray card in behind the row as it
    /// slides, providing the visual separation requested in #39 without
    /// changing row heights or the delete button's appearance.
    ///
    /// Native semantics are preserved:
    ///   - Partial swipe past `revealedWidth / 2` snaps the row open.
    ///   - Full-swipe past 45% of the row width (or fast left flick) commits.
    ///   - Tap on the open row anywhere outside the pill closes it.
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
    /// Measured row height drives the trailing trash pill so it
    /// stays the same height as the row. Without an explicit height
    /// the inner `.frame(maxHeight: .infinity)` would propagate and
    /// force `List` to allocate hundreds of points to each row.
    @State private var rowHeight: CGFloat = 0

    private let revealedWidth: CGFloat = 80
    private let tintColor: Color = Tokens.borderStrong
    /// Curved corner radius used for both the row's gray fade-in
    /// and the trailing trash pill so they read as a matched pair.
    private let cornerRadius: CGFloat = Radius.lg
    /// Spacing between the row's right edge and the trash pill's
    /// left edge, so they read as two distinct objects.
    private let pillGap: CGFloat = Space.sm

    func body(content: Content) -> some View {
        let dragDistance = -offset
        let progress = min(1.0, max(0.0, Double(dragDistance / revealedWidth)))
        let pillWidth = max(0, dragDistance - pillGap)
        let pillHeight: CGFloat = rowHeight > 0 ? rowHeight : 44

        ZStack(alignment: .trailing) {
            // Standalone rounded red pill on the trailing edge with a
            // white trash icon. Width grows with the swipe so the
            // action is revealed live, not just on release.
            Button(action: commit) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: pillWidth, height: pillHeight)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Tokens.danger)
                    )
            }
            .buttonStyle(.plain)
            .opacity(pillWidth > 0.5 ? 1 : 0)
            .allowsHitTesting(pillWidth >= revealedWidth * 0.5)
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
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let proposed = (isOpen ? -revealedWidth : 0) + value.translation.width
                offset = max(min(0, proposed), -UIScreen.main.bounds.width)
            }
            .onEnded { value in
                let endX = (isOpen ? -revealedWidth : 0) + value.translation.width
                let velocity = value.predictedEndTranslation.width - value.translation.width

                if -endX > UIScreen.main.bounds.width * 0.45 || velocity < -1200 {
                    commit()
                } else if -endX > revealedWidth * 0.5 {
                    open()
                } else {
                    close()
                }
            }
    }

    private func open() {
        isOpen = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = -revealedWidth
        }
    }

    private func close() {
        isOpen = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = 0
        }
    }

    private func commit() {
        Haptics.destructive()
        withAnimation(.easeOut(duration: 0.2)) {
            offset = -UIScreen.main.bounds.width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onDelete()
        }
    }
}
