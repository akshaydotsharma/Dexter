import Foundation

/// View-facing DTO for a todo. Identity is the `clientUUID` (here exposed
/// as `id` for Identifiable conformance), which is the sync key shared with
/// the server. The server's integer primary key is kept inside `LocalTodo`
/// for sync internals and never bubbles up to views — this lets locally
/// created todos render correctly before they have ever reached the server.
struct Todo: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, matches `LocalTodo.clientUUID` and the server's
    /// `client_uuid` column.
    let id: UUID
    var title: String
    var description: String?
    var completed: Bool
    var dueDate: Date?
    var tag: String?
    var position: Int?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    /// Optional street / postal address. Local-only (the server schema has no
    /// column for it), so it is omitted from `CodingKeys` and carries a default
    /// — Codable synthesis skips it on encode/decode and uses "" instead.
    var address: String = ""

    /// Optional Google Maps URL. Local-only, same handling as `address`.
    var googleMapsLink: String = ""

    /// Task priority as a raw `Int` (see `TaskPriority`). Local-only, same
    /// handling as `address`/`googleMapsLink`: defaulted and omitted from
    /// `CodingKeys` so the server sync contract is untouched.
    var priority: Int = 0

    /// Typed view of `priority` for the UI. Unknown raw values fall back to
    /// `.none` so a bad stored value never renders a blank/missing bar.
    var taskPriority: TaskPriority { TaskPriority(rawValue: priority) ?? .none }

    /// Server JSON has both `id` (int) and `client_uuid`; we map our `id`
    /// to `client_uuid` and ignore the server's int. The decoder's
    /// `.convertFromSnakeCase` strategy turns `client_uuid` into
    /// `clientUuid`, which is what the explicit raw value below matches.
    /// `address` / `googleMapsLink` are intentionally absent: they are local
    /// fields the server doesn't know about.
    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case title
        case description
        case completed
        case dueDate
        case tag
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }

    /// The stored Google Maps URL, coercing a bare host (e.g.
    /// "maps.app.goo.gl/…") into an https URL. `nil` when no link is saved or
    /// the stored string can't form a URL — the row hides the MAP chip then.
    var mapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let url = URL(string: stored), url.scheme != nil { return url }
        return URL(string: "https://\(stored)")
    }
}

/// View-facing DTO for a wallet-style ticket attached to a task (#399). Identity
/// is the clientUUID; the task link travels by UUID so a ticket added offline can
/// reference a task created offline. Entirely local — the server schema has no
/// notion of these, so there are no `CodingKeys` gymnastics here: this DTO is
/// only ever encoded into the backup archive and the sync oplog.
struct TaskTicket: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let todoId: UUID
    var attachmentPath: String
    var barcodePayload: String
    var barcodeSymbology: String
    var eventTitle: String
    var eventDate: Date?
    var startTimeText: String
    var venue: String
    var seat: String
    var gate: String
    var reference: String
    var ticketMetaJSON: String
    var position: Int
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    var hasBarcode: Bool {
        !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var hasAttachment: Bool {
        !attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Decoded extras (eventType, section, row), or `nil` when none are stored.
    var ticketMeta: TicketMeta? {
        TicketMeta.decode(ticketMetaJSON)
    }

    /// Typed symbology for the barcode renderer. `nil` when there is no barcode
    /// or the stored token is unrecognised, in which case the card falls back to
    /// the original image.
    var symbology: BarcodeSymbology? {
        BarcodeSymbology(rawValue: barcodeSymbology)
    }

    /// What the card shows as its headline: the event name when the extractor
    /// found one, otherwise the caller supplies the task's own title.
    func displayTitle(fallback: String) -> String {
        let trimmed = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return Self.completing(trimmed, with: fallback) ?? trimmed
    }

    /// `fallback` when it is the same name as `title`, finished (#413).
    ///
    /// Booking pages truncate their own headings, and the extractor is told to read
    /// verbatim, so a Luma check-in page yields the literal string
    /// `"Vibe Coders SG #2 - Securing Vibe Co..."`, ellipsis included. The task it is
    /// attached to holds the whole name, which makes the card's own title the worse of
    /// the two.
    ///
    /// Deliberately narrow: it fires only when the read value ENDS in an ellipsis and
    /// the fallback continues it, so it can complete a name and never replace one.
    /// Applied at render rather than on write, so rows already stored this way are
    /// fixed too with no migration.
    static func completing(_ title: String, with fallback: String) -> String? {
        let normalised = title.replacingOccurrences(of: "\u{2026}", with: "...")
        guard normalised.hasSuffix("...") else { return nil }
        let stripped = String(normalised.dropLast(3)).trimmingCharacters(in: .whitespaces)
        // Long enough that the prefix is a real name and not a couple of letters that
        // could match anything.
        guard stripped.count >= 8 else { return nil }
        let candidate = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count > stripped.count,
              candidate.lowercased().hasPrefix(stripped.lowercased()) else { return nil }
        return candidate
    }

    /// `true` when the extractor read nothing beyond the file itself. The detail
    /// sheet opens straight into its form for one of these, because a card that is
    /// blank apart from a barcode has nothing to look at and everything to fill in.
    var isBare: Bool {
        eventTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && venue.trimmingCharacters(in: .whitespaces).isEmpty
            && eventDate == nil
            && seat.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct TodoCreateRequest: Encodable {
    let title: String
    let description: String?
    let dueDate: Date?
    let tag: String?
    var address: String = ""
    var googleMapsLink: String = ""
    var priority: Int = 0
}

struct TodoUpdateRequest: Encodable {
    let title: String?
    let description: String?
    let completed: Bool?
    let dueDate: Date?
    let tag: String?
    /// `nil` leaves the stored value untouched; a value (incl. "") overwrites.
    var address: String? = nil
    var googleMapsLink: String? = nil
    /// `nil` leaves the stored priority untouched; a value overwrites it.
    var priority: Int? = nil
}
