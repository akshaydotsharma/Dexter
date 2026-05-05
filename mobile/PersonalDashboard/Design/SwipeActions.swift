import SwiftUI

extension View {
    /// Unified swipe-left-to-delete affordance across every list surface.
    /// Renders an icon-only trash button on a destructive-red fill, full-swipe enabled.
    /// Tint (without `role: .destructive`) keeps the visual flat across short and tall rows
    /// so SwiftUI does not switch to its circular icon-bubble heuristic on short rows.
    func swipeToDeleteTrash(perform action: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Haptics.destructive()
                action()
            } label: {
                Image(systemName: "trash")
            }
            .tint(Tokens.danger)
            .accessibilityLabel("Delete")
        }
    }

    /// Fades a subtle gray tint behind the row as the user swipes left,
    /// so the row's background reads as distinct from the destructive
    /// `.swipeActions` button on the trailing edge. Visual-only — runs
    /// as a `simultaneousGesture` so the stock swipe-to-delete still
    /// commits normally; row height and the delete button itself are
    /// unchanged.
    func swipeProgressTint(_ color: Color = Tokens.borderStrong) -> some View {
        modifier(SwipeProgressTintModifier(tint: color))
    }
}

private struct SwipeProgressTintModifier: ViewModifier {
    let tint: Color
    @State private var progress: Double = 0

    func body(content: Content) -> some View {
        content
            .background(tint.opacity(progress))
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let dx = -value.translation.width
                        guard dx > 0,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        progress = min(1, Double(dx / 80))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25)) {
                            progress = 0
                        }
                    }
            )
    }
}
