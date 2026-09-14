import SwiftUI

/// Chooses what the exported itinerary carries (#532).
///
/// Both toggles exist for the same reason: the document leaves the device. A
/// plan sent to whoever is meeting you at the airport should not have to carry
/// "ask Priya about the money" in the notes, and a plan printed and left in a
/// hotel room should not have to carry the booking reference that can cancel
/// it. Both default to on, because the common export is to yourself and to the
/// people already on the trip.
struct TripItineraryExportOptionsSheet: View {
    @Binding var includesNotes: Bool
    @Binding var includesReferences: Bool
    /// Called before dismissing. The caller starts the export from the sheet's
    /// `onDismiss`, never from here.
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("What to include").eyebrow()

                        option(
                            title: "Notes",
                            detail: "Whatever you typed on each stop.",
                            isOn: $includesNotes
                        )
                        option(
                            title: "Booking references",
                            detail: "Confirmation codes, seats and gates.",
                            isOn: $includesReferences
                        )

                        Text("The plan itself always goes in: every day of the trip, every stop on it, with its time, place and address.")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.mutedSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        onExport()
                        dismiss()
                    } label: {
                        Text("Export PDF")
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.accentFg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.md)
                            .background(
                                Tokens.accent(for: .itineraries),
                                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(Space.lg)
            }
            .background(Tokens.paper)
            .navigationTitle("Export itinerary")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // A macOS sheet with no intrinsic height collapses to its toolbar
        // (#474). The content here is short, so it gets an explicit frame.
        .frame(width: 420, height: 320)
        #endif
    }

    private func option(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Text(detail)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Tokens.accent(for: .itineraries))
        .padding(.vertical, Space.xs)
    }
}
