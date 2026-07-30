import SwiftUI
import MapKit
import CoreLocation

/// The bottom of a stay ticket: a map of where you are going (#398).
///
/// It replaces the booking reference that used to be set large across this
/// panel. A confirmation code is something you read out once at a desk, so it
/// belongs in the detail list with the other facts; the thing you actually want
/// off a hotel card on the day is *where the place is*. That is also the only
/// honest image this app can put on a ticket — everything else would be
/// decoration, and this is generated from the address the card already has.
///
/// Built from two pieces that already exist: `AddressGeocoder` (free, keyless,
/// no location permission, hard timeout) turns the address into a coordinate,
/// and `MKMapSnapshotter` renders it. Everything degrades: no address, a failed
/// geocode, no network, or a snapshot error all fall back to the plain
/// confirmation row, so the card is never left with an empty panel.
///
/// Snapshots are cached in memory by address, because the deck can show the
/// same stay repeatedly (collapsed, expanded, then again in the detail sheet)
/// and a geocode per appearance would hit Apple's rate limit immediately.
struct StayMapStub: View {
    let address: String
    let venue: String
    let mapsURL: URL?
    /// Shown under the map, and the whole fallback when there is no map.
    let confirmationCode: String
    /// The card's band colour, used for the Directions button. Stub paper is
    /// white in BOTH themes, so the palette's `accent` cannot be used here (it
    /// is light in dark mode and would vanish); `band` stays saturated in both.
    let buttonFill: Color

    @Environment(\.openURL) private var openURL
    @State private var snapshot: PlatformImage?
    @State private var didResolve = false

    /// Rendered height of the map band. Tall enough to place the location in its
    /// surroundings rather than reading as a texture.
    private static let mapHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot {
                mapBand(snapshot)
            }
            footer
        }
        .frame(maxWidth: .infinity)
        .background(Tokens.ticketStub)
        .task(id: address) { await resolveIfNeeded() }
    }

    private func mapBand(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: Self.mapHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            // The snapshotter cannot draw annotations, so the pin goes on top.
            // Dead centre, because that is exactly what the snapshot is centred on.
            .overlay {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.red, .white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .accessibilityHidden(true)
            }
            .accessibilityLabel("Map of \(address)")
    }

    /// Address plus the action, or — when there is no map — the confirmation on
    /// its own so the panel still says something.
    private var footer: some View {
        VStack(spacing: Space.sm) {
            if snapshot == nil && !confirmationCode.isEmpty {
                HStack(spacing: Space.md) {
                    Text("CONFIRMATION")
                        .font(.edEyebrow)
                        .tracking(1.2)
                        .foregroundStyle(Tokens.ticketStubMuted)
                    Spacer(minLength: Space.sm)
                    Text(confirmationCode)
                        .font(.edMono)
                        .foregroundStyle(Tokens.ticketStubInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            if !address.isEmpty {
                Text(address)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ticketStubMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
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
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    // MARK: - Snapshot

    private func resolveIfNeeded() async {
        guard !didResolve, !address.isEmpty else { return }
        didResolve = true

        if let cached = Self.cache[address] {
            snapshot = cached
            return
        }
        guard let coordinate = await AddressGeocoder().resolveCoordinate(
            address: address,
            name: venue.isEmpty ? nil : venue
        ) else { return }

        guard let image = await Self.render(coordinate: coordinate) else { return }
        Self.cache[address] = image
        snapshot = image
    }

    /// One in-memory snapshot per address for the process lifetime. The same
    /// stay is drawn several times over (collapsed, expanded, detail sheet) and
    /// `CLGeocoder` is a shared rate-limited service — re-resolving per
    /// appearance is the fastest way to get throttled.
    @MainActor private static var cache: [String: PlatformImage] = [:]

    @MainActor
    private static func render(coordinate: CLLocationCoordinate2D) async -> PlatformImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            // ~600m across: close enough to name the street, wide enough to
            // recognise the neighbourhood.
            latitudinalMeters: 600,
            longitudinalMeters: 600
        )
        options.size = CGSize(width: 600, height: 340)
        options.showsBuildings = true
        // Always the light map: the stub is white paper in both themes, and a
        // dark map on it would read as a hole punched in the ticket.
        #if canImport(UIKit)
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        #elseif canImport(AppKit)
        options.appearance = NSAppearance(named: .aqua)
        #endif

        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { continuation in
            snapshotter.start(with: .main) { snapshot, _ in
                continuation.resume(returning: snapshot?.image)
            }
        }
    }
}
