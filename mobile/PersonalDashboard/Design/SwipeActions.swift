import SwiftUI
import UIKit

/// Custom swipe-left-to-delete container that replaces the stock
/// `.swipeActions` modifier (which renders edge-to-edge rectangles with
/// no separation between row and action). When a row is dragged left,
/// the row card slides left and a standalone destructive pill appears
/// on the trailing edge with a `Space.sm` gap between the two. Matches
/// the rounded, capsule-led design language used everywhere else in the
/// app.
///
/// The container handles native iOS swipe semantics:
///   - Partial swipe past `restingPillWidth / 2` snaps the row open.
///   - Full-swipe past 45% of the row width (or fast left flick) commits.
///   - Tap on the open row anywhere outside the pill closes it.
///
/// Apply via the `.swipeToDelete(...)` modifier on each row inside a
/// `List`. Set `listRowInsets` leading/trailing to `0` so the wrapper
/// owns the row's edge padding (the Delete pill has to sit inside the
/// trailing margin to read as a separate object).
struct SwipeToDelete<Content: View>: View {
    let cornerRadius: CGFloat
    /// Optional pill fill that fades in only while the row is being
    /// dragged. Use for rows that don't ship their own card surface
    /// (TaskRow, ItemRow) so the at-rest appearance is unchanged.
    let revealedBackground: Color?
    let outerPadding: CGFloat
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false

    private var restingPillWidth: CGFloat { 84 }
    private var gap: CGFloat { Space.sm }
    private var openOffset: CGFloat { -(restingPillWidth + gap) }

    var body: some View {
        let pillReveal = max(0, -offset - gap)
        let pillVisible = pillReveal > 0.5

        ZStack(alignment: .trailing) {
            // Standalone destructive pill anchored to the trailing edge.
            // Width grows with the swipe so the affordance is revealed
            // from behind the row, not animated in only on release.
            Button(action: commit) {
                deletePillLabel
            }
            .buttonStyle(.plain)
            .frame(width: pillReveal)
            .padding(.trailing, outerPadding)
            .opacity(pillVisible ? 1 : 0)
            .allowsHitTesting(pillReveal >= restingPillWidth * 0.5)
            .accessibilityLabel("Delete")
            .accessibilityHidden(!pillVisible)

            content()
                .background(revealedFill)
                .overlay(closeOverlay)
                .padding(.horizontal, outerPadding)
                .offset(x: offset)
                .gesture(dragGesture)
        }
    }

    @ViewBuilder
    private var revealedFill: some View {
        if let bg = revealedBackground {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bg)
                .opacity(min(1, max(0, Double(-offset / 24))))
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

extension View {
    /// Wrap a row with the pill-with-gap swipe-to-delete treatment from
    /// issue #39. Pair with `.listRowInsets(EdgeInsets(top: …, leading: 0,
    /// bottom: …, trailing: 0))` so the wrapper owns horizontal padding.
    ///
    /// Pass `revealedBackground: Tokens.surface` for rows that don't have
    /// their own card surface (TaskRow, ItemRow) so they read as a pill
    /// during the swipe; leave `nil` for rows that already render on a
    /// rounded card (NoteRow, FolderRow, ListSummaryRow).
    func swipeToDelete(
        cornerRadius: CGFloat = Radius.md,
        revealedBackground: Color? = nil,
        outerPadding: CGFloat = Space.lg,
        perform action: @escaping () -> Void
    ) -> some View {
        SwipeToDelete(
            cornerRadius: cornerRadius,
            revealedBackground: revealedBackground,
            outerPadding: outerPadding,
            onDelete: action
        ) {
            self
        }
    }
}
