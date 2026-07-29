import Foundation
import SwiftData

/// What kind of thing a standalone wallet card is (#398). Stored on
/// `LocalWalletCard.kind` as the `rawValue` so SwiftData stays on a plain
/// `String`, exactly like `LocalItineraryItem.kind` / `.transportMode`. New
/// kinds can be added later without a schema change.
///
/// The kind picks the card LAYOUT (see `layout`) and nothing else, so adding a
/// kind that reuses an existing layout is free.
enum WalletCardKind: String, CaseIterable, Identifiable, Hashable {
    /// A flight boarding pass.
    case boardingPass
    /// A rail / coach / ferry ticket. Reads as a pass, so it draws the
    /// boarding-pass layout with its own icon and eyebrow.
    case transit
    /// A concert, match, museum, theatre ticket.
    case event
    /// A hotel / accommodation booking.
    case stay
    /// Anything else scannable: a gym membership, a parking pass, a loyalty
    /// card. The catch-all so the wallet never refuses a card.
    case pass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .boardingPass: return "Boarding pass"
        case .transit:      return "Travel ticket"
        case .event:        return "Event ticket"
        case .stay:         return "Stay"
        case .pass:         return "Pass"
        }
    }

    /// SF Symbol for the kind picker and the wallet's source chip.
    var icon: String {
        switch self {
        case .boardingPass: return "airplane"
        case .transit:      return "tram.fill"
        case .event:        return "ticket"
        case .stay:         return "bed.double"
        case .pass:         return "wallet.pass"
        }
    }

    /// The eyebrow printed at the top of the card. Boarding passes and stays
    /// keep the wording the itinerary card already uses so a trip ticket and a
    /// standalone one are indistinguishable.
    var eyebrow: String {
        switch self {
        case .boardingPass: return "BOARDING PASS"
        case .transit:      return "TICKET"
        case .event:        return "TICKET"
        case .stay:         return "STAY"
        case .pass:         return "PASS"
        }
    }

    /// Which of the three existing ticket layouts draws this kind.
    var layout: TicketCardLayout {
        switch self {
        case .boardingPass, .transit: return .boardingPass
        case .stay:                   return .stay
        case .event, .pass:           return .event
        }
    }

    /// Best-guess kind from a `TicketExtraction` result, so an uploaded file
    /// lands on the right layout without asking the user. Mirrors the mapping
    /// `TicketExtraction.buildItem` applies for the trip path: a decoded
    /// boarding pass is authoritative, then the model's `kind` / `mode`, then a
    /// flight number, and finally the generic pass.
    static func infer(kind: String?, mode: String?, isBoardingPass: Bool, hasFlightNumber: Bool) -> WalletCardKind {
        if isBoardingPass { return .boardingPass }
        switch (kind ?? "").lowercased() {
        case "stay":
            return .stay
        case "transport":
            let resolved = TransportMode(rawValue: (mode ?? "").lowercased())
            return resolved == .flight || (resolved == nil && hasFlightNumber) ? .boardingPass : .transit
        case "activity":
            return .event
        default:
            return hasFlightNumber ? .boardingPass : .pass
        }
    }
}

/// A scannable card that lives in the wallet on its own, with no trip behind it
/// (#398).
///
/// Deliberately a SEPARATE model rather than a nullable `tripUUID` on
/// `LocalItineraryItem`: a trip item is a row on a day-by-day timeline and
/// half its schema (`dayDate` ordering, `sortOrder`, `dedupeKey`, the trip
/// foreign key) only means something inside a trip. Making that FK optional
/// would put an "is this a real itinerary row" branch into the timeline, the
/// email-ingest dedup and the trip cascade delete. A new model type is instead
/// a safe SwiftData lightweight migration and leaves all three untouched.
///
/// The ticket-shaped fields below are named EXACTLY as their
/// `LocalItineraryItem` counterparts so `TicketCardData` can project either one
/// with no per-source special-casing, and so a card moved between the two is a
/// field-for-field copy.
@Model
final class LocalWalletCard {
    @Attribute(.unique) var clientUUID: UUID

    /// `WalletCardKind.rawValue`. Read via `kindEnum`.
    var kind: String

    /// Card title (e.g. "SQ322 · SIN→LHR", "Coldplay · Wembley"). Required.
    var title: String

    /// The day this card is valid, normalised to `Calendar.startOfDay` in the
    /// device timezone. Same shape and rationale as
    /// `LocalItineraryItem.dayDate`: grouping and sorting by day is then a
    /// key-equality check that a timezone change can never move.
    var dayDate: Date

    /// Departure / start / doors-open time. Stored as a UTC wall-clock anchor
    /// (the stored `Date`'s UTC H:mm equals the time printed on the ticket), so
    /// a card keeps reading "19:00" wherever the device is. Matches
    /// `LocalItineraryItem.startTime`. `nil` for an untimed card.
    var startTime: Date?

    /// Arrival / end time for a travel card, same UTC wall-clock anchor.
    var arrivalTime: Date?

    /// Check-out day for a `.stay` card, start-of-day like `dayDate`.
    var endDate: Date?

    /// Check-out time for a `.stay` card, same UTC wall-clock anchor.
    var endTime: Date?

    /// Free-form notes. Empty when none.
    var notes: String = ""

    // MARK: - Ticket fields (mirror LocalItineraryItem, #222)

    var venue: String = ""
    var address: String = ""
    var googleMapsLink: String = ""
    var seat: String = ""
    var gate: String = ""
    /// Booking reference / PNR / order number as printed.
    var sourceConfirmation: String = ""
    /// Relative path into `Documents/tickets/` (shared with the trip path, so
    /// the archive's existing ticket-file bundling applies unchanged).
    var attachmentPath: String = ""
    var barcodePayload: String = ""
    var barcodeSymbology: String = ""
    /// `TicketMeta` as JSON, so new ticket shapes never force a migration.
    var ticketMetaJSON: String = ""

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        kind: WalletCardKind,
        title: String,
        dayDate: Date,
        startTime: Date? = nil,
        arrivalTime: Date? = nil,
        endDate: Date? = nil,
        endTime: Date? = nil,
        notes: String = "",
        venue: String = "",
        address: String = "",
        googleMapsLink: String = "",
        seat: String = "",
        gate: String = "",
        sourceConfirmation: String = "",
        attachmentPath: String = "",
        barcodePayload: String = "",
        barcodeSymbology: String = "",
        ticketMetaJSON: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.kind = kind.rawValue
        self.title = title
        self.dayDate = dayDate
        self.startTime = startTime
        self.arrivalTime = arrivalTime
        self.endDate = endDate
        self.endTime = endTime
        self.notes = notes
        self.venue = venue
        self.address = address
        self.googleMapsLink = googleMapsLink
        self.seat = seat
        self.gate = gate
        self.sourceConfirmation = sourceConfirmation
        self.attachmentPath = attachmentPath
        self.barcodePayload = barcodePayload
        self.barcodeSymbology = barcodeSymbology
        self.ticketMetaJSON = ticketMetaJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Type-safe accessor backed by the stored raw `kind`. Falls back to
    /// `.pass` (the catch-all layout) rather than guessing a travel shape when
    /// the stored value can't be decoded.
    var kindEnum: WalletCardKind {
        get { WalletCardKind(rawValue: kind) ?? .pass }
        set { kind = newValue.rawValue }
    }

    var ticketMeta: TicketMeta? {
        TicketMeta.decode(ticketMetaJSON)
    }

    /// `true` when the card carries something to present: a stored file and/or a
    /// decoded barcode. A manually typed card with neither is still a valid
    /// wallet entry (a confirmation code you read out at a desk), it just draws
    /// no perforation or stub.
    var hasTicket: Bool {
        !attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty
            || !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var hasBarcode: Bool {
        !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A tappable maps URL: the explicit link when stored, otherwise derived
    /// from venue/title + address. Reuses the itinerary item's builder so both
    /// surfaces resolve a place identically (and so neither invents a link for
    /// a card with no address).
    var mapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            if let url = URL(string: stored), url.scheme != nil { return url }
            return URL(string: "https://\(stored)")
        }
        return LocalItineraryItem.googleMapsSearchURL(
            name: venue.isEmpty ? title : venue,
            address: address
        )
    }
}
