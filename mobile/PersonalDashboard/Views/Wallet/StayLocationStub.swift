import SwiftUI

/// The bottom of a stay ticket: where the place is, and a way to get there
/// (#398).
///
/// A hotel booking has nothing to scan, so its stub carries the fact you
/// actually want off the card on the day. That is the same rule the other kinds
/// follow — the stub holds the thing you USE — a boarding pass and an event
/// ticket tear off a barcode, a stay tears off its address.
///
/// This briefly rendered a map snapshot above the address. It was dropped: the
/// image cost a geocode and a network round trip per card to say something the
/// address line already said, and tapping through to Maps is the action anyone
/// actually takes. The address and the button are the whole panel.
struct StayLocationStub: View {
    let address: String
    let mapsURL: URL?
    /// The card's band colour. Stub paper is white in BOTH themes, so the
    /// palette's `accent` cannot be used here (it is light in dark mode and
    /// would vanish); `band` stays saturated in both.
    let buttonFill: Color

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Space.md) {
            if !address.isEmpty {
                VStack(spacing: Space.xs) {
                    Text("ADDRESS")
                        .font(.edEyebrow)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.ticketStubMuted)
                    Text(address)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ticketStubInk)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity)
            }

            if let mapsURL {
                Button {
                    openURL(mapsURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Directions")
                            .font(.edBodyMedium)
                    }
                    .foregroundStyle(Tokens.ticketStub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.sm)
                    .background(buttonFill, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open directions in Maps")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xl)
        .background(Tokens.ticketStub)
    }
}
