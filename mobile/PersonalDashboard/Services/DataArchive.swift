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

        // MARK: Added in #319 — self-verification.
        //
        // `models` is the list of model names this archive CLAIMS to carry, and
        // is the only way to detect a model omitted entirely: a per-model count
        // catches truncation, but a model that was never exported has no count
        // to mismatch against, which is exactly the bug #319 exists to fix.
        // Deliberate exclusions are listed too (see `excludedModels`) so a
        // reader can tell intent from regression.
        //
        // `counts` is asserted on import BEFORE anything is written, so a
        // mismatch is a clean refusal rather than a half-restored store.
        //
        // Both optional and both nil on a v1 archive, which the importer treats
        // as "unverifiable, proceed and warn" — never as "expected zero". A
        // strict equality check would reject every backup the user already
        // holds as corrupt, which is worse than the bug being fixed.
        var models: [String]? = nil
        var counts: [String: Int]? = nil
        var excludedModels: [String]? = nil
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

        // MARK: Added in #319
        // Five models that were never exported at all. Optional with a nil
        // default so v1 archives (which have no such keys) still decode and so
        // `Payload.empty` below keeps compiling unchanged.
        var recurringExpenses: [RecurringExpenseDTO]? = nil
        var persons: [PersonDTO]? = nil
        var events: [EventDTO]? = nil
        var statementImports: [StatementImportDTO]? = nil
        var processedEmails: [ProcessedEmailDTO]? = nil

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
    // MARK: - Models added in #319
    //
    // These five were registered in the schema but had no DTO and no fetch, so
    // they were silently absent from every archive the app has ever written.

    /// `RecurringExpense`. Without this, every recurring template vanished on
    /// restore and the user's monthly bills stopped posting.
    struct RecurringExpenseDTO: Codable {
        let clientUUID: String
        let amount: Double
        let currency: String
        let category: String
        let merchant: String?
        let expenseDescription: String?
        let paymentMethod: String?
        let dayOfMonth: Int
        let isActive: Bool
        let startDate: Date
        let endDate: Date?
        /// Carried so a restored template does not re-post a month it already
        /// posted. Dropping it would double-charge the current month.
        let lastPostedMonthKey: String?
        let createdAt: Date
        let updatedAt: Date
    }

    /// `LocalPerson`. Load-bearing for trip settle-up: expense splits reference
    /// people by UUID, so without the people themselves the splits restore as
    /// dangling references and the feature cannot be reconstructed.
    struct PersonDTO: Codable {
        let clientUUID: UUID
        let name: String
        let colorHex: String
        let createdAt: Date
    }

    /// `LocalEvent`. Same reasoning as `PersonDTO`: expenses tag events by UUID.
    struct EventDTO: Codable {
        let clientUUID: UUID
        let name: String
        let startDate: Date?
        let endDate: Date?
        let tripUUID: UUID?
        let notes: String
        let createdAt: Date
        let updatedAt: Date
    }

    /// `LocalStatementImport`. The import-history record. Without it a restored
    /// device has no record of which statements were already ingested.
    struct StatementImportDTO: Codable {
        let clientUUID: UUID
        let fileName: String
        let statementLabel: String
        let imported: Int
        let skippedDuplicates: Int
        let ignoredNonSpend: Int
        let failed: Int
        let refunds: Int
        let deposits: Int
        let possiblyTruncated: Bool
        /// Comma-joined on the model; carried verbatim.
        let importedExpenseUUIDs: String
        let createdAt: Date
    }

    /// `LocalProcessedEmail`. IMAP dedupe bookkeeping, keyed on `messageKey`
    /// rather than a `clientUUID`.
    ///
    /// Exported on the orchestrator's ruling, against the original proposal to
    /// exclude it. The archive already carries the items these emails produced,
    /// so suppressing re-ingest on a restored device is the CORRECT outcome, not
    /// a loss. Excluding it would make a restored device reprocess the entire
    /// mailbox and lean solely on `dedupeKey` to avoid duplicates, which is a
    /// weaker guarantee than not doing the work twice.
    struct ProcessedEmailDTO: Codable {
        let messageKey: String
        let uid: Int
        let uidValidity: Int
        let processedAt: Date
    }

    /// Models deliberately NOT exported, recorded in the manifest so their
    /// absence reads as intent rather than as a regression like the seven this
    /// ticket fixed.
    ///
    /// - `LocalFXRate`: a derived rate cache, refetchable from the network, and
    ///   keyed on `currencyCode` rather than user-authored identity.
    /// - `LocalEmailIngestLog`: ingest history rather than user content, and the
    ///   email stack is not in the macOS target at all so these rows never
    ///   exist there.
    static let excludedModels = ["LocalFXRate", "LocalEmailIngestLog"]

    /// Every model this archive format carries, used for the manifest's claimed
    /// list. Order is stable so archives diff cleanly.
    static let exportedModels = [
        "LocalTodo", "LocalNote", "LocalNoteFolder", "LocalList",
        "LocalTrip", "LocalItineraryItem", "LocalExpense", "LocalKeyword",
        "RecurringExpense", "LocalPerson", "LocalEvent",
        "LocalStatementImport", "LocalProcessedEmail",
    ]

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
