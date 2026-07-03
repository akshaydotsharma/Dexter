import Foundation

/// Flexible "extras" bag for a wallet-style ticket, persisted as a JSON string
/// on `LocalItineraryItem.ticketMetaJSON`. Kept OUT of the SwiftData schema as
/// discrete columns on purpose: ticket shapes vary wildly (a boarding pass has
/// a route + cabin + flight number; a concert ticket has a section + row + event
/// type) and encoding the long tail as JSON means new ticket kinds never force
/// another risky @Model migration. Only the few fields the card/scan surfaces
/// index on directly (`seat`, `gate`, `venue`) live as real columns.
///
/// Every field is optional. A blank/absent field simply doesn't render its
/// chip. `nil` decodes cleanly from an empty `ticketMetaJSON` (see
/// `TicketMeta.decode`), so an item with no ticket carries no meta and reverts
/// to the plain timeline row.
struct TicketMeta: Codable, Equatable, Sendable {
    // Flight / transport
    var airline: String?
    var flightNumber: String?
    var originCode: String?         // IATA airport / station code, e.g. "SIN"
    var destinationCode: String?
    var originCity: String?         // Human label, e.g. "Singapore"
    var destinationCity: String?
    var terminal: String?
    var cabin: String?              // "Economy", "Business", etc.
    var passengerName: String?
    var boardingTime: String?       // Free-form display string as printed

    // Event / seated ticket
    var eventType: String?          // "Concert", "Match", "Theatre", …
    var section: String?
    var row: String?

    /// True when the payload was a decoded IATA BCBP boarding pass. Drives the
    /// card's boarding-pass vs event-ticket layout selection alongside the
    /// presence of route codes.
    var isBoardingPass: Bool?

    /// A transport ticket (flight / train) is styled as a boarding pass. We
    /// treat any item carrying both endpoint codes, or an explicit boarding
    /// pass flag, or a flight number, as boarding-pass shaped.
    var isTransport: Bool {
        if isBoardingPass == true { return true }
        if let f = flightNumber, !f.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let hasRoute = !(originCode ?? "").isEmpty && !(destinationCode ?? "").isEmpty
        return hasRoute
    }

    // MARK: - JSON string round-trip

    /// Decode a `TicketMeta` from a stored JSON string. Returns `nil` for an
    /// empty string or unparseable JSON, so callers can treat "no meta" and
    /// "bad meta" identically (the row falls back to the plain layout).
    static func decode(_ json: String) -> TicketMeta? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TicketMeta.self, from: data)
    }

    /// Encode to a compact JSON string for persistence. Returns "" on failure
    /// so the stored field stays a harmless empty string rather than throwing.
    func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    /// True when there's nothing worth persisting (every field empty). Lets the
    /// extractor skip stamping an empty `{}` blob.
    var isEmpty: Bool {
        self == TicketMeta()
    }
}

// MARK: - Short-code sanitizer (#222)

/// Guards against a class of junk the extractor (or a mis-parse) can put into a
/// short code field like gate / terminal: a bare separator, a placeholder word,
/// or a single stray letter grabbed off the ticket ("Terminal T"). A real
/// terminal reads like "1", "T2", "2B"; a real gate like "14", "A22". Anything
/// that fails this test is treated as *unknown* rather than displayed verbatim,
/// because showing a fabricated value is worse than showing nothing.
enum TicketField {
    /// Placeholder tokens that never represent a real value (case-insensitive).
    private static let placeholders: Set<String> = [
        "-", "–", "—", "--", "―", "•", ".",
        "TBD", "TBA", "N/A", "NA", "NONE", "NULL", "NIL", "?", "N.A."
    ]

    /// Returns a meaningful code, or `nil` when the input is empty, a
    /// placeholder, or a lone letter (e.g. a stray "T"/"G"). A single *digit*
    /// (gate 1, terminal 2) is kept — only bare letters are rejected.
    static func code(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if placeholders.contains(trimmed.uppercased()) { return nil }
        if trimmed.count == 1, let only = trimmed.first, only.isLetter { return nil }
        return trimmed
    }

    /// The em-width dash shown in a card chip when a code is unknown, so the
    /// slot stays present (and the grid stays balanced) without inventing data.
    static let unknownDash = "–"
}
