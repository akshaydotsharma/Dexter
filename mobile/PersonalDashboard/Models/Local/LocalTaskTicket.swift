import Foundation
import SwiftData

/// A wallet-style ticket attached to a task (#399).
///
/// A separate model rather than fields on `LocalTodo`, for the two reasons #395
/// gave for `LocalNoteImage`: a task can hold more than one ticket (two seats, or
/// a ticket plus a parking pass), and `LocalTodo` is one of the 15 live models
/// whose schema is risky to alter — adding a NEW model is a safe lightweight
/// migration, widening an existing one is the operation that can fail on an
/// install with real data in it.
///
/// The ticket payload mirrors the `LocalItineraryItem` #222 block field for
/// field, minus everything travel-specific. There is no route, no airline and no
/// BCBP parse here: an event ticket has no equivalent grammar.
///
/// ## Why the time is a string
///
/// `eventDate` carries the DAY only and `startTimeText` carries the time exactly
/// as printed on the ticket. Storing a single absolute `Date` is what caused
/// #163 / #168, where a 20:00 Milan booking rendered as 17:30 because the phone
/// was in another timezone — and a ticket is the worst case for that bug, since
/// the number on the card has to match the number the gate is reading. Keeping
/// the printed string means it cannot drift, whatever timezone the phone is in.
///
/// ## These rows sync but their files do not
///
/// Registered with sync like every other archived entity, so a task's ticket
/// rows reach the other device. The oplog carries JSON only and has no asset
/// transfer, so the JPEGs and PDFs stay on the device that created them — the
/// same position receipts, itinerary tickets and note images are already in. The
/// card renders an explicit "on your other device" state for a row whose file is
/// missing, which also covers the reinstall case. Files cross devices through
/// the export archive.
@Model
final class LocalTaskTicket {
    @Attribute(.unique) var clientUUID: UUID

    /// Owning record, by UUID rather than a SwiftData relationship. The schema has
    /// zero `@Relationship` edges by design: the archive and the sync oplog both
    /// move flat records keyed on UUID, so a real relationship would have to be
    /// flattened on the way out and rebuilt on the way in.
    ///
    /// Named for the task because that is all it held when it was written. Since
    /// #432 it carries whichever record owns the document — a `LocalTodo` or a
    /// `LocalItineraryItem` — and `itineraryItemUUID` below says which. The name
    /// stays put: a stored property's name is part of the schema, and renaming it
    /// to `ownerClientUUID` would be a migration bought with nothing but tidiness.
    var todoClientUUID: UUID

    /// Set to the trip stop's `clientUUID` when this document belongs to an
    /// itinerary stop rather than a task (#432). `nil` for a task's.
    ///
    /// Additive with a `nil` default, so every row written before this existed
    /// decodes as a task's — which is what they all are. NEVER remove or rename it.
    ///
    /// Deliberately a discriminator and not the only owner column: `todoClientUUID`
    /// carries the id either way, so every predicate that already filtered on it
    /// keeps working untouched. A task's id and a stop's id are both freshly minted
    /// UUIDs, so a task query can never match a stop's row by accident.
    var itineraryItemUUID: UUID? = nil

    /// Relative to Documents, e.g. `task-tickets/9f2c….jpg` or `….pdf`. Empty
    /// when the row carries only a barcode. Resolved via
    /// `TicketStorage.taskTickets.load`. Relative and not absolute because the
    /// container path changes on every reinstall, so an absolute path would be
    /// dead the moment it was stored.
    var attachmentPath: String = ""

    /// Raw decoded barcode payload (a QR URL, a numeric code, an order string).
    /// Empty when no barcode was found. Re-rendered on display rather than
    /// cropped out of the original, so the card scans even when the source photo
    /// was poor.
    var barcodePayload: String = ""

    /// Normalised symbology id for `barcodePayload`: "qr" / "aztec" / "pdf417" /
    /// "code128" / "other". Empty when there is no barcode. See
    /// `BarcodeSymbology`. `other` means decodable but not regeneratable, and
    /// falls back to the original image cropped to the code.
    var barcodeSymbology: String = ""

    /// Event name as printed. Falls back to the owning task's title on the card
    /// when the extractor could not read one.
    var eventTitle: String = ""

    /// Day of the event, normalised to start-of-day. Nil when unknown.
    var eventDate: Date?

    /// Start time exactly as printed on the ticket ("20:00", "7.30pm",
    /// "Doors 19:00"). Never reformatted. See the note above on why this is not
    /// a `Date`.
    var startTimeText: String = ""

    /// Venue / location label ("National Stadium, Singapore").
    var venue: String = ""

    var seat: String = ""
    var gate: String = ""

    /// Booking / order reference, shown on the tear-off stub beneath the barcode.
    var reference: String = ""

    /// Flexible extras as a JSON string (eventType, section, row), encoded and
    /// decoded via `TicketMeta` — the same already-model-agnostic struct the
    /// itinerary card uses. Kept as JSON so new ticket shapes never force
    /// another @Model migration. Empty string when there are no extras.
    var ticketMetaJSON: String = ""

    /// Display order within the task, ascending.
    var position: Int

    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// Intentional dead field, kept for parity with the other local models and
    /// for migration safety — removing a field is the risky direction.
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        todoClientUUID: UUID,
        itineraryItemUUID: UUID? = nil,
        attachmentPath: String = "",
        barcodePayload: String = "",
        barcodeSymbology: String = "",
        eventTitle: String = "",
        eventDate: Date? = nil,
        startTimeText: String = "",
        venue: String = "",
        seat: String = "",
        gate: String = "",
        reference: String = "",
        ticketMetaJSON: String = "",
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.todoClientUUID = todoClientUUID
        self.itineraryItemUUID = itineraryItemUUID
        self.attachmentPath = attachmentPath
        self.barcodePayload = barcodePayload
        self.barcodeSymbology = barcodeSymbology
        self.eventTitle = eventTitle
        self.eventDate = eventDate
        self.startTimeText = startTimeText
        self.venue = venue
        self.seat = seat
        self.gate = gate
        self.reference = reference
        self.ticketMetaJSON = ticketMetaJSON
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsSync = needsSync
    }

    // MARK: - Accessors

    /// What this document hangs off (#432), reconstructed from the two stored
    /// columns. One place decides it, so no caller has to remember that a `nil`
    /// discriminator means "task".
    var owner: TicketOwner {
        if let itineraryItemUUID { return .tripStop(itineraryItemUUID) }
        return .task(todoClientUUID)
    }

    /// `true` when there is a payload we can either re-render or fall back to a
    /// crop of. Drives whether the card grows its perforation and stub.
    var hasBarcode: Bool {
        !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `true` when a file was stored for this row.
    var hasAttachment: Bool {
        !attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Decoded extras, or `nil` when none are stored.
    var ticketMeta: TicketMeta? {
        TicketMeta.decode(ticketMetaJSON)
    }

    /// `true` when the extractor read nothing beyond the file itself, so the UI
    /// should open the fields for manual entry rather than present a card that is
    /// blank apart from a barcode.
    var isBare: Bool {
        eventTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && venue.trimmingCharacters(in: .whitespaces).isEmpty
            && eventDate == nil
            && seat.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func toDTO() -> TaskTicket {
        TaskTicket(
            id: clientUUID,
            todoId: todoClientUUID,
            itineraryItemUUID: itineraryItemUUID,
            attachmentPath: attachmentPath,
            barcodePayload: barcodePayload,
            barcodeSymbology: barcodeSymbology,
            eventTitle: eventTitle,
            eventDate: eventDate,
            startTimeText: startTimeText,
            venue: venue,
            seat: seat,
            gate: gate,
            reference: reference,
            ticketMetaJSON: ticketMetaJSON,
            position: position,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

// MARK: - Wallet eligibility

/// The rule deciding whether a task attachment earns a card in the Wallet,
/// written once for both shapes it is asked about (#414).
///
/// The stored row is what the Wallet itself builds from, and the DTO is what the
/// detail sheet holds while showing the switch that overrides it. Two copies of
/// this predicate would be two chances for the switch to disagree with the shelf
/// it moves things on and off.
protocol WalletEligible {
    var hasBarcode: Bool { get }
    var barcodePayload: String { get }
    var ticketMeta: TicketMeta? { get }
    var reference: String { get }
    var seat: String { get }
    var gate: String { get }
}

/// What the scannable thing on a document is FOR (#435).
///
/// `hasBarcode` answers "is there something to draw", which is the right question
/// for rendering and the wrong one for the Wallet. A car rental voucher carries a
/// QR that opens Sixt's manage-my-booking page: real, scannable, and it admits
/// nobody. Holding that up at a counter achieves nothing, so the document is a
/// booking record with a link on it, not a pass.
///
/// The distinction is legible because vendors name their own endpoints after what
/// they do: `luma.com/check-in/...` against `sixt.com/account/#/manage-my-booking-info`.
enum BarcodePurpose: Equatable {
    /// Nothing decoded.
    case none

    /// Not a web address, so it is a machine credential by construction: an
    /// opaque token, an IATA boarding pass string, a membership number. The only
    /// thing that reads it is a reader at a door.
    case credential

    /// A web address that says it admits you.
    case entryLink

    /// A web address that says it manages, views or pays for the booking.
    case selfServiceLink

    /// A web address that says neither, so it decides nothing on its own.
    case unknownLink
}

extension BarcodePurpose {

    /// Path fragments that mean "this link is how you get in". Checked first, so a
    /// check-in link hosted under an account path still counts: wrongly keeping a
    /// card costs a glance, wrongly dropping one costs you the gate.
    private static let entryMarkers = [
        "check-in", "checkin", "check_in", "boarding", "boardingpass",
        "ticket", "pass", "admit", "entry", "entrance", "scan",
        "validate", "verify", "gate"
    ]

    /// Path fragments that mean "this link is how you change or review the
    /// booking". Everything here is something you do sitting down, at leisure,
    /// which is the opposite of presenting a pass.
    private static let selfServiceMarkers = [
        "manage", "my-booking", "mybooking", "booking-info", "bookinginfo",
        "reservation-details", "account", "profile", "modify", "amend",
        "change", "cancel", "reschedule", "receipt", "invoice", "billing",
        "feedback", "survey", "review", "unsubscribe", "download",
        "help", "support", "faq", "terms"
    ]

    /// Classify a decoded payload.
    static func classify(_ payload: String) -> BarcodePurpose {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard let tail = webAddressTail(of: trimmed) else { return .credential }
        if entryMarkers.contains(where: tail.contains) { return .entryLink }
        if selfServiceMarkers.contains(where: tail.contains) { return .selfServiceLink }
        return .unknownLink
    }

    /// Everything after the host when `payload` is a web address, lowercased, or
    /// `nil` when it is not one.
    ///
    /// The scheme is optional on purpose: the payload that prompted this is
    /// `sixt.com/account/...` with no `https://` on the front. A host is taken to
    /// be a dotted label before the first slash, which is what keeps an IATA
    /// boarding pass out — `M1SHARMA/AKSHAY ...` splits on a slash too, but
    /// `M1SHARMA` carries no dot.
    private static func webAddressTail(of payload: String) -> String? {
        var body = payload.lowercased()
        for scheme in ["https://", "http://"] where body.hasPrefix(scheme) {
            body.removeFirst(scheme.count)
        }
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let host = body[body.startIndex..<slash]
        guard host.contains("."), !host.contains(" ") else { return nil }
        guard let tld = host.split(separator: ".").last, tld.count >= 2,
              tld.allSatisfy(\.isLetter) else { return nil }
        return String(body[slash...])
    }
}

extension WalletEligible {
    /// Whether this attachment earns a card in the Wallet (#405, narrowed by #414).
    ///
    /// The picker takes any document now (#400), so "attached to a task" stopped
    /// meaning "is a pass" — a brunch reservation was landing in the Wallet next
    /// to a boarding pass. Three things decide it, in this order:
    ///
    /// - The person said so (`TicketMeta.showInWallet`). Their answer beats every
    ///   rule below, in both directions.
    /// - Something scannable was decoded off it. Whatever it is for, you are going
    ///   to hold it under a reader, so the Wallet is where it belongs.
    /// - The extractor judged it a document you present at a door
    ///   (`TicketMeta.presentedAtEntry`) AND the document prints something you can
    ///   actually present. That last clause is #414: a padel court booking came
    ///   back judged a pass with no barcode, no reference, no seat and no gate, so
    ///   the Wallet held a card that could not be shown to anyone. A judgement
    ///   with nothing behind it is an opinion, not a pass.
    ///
    /// An unjudged row falls back to the barcode alone. Every row written before
    /// the field existed is in that state, and reading its silence as "yes" would
    /// keep exactly the cards this is meant to remove.
    ///
    /// #435 split the barcode arm by what the code is FOR. "Something scannable"
    /// was standing in for "a credential", and a car rental voucher broke the
    /// substitution: its QR opens the rental company's manage-my-booking page.
    /// That is a real barcode that admits nobody, so it now argues AGAINST a card
    /// rather than for one. Anything that is not a web address stays a credential
    /// by construction, which is what keeps every opaque cinema token and every
    /// IATA boarding pass exactly where it was.
    var belongsInWallet: Bool {
        if let override = ticketMeta?.showInWallet { return override }
        switch BarcodePurpose.classify(barcodePayload) {
        case .credential, .entryLink:
            return true
        case .selfServiceLink:
            // Deliberately absolute, and it outranks `presentedAtEntry`: the
            // extractor reads the presence of a QR as proof of access and said
            // yes to the rental voucher for that reason. When the only scannable
            // thing on a document is a link for changing the booking, there is
            // nothing on it to show anyone, whatever else it prints. The person's
            // own override is checked above and still wins.
            return false
        case .none, .unknownLink:
            guard ticketMeta?.presentedAtEntry == true else { return false }
            return hasPresentableCredential
        }
    }

    /// `true` when the document prints something the holder can show at the door:
    /// a booking reference, a seat, a gate, or a section and row.
    ///
    /// Deliberately does NOT count the attachment file. Every task ticket has one
    /// by construction, so admitting on that basis would make the rule above a
    /// no-op — and the file arrives with a court booking, a menu or a receipt just
    /// as readily as with a ticket.
    var hasPresentableCredential: Bool {
        let meta = ticketMeta
        let candidates = [reference, seat, gate, meta?.section ?? "", meta?.row ?? ""]
        return candidates.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

extension LocalTaskTicket: WalletEligible {}
