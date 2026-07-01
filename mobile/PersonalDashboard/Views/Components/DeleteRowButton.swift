import SwiftUI

/// Canonical destructive "Delete …" button shown at the bottom of an editor /
/// detail sheet. Extracted from the itinerary item editor (TripDetailView),
/// which is the reference format the app standardizes on:
///
/// - full-width, surface-filled row with a hairline paper border (NOT a
///   red-tinted fill)
/// - red `trash` glyph + label, both in `Color.red`
/// - fires `Haptics.destructive()` on tap
/// - `.plain` button style so the row background reads as a card, not a control
///
/// Confirmation (the itinerary editor wraps this in a `confirmationDialog`) is
/// left to the caller so each surface can phrase its own prompt, but the visual
/// treatment lives here as the single source of truth.
struct DeleteRowButton: View {
    /// Label text, e.g. "Delete item", "Delete task".
    let title: String
    /// Invoked on tap, after the destructive haptic. Callers typically present a
    /// confirmation dialog here, or perform the delete directly for lightweight
    /// records.
    let action: () -> Void

    var body: some View {
        Button(role: .destructive) {
            Haptics.destructive()
            action()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .regular))
                Text(title)
                    .font(.edBodyMedium)
            }
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
