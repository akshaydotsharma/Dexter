import Foundation
import SwiftData

/// Category of an itinerary item. Stored on `LocalItineraryItem.kind` as the
/// `rawValue` so SwiftData stays on plain `String` (no custom-codable
/// migrations to worry about). The skeleton ships four kinds; new ones can be
/// added without a schema change.
enum ItineraryKind: String, CaseIterable, Identifiable, Hashable {
    case stay
    case transport
    case activity
    case place
    case restaurant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stay:       return "Stay"
        case .transport:  return "Transport"
        case .activity:   return "Activity"
        case .place:      return "Place"
        case .restaurant: return "Restaurant"
        }
    }

    /// SF Symbol used in row icons and the kind picker chips. For `.transport`
    /// this is only a generic fallback — the timeline and picker prefer the
    /// per-mode icon from `TransportMode.icon` when a mode is set on the item.
    var icon: String {
        switch self {
        case .stay:       return "bed.double"
        case .transport:  return "airplane"
        case .activity:   return "figure.walk"
        case .place:      return "mappin.and.ellipse"
        case .restaurant: return "fork.knife"
        }
    }
}

/// Mode of a `.transport` itinerary item. Stored on
/// `LocalItineraryItem.transportMode` as the `rawValue` (String) so it needs no
/// custom-codable migration, mirroring `ItineraryKind`. Only meaningful when
/// `kind == .transport`; other kinds leave it empty. Drives the per-mode icon
/// and label shown on the timeline row and the mode picker in the editor.
enum TransportMode: String, CaseIterable, Identifiable, Hashable {
    case flight
    case train
    case car
    case bus
    case ferry
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flight: return "Flight"
        case .train:  return "Train"
        case .car:    return "Car"
        case .bus:    return "Bus"
        case .ferry:  return "Ferry"
        case .other:  return "Transport"
        }
    }

    /// SF Symbol shown on the timeline row and mode picker chips.
    var icon: String {
        switch self {
        case .flight: return "airplane"
        case .train:  return "tram.fill"
        case .car:    return "car.fill"
        case .bus:    return "bus.fill"
        case .ferry:  return "ferry.fill"
        case .other:  return "arrow.left.arrow.right"
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

    /// `TransportMode.rawValue` for a `.transport` item (flight/train/car/…),
    /// empty for every other kind. Stored as a String and read via
    /// `transportModeEnum`. Additive with a "" default so adding it to an
    /// existing install is a safe lightweight migration; NEVER remove or rename.
    var transportMode: String = ""

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

    /// Optional arrival / end time for a timed `.activity` item (a flight's
    /// landing time, a train's arrival). Stored as UTC wall-clock exactly like
    /// `startTime` — the stored `Date`'s UTC hour:minute equals the booking's
    /// stated local time, so the timeline shows "10:35 → 15:35" without drifting
    /// when the device timezone changes. Only meaningful when `startTime` is
    /// also set. `nil` for untimed items and for kinds other than `.activity`
    /// or `.transport` (a flight/train arrival is a transport arrival).
    /// Distinct from `endTime`, which is the stay-only check-out time. Additive
    /// with a `nil` default so adding it to an existing install is a safe
    /// lightweight migration (no data loss); NEVER remove or rename it.
    var arrivalTime: Date?

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

    // MARK: - Wallet-style ticket fields (#222)
    //
    // All ADDITIVE with defaults so SwiftData's lightweight migration is safe on
    // existing installs, and a code revert leaves them as harmless dead columns.
    // NEVER remove or rename these. An item is a "ticket" when it carries either
    // a stored attachment or a decoded barcode payload (see `hasTicket`).

    /// Relative path to the original uploaded ticket file in
    /// `Documents/tickets/<uuid>.{jpg|pdf}` (mirrors `LocalExpense.receiptImagePath`).
    /// Empty when the item has no attachment. Resolved via `TicketStorage.load`.
    var attachmentPath: String = ""

    /// Raw decoded barcode payload (e.g. the IATA BCBP "M1..." string, a QR
    /// URL, or a numeric code). Empty when no barcode was found. Re-rendered on
    /// the scan screen in its original symbology so a gate scanner can read it.
    var barcodePayload: String = ""

    /// Normalised symbology id for `barcodePayload`: "qr" / "aztec" / "pdf417" /
    /// "code128" / "other". Drives which CoreImage generator re-renders the
    /// code. Empty when there is no barcode. See `BarcodeSymbology`.
    var barcodeSymbology: String = ""

    /// Seat assignment as printed (e.g. "12A", "Coach 4 / 21"). Empty when none.
    /// A real column (not in `ticketMetaJSON`) because both the card and the
    /// scan screen surface it prominently.
    var seat: String = ""

    /// Gate / boarding gate as printed (e.g. "B22"). Empty when none.
    var gate: String = ""

    /// Venue / location label for an event ticket (e.g. "The O2, London").
    /// Distinct from `address` (the postal address used for the map link):
    /// `venue` is the human name shown on the card. Empty when none.
    var venue: String = ""

    /// Flexible ticket extras as a JSON string (airline, flightNumber,
    /// originCode/destinationCode, terminal, section, row, eventType, …).
    /// Encoded/decoded via `TicketMeta`. Empty string when there are no extras.
    /// Kept as JSON so new ticket shapes never force another @Model migration.
    var ticketMetaJSON: String = ""

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        tripUUID: UUID,
        dayDate: Date,
        kind: ItineraryKind,
        transportMode: TransportMode? = nil,
        title: String,
        notes: String = "",
        startTime: Date? = nil,
        endDate: Date? = nil,
        endTime: Date? = nil,
        arrivalTime: Date? = nil,
        sortOrder: Int = 0,
        address: String = "",
        googleMapsLink: String = "",
        attachmentPath: String = "",
        barcodePayload: String = "",
        barcodeSymbology: String = "",
        seat: String = "",
        gate: String = "",
        venue: String = "",
        ticketMetaJSON: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.tripUUID = tripUUID
        self.dayDate = dayDate
        self.kind = kind.rawValue
        self.transportMode = transportMode?.rawValue ?? ""
        self.title = title
        self.notes = notes
        self.startTime = startTime
        self.endDate = endDate
        self.endTime = endTime
        self.arrivalTime = arrivalTime
        self.sortOrder = sortOrder
        self.address = address
        self.googleMapsLink = googleMapsLink
        self.attachmentPath = attachmentPath
        self.barcodePayload = barcodePayload
        self.barcodeSymbology = barcodeSymbology
        self.seat = seat
        self.gate = gate
        self.venue = venue
        self.ticketMetaJSON = ticketMetaJSON
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

    /// Type-safe accessor for a `.transport` item's mode, backed by the stored
    /// raw `transportMode` string. `nil` when unset or unrecognised (e.g. a
    /// non-transport item, or an older row). The timeline row and picker fall
    /// back to `kindEnum.icon`/`.displayName` when this is `nil`.
    var transportModeEnum: TransportMode? {
        get { TransportMode(rawValue: transportMode) }
        set { transportMode = newValue?.rawValue ?? "" }
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

    // MARK: - Ticket accessors (#222)

    /// `true` when this item should render as a wallet-style ticket card: it
    /// carries an uploaded attachment and/or a decoded barcode. Items without
    /// either render exactly as before (plain timeline row).
    var hasTicket: Bool {
        !attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty
            || !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `true` when a barcode payload exists that we can either re-render or fall
    /// back to the attachment for. Gates the "scan" affordance on the card.
    var hasBarcode: Bool {
        !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Decoded ticket extras, or `nil` when none are stored. Cheap enough to
    /// decode on demand at render time (the JSON is a few hundred bytes).
    var ticketMeta: TicketMeta? {
        TicketMeta.decode(ticketMetaJSON)
    }

    /// Whether to use the boarding-pass layout (big origin→destination codes)
    /// vs the event-ticket layout. Boarding-pass when the meta says it's a
    /// transport ticket.
    var isBoardingPassStyle: Bool {
        ticketMeta?.isTransport ?? false
    }

    /// `true` when a `.stay` carries any booking info worth surfacing as a
    /// wallet-style stay card: a source confirmation code (the common
    /// email-imported hotel case), an uploaded attachment, or a decoded barcode.
    /// A stay is a *duration*, not a moment, so it stays a compact timeline row
    /// on both its check-in and check-out days; this flag instead drives a
    /// discoverability chip on the row and a tap that opens the stay card in a
    /// detail sheet. A bare, manually-added stay (none of these) keeps the plain
    /// row and the plain tap-to-edit behavior. Always `false` for non-stay kinds.
    var hasStayBooking: Bool {
        guard kindEnum == .stay else { return false }
        return !sourceConfirmation.trimmingCharacters(in: .whitespaces).isEmpty || hasTicket
    }
}
