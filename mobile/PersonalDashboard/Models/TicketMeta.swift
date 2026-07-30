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

    /// Whether the holder physically presents this document to get in somewhere:
    /// a concert ticket, a match ticket, a boarding pass, a museum entry (#405).
    ///
    /// This is what separates a pass from a *record of a booking*. A restaurant
    /// reservation, a hotel enquiry, an appointment reminder and an order receipt
    /// are all worth keeping on the task, but you do not hold any of them up at a
    /// door — so they have no business in the Wallet, which exists to put the
    /// thing you are about to present one tap away.
    ///
    /// `nil` means nobody has judged it, which is the state every row written
    /// before this field existed is in. Callers must treat unknown as "don't
    /// know", never as "yes" — see `LocalTaskTicket.belongsInWallet`.
    var presentedAtEntry: Bool?

    /// The person's own answer to "does this belong in the Wallet", overriding
    /// whatever the extractor judged (#414).
    ///
    /// `presentedAtEntry` is a model's opinion about a document it saw once, and it
    /// gets things wrong in both directions: a padel court booking read as a match
    /// ticket, and somewhere out there a real pass it will refuse to admit.
    /// Correcting it used to mean deleting the attachment, which throws the file
    /// away to fix a display decision.
    ///
    /// `nil` means nobody has overridden anything and the automatic rule stands,
    /// which is where every row starts. A value wins outright, including over a
    /// decoded barcode: the reason to force a scannable document out is usually
    /// that it carries a code which admits nobody.
    var showInWallet: Bool?

    /// Hex SHA-256 of the file exactly as it was uploaded, before any
    /// compression (#408).
    ///
    /// This is what lets a second attempt at the same file be recognised as a
    /// repeat rather than attached again. It is stamped on the way in, so rows
    /// written before this field existed carry `nil` and are matched on their
    /// barcode payload instead. Hashing the ORIGINAL bytes rather than the
    /// stored JPEG is deliberate: the compression pipeline is free to change its
    /// constants, and an ingest fingerprint that shifts with them would stop
    /// recognising files it had already seen.
    var sourceHash: String?

    /// The event's own page, when the document or the task carries one (#412).
    ///
    /// Apple Wallet puts this on the BACK of a pass ("Event Page"), not on its face,
    /// and that is the right call: it is the thing you reach for before the event, not
    /// at the door. So it renders as an action on the detail surface rather than a chip
    /// on the card.
    ///
    /// Distinct from the barcode payload, which for a Luma pass is also a URL — the
    /// check-in link. That one admits you; this one tells you where you are going.
    var eventURL: String?

    /// The full postal address, when the document carries one beyond the venue's
    /// name (#420).
    ///
    /// A pass prints its location twice at different resolutions: "Lorong AI @
    /// One-North" on the face, where you are glancing at it, and "69 Ayer Rajah
    /// Cres., Level 3 Vidacity, Singapore 139961" on the back, where you are trying
    /// to get there. `venue` is the first; this is the second. Kept separate rather
    /// than overwriting the venue with the longer string, because the short form is
    /// what belongs on the card.
    var address: String?

    /// A map link the document itself supplied (#420).
    ///
    /// Preferred over a link derived from the address, because an issuer's own link
    /// resolves to the exact place — Luma ships a Google Maps URL carrying a
    /// `place_id`, which lands on the building rather than on a text search that may
    /// match three of them.
    var directionsURL: String?

    /// Everything else the document printed, as its own labels (#420).
    ///
    /// This is the field that stops the next pass needing a code change. Issuers
    /// print whatever they like — "Ticket: In-Person", "Dress code: smart casual",
    /// "Organiser", "Table" — and inventing a typed property here for each one means
    /// a new property, a new render site and a new editor row every time, forever.
    /// A pass already models this as labelled fields grouped by where they sit, so
    /// we keep that shape and render it generically.
    ///
    /// Only fields no typed property above already covers land here: the mapper
    /// consumes what it recognises first, so nothing is printed twice.
    var fields: [PassField]?

    /// One labelled field, positioned the way a pass positions its own.
    struct PassField: Codable, Equatable, Sendable, Hashable {
        /// Where the issuer put it. Drives which surface renders it: the card's face
        /// carries the front groups, and the detail surface — which is our
        /// equivalent of turning the pass over — carries `back`.
        enum Placement: String, Codable, Sendable, Hashable {
            case header, primary, secondary, auxiliary, back
        }

        var label: String
        var value: String
        var placement: Placement

        init(label: String, value: String, placement: Placement) {
            self.label = label
            self.value = value
            self.placement = placement
        }

        /// A field with no label is legal on a pass (the value stands alone) but has
        /// nothing to render against in a label-over-value list, so callers treat it
        /// as unusable rather than printing an unlabelled row.
        var isRenderable: Bool {
            !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// The value as an openable URL, when that is what it is. A pass puts its
        /// event page and its directions link in ordinary fields, and a row showing
        /// 180 characters of query string is worse than a row you can tap.
        var url: URL? {
            let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") else {
                return nil
            }
            return URL(string: raw)
        }
    }

    /// Who the ticket is issued to, when the document prints a name (#413).
    ///
    /// A Wallet pass carries this as an auxiliary field, and it is what fills that
    /// row on an event ticket with no seat, row or gate — which is most of them
    /// outside a stadium. Distinct from `passengerName`, which belongs to the
    /// boarding-pass layout and is parsed out of BCBP.
    var guestName: String?

    /// A transport ticket (flight / train) is styled as a boarding pass. We
    /// treat any item carrying both endpoint codes, or an explicit boarding
    /// pass flag, or a flight number, as boarding-pass shaped.
    var isTransport: Bool {
        if isBoardingPass == true { return true }
        if let f = flightNumber, !f.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let hasRoute = !(originCode ?? "").isEmpty && !(destinationCode ?? "").isEmpty
        return hasRoute
    }

    // MARK: - Generic fields

    /// Extra fields that belong on the card's face, in the issuer's own order.
    ///
    /// `header` and `primary` are excluded: those hold the date, the time and the
    /// event's name, which the card already draws as its hero and its title. Printing
    /// them again in the fact list is the duplication this whole mechanism exists to
    /// avoid.
    var faceFields: [PassField] {
        (fields ?? []).filter { $0.isRenderable && ($0.placement == .secondary || $0.placement == .auxiliary) }
    }

    /// Extra fields that belong on the back, which is our detail surface.
    var backFields: [PassField] {
        (fields ?? []).filter { $0.isRenderable && $0.placement == .back }
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
