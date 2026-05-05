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

    /// Fades a rounded gray tint behind the row in proportion to how
    /// far the stock `.swipeActions` recogniser has shifted the row to
    /// the left. Detection is purely geometric — a GeometryReader
    /// measures the row's global x position and we compare against the
    /// at-rest position. No custom DragGesture is attached, so the
    /// stock swipe (and its full-swipe-to-commit) keep working
    /// unchanged. Row height and the trailing trash button are
    /// untouched.
    func swipeProgressTint(_ color: Color = Tokens.borderStrong, cornerRadius: CGFloat = Radius.md) -> some View {
        modifier(SwipeProgressTintModifier(tint: color, cornerRadius: cornerRadius))
    }
}

private struct SwipeRowOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SwipeProgressTintModifier: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat
    @State private var baseX: CGFloat? = nil
    @State private var progress: Double = 0

    /// Distance over which the tint fades from 0 -> 1 opacity. Roughly
    /// matches the width of the stock `.swipeActions` trash button so
    /// the tint is fully present once the action is fully revealed.
    private let revealDistance: CGFloat = 80

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
                    .opacity(progress)
            )
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: SwipeRowOffsetKey.self,
                            value: geo.frame(in: .global).origin.x
                        )
                }
            )
            .onPreferenceChange(SwipeRowOffsetKey.self) { x in
                if let base = baseX {
                    let dx = base - x
                    progress = min(1, max(0, Double(dx / revealDistance)))
                } else {
                    baseX = x
                }
            }
    }
}
