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
}
