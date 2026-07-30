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

    /// Owning task, by UUID rather than a SwiftData relationship. The schema has
    /// zero `@Relationship` edges by design: the archive and the sync oplog both
    /// move flat records keyed on UUID, so a real relationship would have to be
    /// flattened on the way out and rebuilt on the way in.
    var todoClientUUID: UUID

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

    /// Whether this attachment earns a card in the Wallet (#405).
    ///
    /// The picker takes any document now (#400), so "attached to a task" stopped
    /// meaning "is a pass" — a brunch reservation was landing in the Wallet next
    /// to a boarding pass. Two things get one in:
    ///
    /// - Something scannable was decoded off it. Whatever it is for, you are going
    ///   to hold it under a reader, so the Wallet is where it belongs.
    /// - The extractor judged it a document you present at a door
    ///   (`TicketMeta.presentedAtEntry`), which catches the event ticket that
    ///   prints no code at all.
    ///
    /// An unjudged row falls back to the barcode alone. Every row written before
    /// the field existed is in that state, and reading its silence as "yes" would
    /// keep exactly the cards this is meant to remove.
    var belongsInWallet: Bool {
        hasBarcode || ticketMeta?.presentedAtEntry == true
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
