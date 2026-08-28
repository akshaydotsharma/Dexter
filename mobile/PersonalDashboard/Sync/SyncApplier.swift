import Foundation
import SwiftData

// Inbound apply for sync phase 2 (#359).
//
// ⚠️ THIS IS THE FIRST CODE IN THE FEATURE THAT CAN DESTROY DATA. Phases 0 and 1
// only appended files to a folder. From here a peer's ops mutate the local store,
// and a wrong apply does not look like a bug: it looks like data that was simply
// never there. Every decision below is biased toward "refuse and log" over
// "guess and write".
//
// Shape of a pass:
//
//   1. Decide, per record, whether the incoming op wins (record-level LWW).
//   2. Verify the decoded payload still hashes to what the op claims.
//   3. Group the winners into a `DataArchive.Payload` and hand it to
//      `DataImportService` in `.replaceMatching` mode, so all 13 DTO-to-model
//      mappings are the ones the archive already uses and hardened.
//   4. Apply deletes, leaving tombstones behind.
//   5. Update the shadow for everything applied, in the SAME save.
//
// Step 5 is not bookkeeping. The shadow records what this device has published;
// if an applied record is not written into it, the next local diff sees the
// applied change as a LOCAL change, re-emits it, the peer applies it back, and
// the two devices trade the same record forever. Sync becomes an infinite loop
// that looks like it is working.

@MainActor
struct SyncApplier {

    struct Outcome {
        var applied = 0
        var deleted = 0
        /// Lost the last-writer-wins comparison. Not an error: the local copy is
        /// newer, so declining is the correct result.
        var skippedOlder = 0
        /// Already identical locally, so applying would be a no-op write.
        var skippedIdentical = 0
        /// Refused because the decoded payload did not hash to the op's claim.
        var rejectedCorrupt = 0
        /// Refused because a tombstone says this record is deleted and the op is
        /// not newer than the tombstone.
        var rejectedTombstoned = 0

        var touchedAnything: Bool { applied > 0 || deleted > 0 }

        var summary: String {
            "applied \(applied), deleted \(deleted), older \(skippedOlder), "
            + "identical \(skippedIdentical), corrupt \(rejectedCorrupt), tombstoned \(rejectedTombstoned)"
        }
    }

    let modelContext: ModelContext

    // MARK: - Entry point

    /// Apply a peer's ops. Ops must arrive in the order they were sealed.
    func apply(_ ops: [SyncOp], localDeviceUUID: UUID) throws -> Outcome {
        var outcome = Outcome()
        guard !ops.isEmpty else { return outcome }

        var shadows = try shadowIndex()
        let tombstones = try tombstoneIndex()

        // Collapse to one winner per record BEFORE touching the store. A batch can
        // legitimately contain several ops for the same record (edited twice
        // between passes), and applying each in turn would write the intermediate
        // states and, worse, make the outcome depend on save granularity.
        var winners: [String: SyncOp] = [:]
        for op in ops {
            let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
            if let held = winners[key], !beats(op, held) { continue }
            winners[key] = op
        }

        var upserts: [SyncOp] = []
        var deletes: [SyncOp] = []

        for (key, op) in winners {
            // A tombstone outranks any op that is not strictly newer than it.
            // Without this a stale upsert still sitting in a peer's log
            // resurrects a record the user deleted, every single pass.
            if let tombstone = tombstones[key], !(op.lamport > tombstone.lamport) {
                outcome.rejectedTombstoned += 1
                continue
            }

            let shadow = shadows[key]
            if let shadow, !beatsLocal(op, shadow: shadow) {
                outcome.skippedOlder += 1
                continue
            }

            switch op.kind {
            case .upsert:
                // Identical content is a no-op. Skipping it keeps the store's
                // modification dates honest and avoids waking every @Query
                // observing these models for nothing.
                if let shadow, shadow.contentHash == op.contentHash {
                    outcome.skippedIdentical += 1
                    continue
                }
                upserts.append(op)
            case .delete:
                deletes.append(op)
            }
            _ = key
        }

        // Verify before writing anything: an op whose payload does not re-hash to
        // its own claim is corrupt or was mangled in transit, and applying it
        // would write bad data under a trusted-looking clock.
        let (verified, corrupt) = try verify(upserts)
        outcome.rejectedCorrupt = corrupt

        var mergedHashes: [String: String] = [:]
        if !verified.isEmpty {
            mergedHashes = try applyUpserts(verified)
            outcome.applied = verified.count
        }
        if !deletes.isEmpty {
            outcome.deleted = try applyDeletes(deletes, localDeviceUUID: localDeviceUUID)
        }

        // Shadow LAST, and in the same save as the deletes' tombstones, so a
        // failure anywhere above leaves the shadow untouched and the whole batch
        // simply retries next pass.
        shadows = try shadowIndex()
        for op in verified + deletes {
            recordShadow(for: op, existing: shadows, mergedHashes: mergedHashes)
        }
        try modelContext.save()

        return outcome
    }

    // MARK: - Ordering

    /// Record-level last-writer-wins: higher Lamport wins, ties broken on device
    /// id so both devices independently reach the SAME answer. A tie-break that
    /// is not total (wall clock, say) lets the two devices pick different winners
    /// and diverge permanently while both believe they converged.
    private func beats(_ lhs: SyncOp, _ rhs: SyncOp) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport > rhs.lamport }
        return lhs.deviceUUID.uuidString > rhs.deviceUUID.uuidString
    }

    private func beatsLocal(_ op: SyncOp, shadow: SyncShadow) -> Bool {
        let localLamport = shadow.lastKnownLamport
        if op.lamport != localLamport { return op.lamport > localLamport }
        guard let localWriter = shadow.lastWriterDeviceUUID else { return true }
        return op.deviceUUID.uuidString > localWriter.uuidString
    }

    // MARK: - Verification

    private func verify(_ ops: [SyncOp]) throws -> (verified: [SyncOp], corrupt: Int) {
        var verified: [SyncOp] = []
        var corrupt = 0
        for op in ops {
            guard let payload = op.payload, let claimed = op.contentHash else {
                corrupt += 1
                continue
            }
            guard let data = try? payload.encodedData(), SyncHash.hex(data) == claimed else {
                SyncLog.line(
                    "SyncApplier: REJECTED \(op.entity) \(op.recordID.prefix(8)) — "
                    + "payload does not match its own contentHash"
                )
                corrupt += 1
                continue
            }
            verified.append(op)
        }
        return (verified, corrupt)
    }

    // MARK: - Upserts

    /// Rebuild a `DataArchive.Payload` from the winning ops and replay it through
    /// the archive importer.
    ///
    /// Reusing the importer is the whole point: it already carries every
    /// DTO-to-model mapping, hardened by #319 for exactly the fidelity failures a
    /// hand-written applier would reintroduce. A parallel mapping here would drift
    /// the moment either side gained a field, and the symptom would be sync
    /// silently dropping that field.
    ///
    /// Attachment BYTES never ride in the oplog, so `entries` is empty here. Since
    /// #471 they travel separately, as content-addressed blobs in the same shared
    /// folder, and `SyncAssetTransfer` fills them in on a later pass. A row can
    /// therefore reference a file this device does not have yet, which is now a
    /// transient state rather than a permanent one.
    private func applyUpserts(_ ops: [SyncOp]) throws -> [String: String] {
        var payload = DataArchive.Payload.empty
        let decoder = DataArchive.makeDecoder()

        // Snapshot the LOCAL rows before anything is written, as the same per-record
        // JSON the diff publishes, so an incoming payload can be overlaid onto it.
        //
        // This is what stops an older peer erasing a column it has never heard of:
        // `.replaceMatching` below DELETES the local row and re-inserts it from the
        // peer's DTO, so any key the peer omits becomes NULL. See
        // `JSONValue.preservingFieldsAbsentHere(from:)` for the measured failure.
        //
        // A full `buildPayload()` is 13 fetches plus DTO mapping, which the engine
        // already pays once per pass for the diff. Paying it again here is deliberate:
        // this method must not depend on the caller having done it, and correctness on
        // a data-loss path beats saving a fetch.
        var localJSON: [String: JSONValue] = [:]
        do {
            let localPayload = try DataExportService(modelContext: modelContext).buildPayload()
            for record in try SyncRecordMapper.records(from: localPayload) {
                localJSON[SyncKey.make(entity: record.entity, recordID: record.recordID)] = record.json
            }
        } catch {
            // Without the snapshot the merge cannot run, and applying unmerged ops is
            // exactly the destructive behaviour being fixed. Refuse the batch instead:
            // it retries next pass.
            SyncLog.line("SyncApplier: could not snapshot local rows, skipping apply: \(error)")
            throw error
        }

        /// Content hash of what each row actually BECAME, keyed for the shadow.
        ///
        /// The shadow must record the merged state, not `op.contentHash`. Recording the
        /// peer's hash would leave this device's own row disagreeing with its shadow, so
        /// the next local diff would read the preserved fields as a fresh local edit and
        /// re-publish them — this device amplifying the very skew it just absorbed.
        var mergedHashes: [String: String] = [:]

        for op in ops {
            let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
            guard let incoming = op.payload else { continue }
            let merged = localJSON[key].map { incoming.preservingFieldsAbsentHere(from: $0) } ?? incoming
            guard let data = try? merged.encodedData() else { continue }
            mergedHashes[key] = SyncHash.hex(data)
            switch op.entity {
            case "LocalTodo":
                payload.tasks.append(try decoder.decode(DataArchive.TaskDTO.self, from: data))
            case "LocalTaskTicket":
                payload.taskTickets = (payload.taskTickets ?? [])
                    + [try decoder.decode(DataArchive.TaskTicketDTO.self, from: data)]
            case "LocalNote":
                payload.notes.append(try decoder.decode(DataArchive.NoteDTO.self, from: data))
            case "LocalNoteImage":
                payload.noteImages = (payload.noteImages ?? [])
                    + [try decoder.decode(DataArchive.NoteImageDTO.self, from: data)]
            case "LocalNoteFolder":
                payload.noteFolders.append(try decoder.decode(DataArchive.NoteFolderDTO.self, from: data))
            case "LocalList":
                // Lists ship as a composite with their checklist items, because
                // the archive flattens items into a separate top-level array and
                // hashing the list alone would miss every item edit.
                let composite = try decoder.decode(SyncRecordMapper.ListWithItems.self, from: data)
                payload.lists.append(composite.list)
                payload.listItems.append(contentsOf: composite.items)
            case "LocalTrip":
                payload.itineraries.append(try decoder.decode(DataArchive.ItineraryDTO.self, from: data))
            case "LocalItineraryItem":
                payload.itineraryDays.append(try decoder.decode(DataArchive.ItineraryDayDTO.self, from: data))
            case "LocalExpense":
                payload.expenses.append(try decoder.decode(DataArchive.ExpenseDTO.self, from: data))
            case "LocalKeyword":
                payload.vocab.append(try decoder.decode(DataArchive.VocabDTO.self, from: data))
            case "RecurringExpense":
                payload.recurringExpenses = (payload.recurringExpenses ?? [])
                    + [try decoder.decode(DataArchive.RecurringExpenseDTO.self, from: data)]
            case "LocalPerson":
                payload.persons = (payload.persons ?? [])
                    + [try decoder.decode(DataArchive.PersonDTO.self, from: data)]
            case "LocalEvent":
                payload.events = (payload.events ?? [])
                    + [try decoder.decode(DataArchive.EventDTO.self, from: data)]
            case "LocalStatementImport":
                payload.statementImports = (payload.statementImports ?? [])
                    + [try decoder.decode(DataArchive.StatementImportDTO.self, from: data)]
            case "LocalProcessedEmail":
                payload.processedEmails = (payload.processedEmails ?? [])
                    + [try decoder.decode(DataArchive.ProcessedEmailDTO.self, from: data)]
            case "LocalWalletCard":
                payload.walletCards = (payload.walletCards ?? [])
                    + [try decoder.decode(DataArchive.WalletCardDTO.self, from: data)]
            // #449. A peer still on a build that predates the model hits the
            // `default` arm below and skips these ops with a log line, which is
            // the graceful degrade #447 asks for.
            case "LocalVisionBlock":
                payload.visionBlocks = (payload.visionBlocks ?? [])
                    + [try decoder.decode(DataArchive.VisionBlockDTO.self, from: data)]
            default:
                // An entity this build does not know about, e.g. a peer running a
                // newer version. Skipped rather than guessed at, and logged so it
                // is visible instead of silently discarded.
                SyncLog.line("SyncApplier: skipping unknown entity \(op.entity)")
            }
        }

        // A synthetic manifest: the importer only reads `data` and `entries` from
        // it, and counts are asserted on the archive path rather than here.
        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: "sync",
            data: payload
        )
        let preview = DataImportService.Preview(
            manifest: manifest,
            archiveURL: URL(fileURLWithPath: "/dev/null"),
            entries: [:],
            counts: [:]
        )
        // `.keepPath` is what makes asset transfer possible at all (#471).
        //
        // `entries` is empty because attachment BYTES never ride in the oplog; they
        // travel as content-addressed blobs in the sync folder instead. So every
        // asset restorer reports `.unresolved` for a row whose file has not landed
        // here yet, and dropping the path at that moment would throw away the only
        // reference the arriving bytes have to attach to. Under `.dropPath` this
        // also blanked rows whose file was sitting on THIS device, which is #411.
        try DataImportService(modelContext: modelContext)
            .commit(preview: preview, mode: .replaceMatching, unresolvedAssets: .keepPath)

        return mergedHashes
    }

    // MARK: - Deletes

    private func applyDeletes(_ ops: [SyncOp], localDeviceUUID: UUID) throws -> Int {
        var deleted = 0
        for op in ops {
            if try deleteRecord(entity: op.entity, recordID: op.recordID) {
                deleted += 1
            }
            // Tombstone regardless of whether a row was actually present. The
            // delete may simply have arrived before the record ever did, and the
            // tombstone is what stops that record being created later by a stale
            // upsert still sitting in the peer's log.
            let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
            if try !tombstoneExists(key: key) {
                modelContext.insert(SyncTombstone(
                    entity: op.entity,
                    recordID: op.recordID,
                    lamport: op.lamport,
                    deviceUUID: op.deviceUUID
                ))
            }
        }
        return deleted
    }

    private func deleteRecord(entity: String, recordID: String) throws -> Bool {
        switch entity {
        case "LocalTodo":            return try delete(LocalTodo.self, uuid: recordID, key: \.clientUUID)
        case "LocalTaskTicket":      return try delete(LocalTaskTicket.self, uuid: recordID, key: \.clientUUID)
        case "LocalNote":            return try delete(LocalNote.self, uuid: recordID, key: \.clientUUID)
        case "LocalNoteImage":       return try delete(LocalNoteImage.self, uuid: recordID, key: \.clientUUID)
        case "LocalNoteFolder":      return try delete(LocalNoteFolder.self, uuid: recordID, key: \.clientUUID)
        case "LocalList":            return try delete(LocalList.self, uuid: recordID, key: \.clientUUID)
        case "LocalTrip":            return try delete(LocalTrip.self, uuid: recordID, key: \.clientUUID)
        case "LocalItineraryItem":   return try delete(LocalItineraryItem.self, uuid: recordID, key: \.clientUUID)
        case "LocalKeyword":         return try delete(LocalKeyword.self, uuid: recordID, key: \.clientUUID)
        case "LocalPerson":          return try delete(LocalPerson.self, uuid: recordID, key: \.clientUUID)
        case "LocalEvent":           return try delete(LocalEvent.self, uuid: recordID, key: \.clientUUID)
        case "LocalStatementImport": return try delete(LocalStatementImport.self, uuid: recordID, key: \.clientUUID)
        case "LocalWalletCard":      return try delete(LocalWalletCard.self, uuid: recordID, key: \.clientUUID)
        // Deleting a block deletes the block only. Its members are `LocalTodo`
        // rows the board borrows, and nothing here touches them (#447).
        case "LocalVisionBlock":     return try delete(LocalVisionBlock.self, uuid: recordID, key: \.clientUUID)
        case "LocalExpense":         return try deleteString(LocalExpense.self, id: recordID, key: \.clientUUID)
        case "RecurringExpense":     return try deleteString(RecurringExpense.self, id: recordID, key: \.clientUUID)
        case "LocalProcessedEmail":  return try deleteString(LocalProcessedEmail.self, id: recordID, key: \.messageKey)
        default:
            SyncLog.line("SyncApplier: cannot delete unknown entity \(entity)")
            return false
        }
    }

    private func delete<M: PersistentModel>(_ type: M.Type, uuid: String, key: KeyPath<M, UUID>) throws -> Bool {
        guard let target = UUID(uuidString: uuid) else { return false }
        var found = false
        for model in try modelContext.fetch(FetchDescriptor<M>()) where model[keyPath: key] == target {
            modelContext.delete(model)
            found = true
        }
        return found
    }

    private func deleteString<M: PersistentModel>(_ type: M.Type, id: String, key: KeyPath<M, String>) throws -> Bool {
        var found = false
        for model in try modelContext.fetch(FetchDescriptor<M>()) where model[keyPath: key] == id {
            modelContext.delete(model)
            found = true
        }
        return found
    }

    // MARK: - Shadow

    /// Write the applied state into the shadow so the next local diff sees it as
    /// already-published rather than as a fresh local edit.
    ///
    /// This is the ping-pong guard. Without it: apply, re-emit, peer applies,
    /// re-emits, forever.
    private func recordShadow(
        for op: SyncOp,
        existing: [String: SyncShadow],
        mergedHashes: [String: String]
    ) {
        let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
        switch op.kind {
        case .upsert:
            // The MERGED hash, falling back to the op's own. See `mergedHashes` in
            // `applyUpserts`: recording the peer's hash for a row we preserved fields on
            // would make the next local diff re-publish them.
            guard let hash = mergedHashes[key] ?? op.contentHash else { return }
            if let shadow = existing[key] {
                shadow.contentHash = hash
                shadow.lastEmittedLamport = op.lamport
                shadow.lastKnownLamport = op.lamport
                shadow.lastWriterDeviceUUID = op.deviceUUID
                shadow.updatedAt = Date()
            } else {
                let shadow = SyncShadow(
                    entity: op.entity,
                    recordID: op.recordID,
                    contentHash: hash,
                    lastEmittedLamport: op.lamport
                )
                shadow.lastKnownLamport = op.lamport
                shadow.lastWriterDeviceUUID = op.deviceUUID
                modelContext.insert(shadow)
            }
        case .delete:
            // The record is gone, so its shadow must go too, or the next local
            // diff reads the orphaned shadow as a LOCAL delete and emits a
            // duplicate delete op back at the peer.
            if let shadow = existing[key] {
                modelContext.delete(shadow)
            }
        }
    }

    private func shadowIndex() throws -> [String: SyncShadow] {
        var index: [String: SyncShadow] = [:]
        for shadow in try modelContext.fetch(FetchDescriptor<SyncShadow>()) {
            index[shadow.key] = shadow
        }
        return index
    }

    private func tombstoneIndex() throws -> [String: SyncTombstone] {
        var index: [String: SyncTombstone] = [:]
        for tombstone in try modelContext.fetch(FetchDescriptor<SyncTombstone>()) {
            index[tombstone.key] = tombstone
        }
        return index
    }

    private func tombstoneExists(key: String) throws -> Bool {
        var descriptor = FetchDescriptor<SyncTombstone>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }
}
