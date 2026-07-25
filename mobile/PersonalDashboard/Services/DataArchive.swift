import Foundation

/// Wire format for the export / import archive.
///
/// Keep these DTOs decoupled from `@Model` classes so future SwiftData schema
/// changes don't force a manifest schema bump. The `schemaVersion` on
/// `DexterArchive` is the contract — bump it when the wire format breaks
/// backwards compatibility, and teach the importer the new version.
enum DataArchive {
    /// Bumped on any breaking change to the manifest shape. The importer
    /// rejects unknown versions with a user-readable error rather than
    /// guessing.
    static let currentSchemaVersion = 1

    /// Top-level envelope written as `manifest.json`.
    struct Manifest: Codable {
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String
        var data: Payload
    }

    struct Payload: Codable {
        var tasks: [TaskDTO]
        var notes: [NoteDTO]
        var noteFolders: [NoteFolderDTO]
        var lists: [ListDTO]
        var listItems: [ListItemDTO]
        var itineraries: [ItineraryDTO]
        var itineraryDays: [ItineraryDayDTO]
        var expenses: [ExpenseDTO]
        var vocab: [VocabDTO]

        static let empty = Payload(
            tasks: [], notes: [], noteFolders: [],
            lists: [], listItems: [],
            itineraries: [], itineraryDays: [],
            expenses: [], vocab: []
        )
    }

    // MARK: - Entity DTOs

    struct TaskDTO: Codable {
        let clientUUID: UUID
        let title: String
        let description: String?
        let completed: Bool
        let dueDate: Date?
        let tag: String?
        let position: Int?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?

        // MARK: Added in #319
        // `priority` is the visible one: dropping it flattened every restored
        // task to no priority on the app's most-used surface. Optional per the
        // #206 / #208 precedent, so v1 archives still decode.
        let priority: Int?
        let address: String?
        let googleMapsLink: String?
    }

    struct NoteDTO: Codable {
        let clientUUID: UUID
        let folderClientUUID: UUID?
        let title: String?
        let content: String?
        let position: Int?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct NoteFolderDTO: Codable {
        let clientUUID: UUID
        let name: String
        let position: Int?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
    }

    struct ListDTO: Codable {
        let clientUUID: UUID
        let title: String
        let position: Int?
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?

        // MARK: Added in #319 — list styling was previously dropped.
        let iconName: String?
        let colorHex: String?
    }

    /// Lists store their checklist items as a JSON blob inside the
    /// `LocalList` model. We flatten them out into separate DTOs in the
    /// archive so the wire format reads like a normalised dump rather
    /// than nesting opaque blobs. The importer re-attaches them by
    /// `listClientUUID` and preserves order via `position`.
    struct ListItemDTO: Codable {
        let listClientUUID: UUID
        let position: Int
        let text: String
        let checked: Bool

        // MARK: Added in #319
        // The flattening dropped `ChecklistItem.url`, so per-item links did not
        // survive a round trip. `ChecklistItem.id` is deliberately NOT carried:
        // it exists only to keep SwiftUI's ForEach animations stable, the model
        // mints a fresh one at decode time when absent, and it is not user
        // data. Recording that here so the omission reads as intentional.
        let url: String?
    }

    struct ItineraryDTO: Codable {
        let clientUUID: UUID
        let name: String
        let startDate: Date
        let endDate: Date
        let notes: String
        let createdAt: Date
        let updatedAt: Date

        // MARK: Added in #319
        // Trip participants (#258) were dropped entirely. Carried as the raw
        // `participantsData` blob rather than re-modelled, matching how
        // `ExpenseDTO.splitsData` is handled: the model's accessor already
        // decodes defensively and falls back to empty.
        let participantsData: Data?
    }

    /// "Itinerary day" in the manifest is a single timeline item on a trip
    /// day — matches `LocalItineraryItem`. The plural shape mirrors the
    /// language used on the ticket; this is the entity that holds the
    /// per-day rows on a trip's timeline.
    struct ItineraryDayDTO: Codable {
        let clientUUID: UUID
        let tripClientUUID: UUID
        let dayDate: Date
        let kind: String
        /// `TransportMode.rawValue` for a `.transport` item, empty otherwise.
        /// Optional in the archive so exports written before this field existed
        /// still decode (missing key -> nil -> "" on import).
        let transportMode: String?
        let title: String
        let notes: String
        let startTime: Date?
        let endDate: Date?
        let endTime: Date?
        let sortOrder: Int
        /// Optional in the archive so exports written before this field existed
        /// still decode (missing key -> nil -> "" on import).
        let googleMapsLink: String?
        let createdAt: Date
        let updatedAt: Date

        // MARK: Added in #319
        // Every field below was previously dropped, so a restore rebuilt the
        // timeline row but lost its ticket entirely. All optional, following the
        // #206 / #208 precedent above: a missing key decodes to nil and the
        // importer coalesces to the model's default, so v1 archives still load
        // and `schemaVersion` does not move.
        //
        // `attachmentPath` is only meaningful because #319 also teaches the
        // exporter to put the `tickets/<uuid>.<ext>` files INTO the archive.
        // Restoring the path without the file would set `hasTicket` true and
        // then fail to open it, which is worse than dropping the field.
        let arrivalTime: Date?
        let address: String?
        let dedupeKey: String?
        let sourceConfirmation: String?
        let attachmentPath: String?
        let barcodePayload: String?
        let barcodeSymbology: String?
        let seat: String?
        let gate: String?
        let venue: String?
        let ticketMetaJSON: String?
    }

    struct ExpenseDTO: Codable {
        let clientUUID: String
        let date: Date
        let category: String
        let merchant: String?
        let expenseDescription: String?
        let originalAmount: Double
        let originalCurrency: String
        let sgdAmount: Double
        let fxRate: Double
        let paymentMethod: String?
        let receiptImagePath: String?
        let source: String
        let createdAt: Date
        /// Refund direction (#206). Optional so archives written before this
        /// field existed still decode (missing key -> nil -> false on import,
        /// i.e. a plain expense).
        let isRefund: Bool?
        /// Verbatim statement descriptor used as the dedup key (#208). Optional
        /// so archives written before this field existed still decode (missing
        /// key -> nil -> "" on import, i.e. a legacy row matched on
        /// amount+date+currency alone).
        let dedupeDescriptor: String?

        // MARK: Added in #319
        // Previously dropped, which is why a restore could not reconstruct trip
        // expenses or settle-up at all: `personUUID`, `paidByPersonUUID`,
        // `splitsData` and `numberOfShares` are the whole of the participants /
        // shares feature (#258-#261, #264), and without `tripUUID` a trip
        // expense came back as a loose Finance row.
        //
        // `hiddenFromFinance` / `hiddenFromTrip` matter more than they look: a
        // restore that loses them resurrects per-surface deletions the user
        // already made. And dropping `dedupeKey` / `statementLabel` /
        // `statementFileName` meant re-importing a statement after a restore
        // re-duplicated every transaction, reintroducing the class #206-#209
        // fixed.
        //
        // All optional, per the precedent above; v1 archives still decode.
        let tripUUID: UUID?
        let sourceReference: String?
        let statementLabel: String?
        let statementFileName: String?
        let personUUID: UUID?
        let personName: String?
        let eventUUID: UUID?
        let eventName: String?
        let numberOfShares: Int?
        let paidByPersonUUID: UUID?
        /// Raw JSON blob from `LocalExpense.splitsData`, carried verbatim rather
        /// than re-modelled: the accessor already decodes defensively and falls
        /// back to empty, so a byte-for-byte round trip is the safest shape.
        let splitsData: Data?
        let hiddenFromFinance: Bool?
        let hiddenFromTrip: Bool?
        let dedupeKey: String?
    }

    struct VocabDTO: Codable {
        let clientUUID: UUID
        let term: String
        let notes: String
        let createdAt: Date
        let updatedAt: Date
    }

    // MARK: - Encoder / Decoder

    /// Manifest JSON uses ISO-8601 dates (with fractional seconds) so the
    /// archive is human-readable and survives non-Apple consumers.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
