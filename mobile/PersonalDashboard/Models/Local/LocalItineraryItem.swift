import Foundation
import SwiftData

/// Category of an itinerary item. Stored on `LocalItineraryItem.kind` as the
/// `rawValue` so SwiftData stays on plain `String` (no custom-codable
/// migrations to worry about). The skeleton ships four kinds; new ones can be
/// added without a schema change.
enum ItineraryKind: String, CaseIterable, Identifiable, Hashable {
    case stay
    case activity
    case place
    case restaurant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stay:       return "Stay"
        case .activity:   return "Activity"
        case .place:      return "Place"
        case .restaurant: return "Restaurant"
        }
    }

    /// SF Symbol used in row icons and the kind picker chips.
    var icon: String {
        switch self {
        case .stay:       return "bed.double"
        case .activity:   return "figure.walk"
        case .place:      return "mappin.and.ellipse"
        case .restaurant: return "fork.knife"
        }
    }
}

/// One row on a trip's day-by-day timeline. Belongs to a `LocalTrip` via
/// `tripUUID` foreign key (no SwiftData relationship — keeps the schema
/// boring and cascade-on-delete explicit, matching the rest of the app).
@Model
final class LocalItineraryItem {
    @Attribute(.unique) var clientUUID: UUID

    /// `LocalTrip.clientUUID` this item belongs to.
    var tripUUID: UUID

    /// The day this item lives on. Always normalised to `Calendar.startOfDay`
    /// so grouping by day is just a key-equality check.
    var dayDate: Date

    /// `ItineraryKind.rawValue`. Stored as a String to keep SwiftData happy.
    /// Read via `kindEnum` for type-safe access.
    var kind: String

    /// Short title (e.g. "Hanoi Hotel", "Halong Bay tour"). Required.
    var title: String

    /// Free-form notes. Empty when none.
    var notes: String

    /// Optional start time for this item. Stored as a full `Date` so the
    /// hours/minutes always round-trip cleanly with the day they belong to
    /// (the editor combines `dayDate` + the picked time-of-day before
    /// persisting). `nil` means the item is "untimed" and renders with a
    /// hollow marker plus no time label. The day grouping continues to use
    /// `dayDate` so timezone shifts in `startTime` can't accidentally move
    /// an item to a neighbouring day.
    var startTime: Date?

    /// Check-out day for `.stay` items. `nil` for other kinds. Stored as a
    /// start-of-day Date, same shape as `dayDate`. The timeline still renders
    /// the stay on its check-in day (`dayDate`); the card just shows a
    /// "Check-out · Sun May 17" sub-line so the duration is visible at a
    /// glance.
    var endDate: Date?

    /// Optional check-out time for `.stay` items (same `Date` shape as
    /// `startTime`). Only used when `endDate` is set.
    var endTime: Date?

    /// Ordering within a single day. Lower numbers render first; ties are
    /// broken by `createdAt`. Skeleton uses append-on-create (max + 1); a
    /// drag-to-reorder UI is a follow-up.
    var sortOrder: Int

    /// Item-level dedup signature for the email-ingest path (#143). A stable
    /// fingerprint of this item within its trip so forwarding the same booking
    /// twice (or re-scanning it) never creates a duplicate row. Empty for
    /// items created by chat/capture (they don't dedup), so this is purely
    /// additive: existing rows keep "". Set via `EmailItemDedupe`.
    var dedupeKey: String = ""

    /// Confirmation / reservation code from the source booking (e.g.
    /// "HM84R8EPNF") when one was found. Strongest dedup signal — two
    /// different emails of the same reservation share it. Empty when none was
    /// found or for non-email items. Additive: existing rows keep "".
    var sourceConfirmation: String = ""

    /// Optional street / postal address for this item's location. Populated
    /// when a forwarded booking email contains one, or typed manually in the
    /// editor. Empty when none. Stored with a default so adding it to an
    /// existing install is a safe lightweight migration (no data loss). Shown
    /// as a plain text line on the timeline card; the tappable map affordance
    /// lives on `googleMapsLink`.
    var address: String = ""

    /// Optional Google Maps URL for this item's location (#144). Populated when
    /// a forwarded booking email contains a maps link, or pasted manually in
    /// the editor. Empty when none. Stored with a default so adding it to an
    /// existing install is a safe lightweight migration (no data loss). Read
    /// via `mapsURL`; the timeline shows a tappable "MAP" chip only when this
    /// resolves to a non-nil URL.
    var googleMapsLink: String = ""

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        tripUUID: UUID,
        dayDate: Date,
        kind: ItineraryKind,
        title: String,
        notes: String = "",
        startTime: Date? = nil,
        endDate: Date? = nil,
        endTime: Date? = nil,
        sortOrder: Int = 0,
        address: String = "",
        googleMapsLink: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.tripUUID = tripUUID
        self.dayDate = dayDate
        self.kind = kind.rawValue
        self.title = title
        self.notes = notes
        self.startTime = startTime
        self.endDate = endDate
        self.endTime = endTime
        self.sortOrder = sortOrder
        self.address = address
        self.googleMapsLink = googleMapsLink
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Type-safe accessor backed by the stored raw `kind` string. Falls back
    /// to `.activity` if the stored value can't be decoded (e.g. an older
    /// schema added a kind that was later removed).
    var kindEnum: ItineraryKind {
        get { ItineraryKind(rawValue: kind) ?? .activity }
        set { kind = newValue.rawValue }
    }

    /// `true` when an explicit maps link has been stored. Distinct from
    /// `mapsURL != nil`, which is also true when the URL is derived from
    /// `address` (see below): this stays `false` for address-only items.
    var hasExplicitMapsLink: Bool {
        explicitMapsURL != nil
    }

    /// The stored Google Maps URL, coercing a bare host (e.g.
    /// "maps.app.goo.gl/…") into an https URL. `nil` when no link is saved or
    /// the stored string can't form a URL. This is the explicit link only; it
    /// does NOT fall back to `address` (that's `mapsURL`).
    private var explicitMapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let url = URL(string: stored), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(stored)")
    }

    /// A tappable maps URL for this item, used to render the "MAP" chip.
    /// Prefers the explicit `googleMapsLink` when present; otherwise DERIVES a
    /// Google Maps search URL from the title + `address`. This keeps a working
    /// map pin for any item that has an address but no stored link (e.g. items
    /// created before the link was persisted). `nil` only when there is no
    /// explicit link and no address.
    var mapsURL: URL? {
        if let explicit = explicitMapsURL { return explicit }
        return Self.googleMapsSearchURL(name: title, address: address)
    }

    /// Builds a Google Maps *search* URL that resolves to a specific place,
    /// combining the place name with the address so Google lands on the named
    /// venue (e.g. "207 Inn, Via Nazionale, Rome") rather than just the street.
    /// Returns `nil` when there is NO address: a bare title (e.g. "Lunch",
    /// "Free day") is not a reliable map target, so an item with no real
    /// location gets no link — and therefore no MAP chip. Dependency-free: no
    /// geocoding, no API call, no location permission.
    static func googleMapsSearchURL(name: String, address: String) -> URL? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }
        let query = [name.trimmingCharacters(in: .whitespacesAndNewlines), trimmedAddress]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: query)
        ]
        return components?.url
    }
}
