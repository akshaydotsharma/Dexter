import Foundation

/// Flattens a `DataArchive.Payload` into uniform, hashable per-record units.
///
/// Everything downstream of here is entity-agnostic: the diff, the oplog and the
/// status UI all work on `SyncRecord`, which is what keeps them from growing a
/// 13-way switch each.
struct SyncRecord: Sendable {
    let entity: String
    let recordID: String
    let json: JSONValue
    let contentHash: String
}

enum SyncRecordMapper {

    /// The entities sync carries, mirroring the backup archive exactly.
    ///
    /// `LocalFXRate` and `LocalEmailIngestLog` are absent here because they are
    /// absent from the archive: a refetchable rate cache and an ingest audit
    /// trail respectively, neither of them user-authored content. Deriving this
    /// from `exportedModels` rather than restating it means the two lists cannot
    /// disagree about what a record is.
    static var syncedEntities: [String] { DataArchive.exportedModels }

    /// A list plus its checklist items, hashed and shipped as one record.
    ///
    /// ⚠️ THIS COMPOSITE IS NOT COSMETIC. `ListDTO` carries only the list's own
    /// columns; the archive flattens checklist items into a separate top-level
    /// array keyed by `listClientUUID`. Hashing `ListDTO` alone would therefore
    /// miss every item edit, so ticking a checkbox or adding a line would look
    /// like no change at all and would silently never sync. Items belong to
    /// exactly one list and have no identity of their own (`ChecklistItem.id` is
    /// deliberately not persisted in the archive), so the list is the only
    /// sensible sync unit.
    struct ListWithItems: Codable {
        let list: DataArchive.ListDTO
        let items: [DataArchive.ListItemDTO]
    }

    /// Build one `SyncRecord` per synced record in the payload.
    static func records(from payload: DataArchive.Payload) throws -> [SyncRecord] {
        var out: [SyncRecord] = []

        out += try map("LocalTodo",       payload.tasks)        { $0.clientUUID.uuidString }
        // #399. The rows travel here; the JPEGs and PDFs travel beside them as
        // blobs (#471), because the oplog carries JSON only. A peer that receives a
        // row before its bytes renders the card's arriving state.
        out += try map("LocalTaskTicket", payload.taskTickets ?? []) { $0.clientUUID.uuidString }
        out += try map("LocalNote",       payload.notes)        { $0.clientUUID.uuidString }
        out += try map("LocalNoteFolder", payload.noteFolders)  { $0.clientUUID.uuidString }
        // #395. Same as task tickets above: the row travels in the oplog and its
        // JPEG travels beside it as a blob (#471). Until the bytes land, the strip
        // shows the image as living on the other device.
        out += try map("LocalNoteImage",  payload.noteImages ?? []) { $0.clientUUID.uuidString }
        out += try map("LocalList",       listRecords(payload)) { $0.list.clientUUID.uuidString }
        out += try map("LocalTrip",       payload.itineraries)  { $0.clientUUID.uuidString }
        out += try map("LocalItineraryItem", payload.itineraryDays) { $0.clientUUID.uuidString }
        // Already a String on the model, not a UUID.
        out += try map("LocalExpense",    payload.expenses)     { $0.clientUUID }
        out += try map("LocalKeyword",    payload.vocab)        { $0.clientUUID.uuidString }
        out += try map("RecurringExpense", payload.recurringExpenses ?? []) { $0.clientUUID }
        // #524. Already a String on the model, like the expense template above.
        // The TASKS a template makes travel as ordinary `LocalTodo` records and
        // carry their own `occurrenceKey`, so a peer that has already made the same
        // date recognises it rather than duplicating it.
        out += try map("RecurringTask", payload.recurringTasks ?? []) { $0.clientUUID }
        out += try map("LocalPerson",     payload.persons ?? []) { $0.clientUUID.uuidString }
        out += try map("LocalEvent",      payload.events ?? [])  { $0.clientUUID.uuidString }
        out += try map("LocalStatementImport", payload.statementImports ?? []) { $0.clientUUID.uuidString }
        // Keyed on `messageKey`: this model has no `clientUUID` at all, its
        // unique attribute is the IMAP message key. Getting this wrong would
        // collapse every processed email onto one record.
        out += try map("LocalProcessedEmail", payload.processedEmails ?? []) { $0.messageKey }
        out += try map("LocalWalletCard", payload.walletCards ?? []) { $0.clientUUID.uuidString }
        // #449. Membership travels inside the record as a blob, so a block and
        // its member list are one sync unit — last write wins on the whole list,
        // the same call `LocalList` makes about its checklist items.
        out += try map("LocalVisionBlock", payload.visionBlocks ?? []) { $0.clientUUID.uuidString }
        // #542. Both already Strings on the model, like the expense above. A
        // meal's per-dish breakdown travels inside the record as a blob, so a
        // meal and its items are one sync unit and last write wins on the whole
        // list — the same call `LocalList` and `LocalVisionBlock` make.
        out += try map("LocalMeal", payload.meals ?? []) { $0.clientUUID }
        // One record, and on this build only ever one row. It still ships as an
        // ordinary record rather than as a device setting, because targets that
        // differ between the phone and the Mac make every verdict on one of them
        // wrong without looking wrong.
        out += try map("MealTargets", payload.mealTargets ?? []) { $0.clientUUID }
        // #599. Already a String on the model, like the two above. A block's
        // ingredients travel inside the record as a blob, so a block and its
        // ingredient list are one sync unit and last write wins on the whole
        // list — the same call `LocalList`, `LocalVisionBlock` and `LocalMeal`
        // all make about the arrays they own.
        out += try map("LocalMealPlanEntry", payload.mealPlanEntries ?? []) { $0.clientUUID }
        // #625. Already a String on the model, like the three above. A library
        // row owns no array and no file, so it is the simplest record here:
        // every column is a scalar and the whole row is one sync unit. Meals
        // logged from an item are ordinary `LocalMeal` records carrying their
        // own copy of the numbers, so correcting an item on one device cannot
        // rewrite a meal on another.
        out += try map("LocalFoodItem", payload.foodItems ?? []) { $0.clientUUID }
        // #661. Both ids are Strings. A check-in's id is derived from the habit
        // and the day, so the phone and the Mac ticking the same day produce ONE
        // record, and last write wins on it instead of two rows disagreeing.
        out += try map("LocalHabit", payload.habits ?? []) { $0.clientUUID }
        out += try map("LocalHabitCheckIn", payload.habitCheckIns ?? []) { $0.clientUUID }

        return out
    }

    /// Regroup the archive's flattened list items back onto their lists.
    ///
    /// Items are sorted by `position` so the hash is stable: dictionary grouping
    /// does not preserve order, and an unstable order would make every list look
    /// changed on every pass and flood the log.
    private static func listRecords(_ payload: DataArchive.Payload) -> [ListWithItems] {
        let grouped = Dictionary(grouping: payload.listItems, by: \.listClientUUID)
        return payload.lists.map { list in
            let items = (grouped[list.clientUUID] ?? []).sorted { $0.position < $1.position }
            return ListWithItems(list: list, items: items)
        }
    }

    private static func map<T: Encodable>(
        _ entity: String,
        _ items: [T],
        id: (T) -> String
    ) throws -> [SyncRecord] {
        // `DataArchive.makeEncoder()` sets `.sortedKeys`, which is the only
        // reason the hash below is reproducible run to run. A plain JSONEncoder
        // emits keys in arbitrary order.
        let encoder = DataArchive.makeEncoder()
        return try items.map { item in
            let data = try encoder.encode(item)
            // Explicit nulls for the optionals `encodeIfPresent` dropped, so a field
            // this build CLEARED reads differently from one it has never heard of
            // (#516). The hash covers the filled payload, not the encoder's output:
            // `SyncApplier.verify` rehashes the payload it receives and rejects any op
            // whose bytes disagree with its own `contentHash`, so the hash has to be
            // taken over what is actually shipped.
            let filled = JSONValue.fillingNulls(of: item, into: try JSONValue.from(encoded: data))
            return SyncRecord(
                entity: entity,
                recordID: id(item),
                json: filled,
                contentHash: SyncHash.hex(try filled.encodedData())
            )
        }
    }
}
