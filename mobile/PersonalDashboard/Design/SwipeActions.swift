import SwiftUI
import UIKit

/// Custom swipe-left-to-delete container that replaces the stock
/// `.swipeActions` modifier (which renders edge-to-edge rectangles with
/// no separation between row and action). When a row is dragged left,
/// the row content slides left and a standalone destructive pill
/// appears on the trailing edge with a `Space.sm` gap between the two.
/// Matches the rounded, capsule-led design language used everywhere
/// else in the app.
///
/// The container handles native iOS swipe semantics:
///   - Partial swipe past `restingPillWidth / 2` snaps the row open.
///   - Full-swipe past 45% of the row width (or fast left flick) commits.
///   - Tap on the open row anywhere outside the pill closes it.
///
/// Apply via the `.swipeToDelete(...)` modifier on each row inside a
/// `List`. Set `listRowInsets` leading/trailing to `0` so the wrapper
/// owns the row's edge padding (the Delete pill has to sit inside the
/// trailing margin to read as a separate object). The wrapper paints
/// nothing under the row itself: the row keeps the same look at rest
/// and during swipe — only the standalone red pill appears.
struct SwipeToDelete<Content: View>: View {
    let cornerRadius: CGFloat
    let outerPadding: CGFloat
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false
    /// Measured height of the row content. Drives the Delete pill's
    /// height so the pill matches the row visually. The row's content
    /// has to size the pill, not the other way around — using
    /// `maxHeight: .infinity` on the pill makes the row claim infinite
    /// vertical space and forces `List` to allocate hundreds of points
    /// to each row.
    @State private var rowHeight: CGFloat = 0

    private var restingPillWidth: CGFloat { 84 }
    private var gap: CGFloat { Space.sm }
    private var openOffset: CGFloat { -(restingPillWidth + gap) }

    var body: some View {
        let pillReveal = max(0, -offset - gap)
        let pillVisible = pillReveal > 0.5
        // Always pass an explicit, finite height to the Button's outer
        // frame. Without this fallback, the inner `maxHeight: .infinity`
        // on the label would propagate up through the ZStack and force
        // `List` to allocate hundreds of points to each row before the
        // PreferenceKey settles.
        let pillHeight: CGFloat = rowHeight > 0 ? rowHeight : 44

        ZStack(alignment: .trailing) {
            // Standalone destructive pill anchored to the trailing edge.
            // Width grows with the swipe so the affordance is revealed
            // from behind the row, not animated in only on release.
            Button(action: commit) {
                deletePillLabel
            }
            .buttonStyle(.plain)
            .frame(width: pillReveal, height: pillHeight)
            .padding(.trailing, outerPadding)
            .opacity(pillVisible ? 1 : 0)
            .allowsHitTesting(pillReveal >= restingPillWidth * 0.5)
            .accessibilityLabel("Delete")
            .accessibilityHidden(!pillVisible)

            content()
                .background(heightProbe)
                .overlay(closeOverlay)
                .padding(.horizontal, outerPadding)
                .offset(x: offset)
                .gesture(dragGesture)
        }
        .onPreferenceChange(SwipeRowHeightKey.self) { rowHeight = $0 }
    }

    private var heightProbe: some View {
        GeometryReader { geo in
            Color.clear.preference(key: SwipeRowHeightKey.self, value: geo.size.height)
        }
    }

    @ViewBuilder
    private var closeOverlay: some View {
        if isOpen {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
        }
    }

    private var deletePillLabel: some View {
        VStack(spacing: 4) {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
            Text("Delete")
                .font(.edCaption)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.danger, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let proposed = (isOpen ? openOffset : 0) + value.translation.width
                offset = max(min(0, proposed), -UIScreen.main.bounds.width)
            }
            .onEnded { value in
                let endX = (isOpen ? openOffset : 0) + value.translation.width
                let velocity = value.predictedEndTranslation.width - value.translation.width

                if -endX > UIScreen.main.bounds.width * 0.45 || velocity < -1200 {
                    commit()
                } else if -endX > restingPillWidth * 0.5 {
                    open()
                } else {
                    close()
                }
            }
    }

    private func open() {
        isOpen = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = openOffset
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

private struct SwipeRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Wrap a row with the pill-with-gap swipe-to-delete treatment from
    /// issue #39. Pair with `.listRowInsets(EdgeInsets(top: …, leading: 0,
    /// bottom: …, trailing: 0))` so the wrapper owns horizontal padding.
    /// The row keeps its own appearance at rest and during swipe; only
    /// the standalone red Delete pill appears.
    func swipeToDelete(
        cornerRadius: CGFloat = Radius.md,
        outerPadding: CGFloat = Space.lg,
        perform action: @escaping () -> Void
    ) -> some View {
        SwipeToDelete(
            cornerRadius: cornerRadius,
            outerPadding: outerPadding,
            onDelete: action
        ) {
            self
        }
    }
}
