import Foundation
import SwiftData

// The sync pass (#348, phases 0+1).
//
// PHASE 1 IS A DRY RUN AND THAT IS A HARD GUARANTEE, not a setting. Nothing in
// this file writes to any of the 15 existing `@Model` classes. The inbound half
// decodes a peer's ops, counts what it would do, and stops. That exists so the
// riskiest part of the design (local change capture) can be watched against real
// data for several days before anything is allowed to mutate the store.
//
// If you are adding inbound apply for phase 2, do not thread it through
// `readPeers`. Add a separate applier, gate it behind `SyncSettings`, and keep
// this dry-run path intact as the thing you diff against.

/// Everything the status UI needs from one pass. A value type so the UI holds a
/// snapshot rather than reaching into live SwiftData objects mid-pass.
struct SyncStatusSnapshot {
    struct Peer: Identifiable {
        let id: UUID
        let name: String
        let lastSeenAt: Date?
        let highestSegmentRead: Int
        let highestSegmentInspected: Int
        let highestSegmentAvailable: Int
        let opsDecoded: Int
        let opsWouldApply: Int
        let lastError: String?

        var isBehind: Bool { highestSegmentAvailable > highestSegmentRead }

        /// Segments decoded but never applied, because they were read while
        /// applying was off. Surfaced because the old behaviour reported this state
        /// as a fully caught-up cursor, which is how #380 stayed invisible.
        var unappliedSegmentCount: Int { max(0, highestSegmentInspected - highestSegmentRead) }
    }

    var health: SyncFolderHealth = .notConfigured
    var deviceUUID: UUID?
    var deviceName: String = ""
    var lamport: Int64 = 0
    var opsEmitted: Int = 0
    var lastEmitAt: Date?
    var nextSegmentSequence: Int = 1

    var pendingUpserts: Int = 0
    var pendingDeletes: Int = 0
    /// Per-entity breakdown of pending upserts, for the detailed status view.
    var pendingByEntity: [String: Int] = [:]

    var lastPassStartedAt: Date?
    var lastPassDurationMS: Int = 0
    var lastPassOpsOut: Int = 0
    var lastPassOpsIn: Int = 0
    /// Records the applier wrote or removed in the pass that produced this
    /// snapshot. Not persisted, so it is zero for a snapshot rebuilt without a
    /// pass; the replay action is the only reader.
    var lastPassOpsApplied: Int = 0
    /// The pass stopped short because iCloud had not delivered a peer's segment
    /// yet. Not persisted, and false for a snapshot rebuilt without a pass. The
    /// coordinator reads it to retry in seconds instead of at the next tick.
    var isWaitingOnDownloads: Bool = false
    var lastPassOutcome: String = ""

    var peers: [Peer] = []

    var tombstoneCount: Int = 0
    var shadowCount: Int = 0

    /// A pre-#353 `DexterSync/` tree is still present in the folder. Dead weight,
    /// never read, but worth telling the user they can delete it: while it exists
    /// it looks like sync data and invites the conclusion that sync is confused.
    var hasLegacyFolder: Bool = false

    var pendingTotal: Int { pendingUpserts + pendingDeletes }
}

@MainActor
final class SyncEngine {

    /// Local changes found by diffing the store against the shadow table.
    struct LocalChanges {
        var upserts: [SyncRecord] = []
        var deletes: [(entity: String, recordID: String)] = []

        var isEmpty: Bool { upserts.isEmpty && deletes.isEmpty }
        var count: Int { upserts.count + deletes.count }
    }

    private let modelContext: ModelContext

    /// Guards against two overlapping passes. A pass reads the shadow table,
    /// then writes it; two interleaved passes would emit the same change twice
    /// with different Lamport values.
    private var isRunning = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Device state

    /// Fetch or mint this install's sync identity.
    func deviceState() throws -> SyncDeviceState {
        let existing = try modelContext.fetch(FetchDescriptor<SyncDeviceState>())
        if let state = existing.first { return state }
        let state = SyncDeviceState(deviceName: SyncDeviceNaming.currentDeviceName())
        modelContext.insert(state)
        try modelContext.save()
        return state
    }

    // MARK: - Local change detection

    /// Diff the whole store against the shadow table.
    ///
    /// This is deliberately a full sweep rather than an incremental hook. Writes
    /// reach the store from the service layer, the AI tool-use dispatcher, email
    /// ingest, statement import and the archive importer, and any per-site hook
    /// we forget means that data silently never syncs while the UI still reads
    /// healthy. A full diff cannot forget.
    ///
    /// Cost is one fetch per model plus a SHA-256 per record, which at personal
    /// scale is milliseconds. If it ever stops being cheap, the fix is to shard
    /// the sweep across passes, not to reintroduce per-site hooks.
    func computeLocalChanges() throws -> LocalChanges {
        let payload = try DataExportService(modelContext: modelContext).buildPayload()
        let records = try SyncRecordMapper.records(from: payload)

        let shadows = try modelContext.fetch(FetchDescriptor<SyncShadow>())
        var shadowByKey: [String: SyncShadow] = [:]
        for shadow in shadows {
            shadowByKey[shadow.key] = shadow
        }

        var changes = LocalChanges()
        var seenKeys = Set<String>()

        for record in records {
            let key = SyncKey.make(entity: record.entity, recordID: record.recordID)
            seenKeys.insert(key)
            if let shadow = shadowByKey[key], shadow.contentHash == record.contentHash {
                continue
            }
            changes.upserts.append(record)
        }

        // A shadow with no live record behind it is a deletion. This is the ONLY
        // place sync infers a delete, and it infers it about the LOCAL store,
        // where absence really does mean the user deleted something. It never
        // infers a delete from a peer's log being short: that direction requires
        // an explicit tombstone op, which is the invariant that makes a stale
        // device safe.
        for shadow in shadows where !seenKeys.contains(shadow.key) {
            changes.deletes.append((entity: shadow.entityName, recordID: shadow.recordID))
        }

        return changes
    }

    // MARK: - Pass

    @discardableResult
    func runPass(reason: String) async -> SyncStatusSnapshot {
        guard !isRunning else {
            return (try? snapshot()) ?? SyncStatusSnapshot()
        }
        isRunning = true
        defer { isRunning = false }

        let started = Date()
        var opsOut = 0
        var opsIn = 0
        /// Records the applier actually wrote or removed this pass. Not persisted:
        /// it answers "did the thing I just asked for do anything", which only
        /// matters until the next pass.
        var opsApplied = 0
        /// Whether this pass stopped short waiting for iCloud to deliver a peer's
        /// segment. Drives the short retry in `SyncCoordinator` (#451).
        var waitingOnDownloads = false
        var outcome = "OK (\(reason))"

        let health = SyncFolder.health()
        guard health.isUsable else {
            recordPass(started: started, opsOut: 0, opsIn: 0, outcome: health.label)
            return (try? snapshot()) ?? SyncStatusSnapshot()
        }

        do {
            let folder = try SyncFolder.resolve()
            guard folder.beginAccess() else {
                throw SyncFolderError.accessDenied
            }
            defer { folder.endAccess() }

            let state = try deviceState()
            try folder.ensureDirectories(for: state.deviceUUID)

            // INBOUND FIRST, and the order is load-bearing. Reading peers
            // advances our Lamport clock past anything they have already said,
            // so ops we emit below sort after theirs. Emitting first would mint
            // ops with a clock that appears concurrent with changes we had in
            // fact already observed.
            let inbound = try await readPeers(folder: folder, state: state)
            opsIn = inbound.decoded
            opsApplied = inbound.applied
            waitingOnDownloads = inbound.waitingOnDownloads

            opsOut = try await emitLocalChanges(folder: folder, state: state)

            // Pointer file last, so it never advertises a segment that is not
            // on disk yet. A peer that reads a torn meta.json just sees a stale
            // hint, which costs nothing because segments are the truth.
            try? folder.writeMeta(SyncDeviceMeta(
                deviceUUID: state.deviceUUID,
                deviceName: state.deviceName,
                highestSealedSequence: state.nextSegmentSequence - 1,
                lamport: state.lamport
            ))
        } catch {
            // `String(describing:)` as well as `errorDescription`: a SwiftData
            // save failure surfaces as an NSError whose localizedDescription is
            // the useless "The operation couldn\u2019t be completed", while the
            // underlying constraint or validation detail is only in the full
            // description. Losing that turned a one-line bug into a long hunt.
            outcome = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            SyncLog.line("SyncEngine: pass FAILED: \(outcome) | raw: \(String(describing: error))")
        }

        recordPass(started: started, opsOut: opsOut, opsIn: opsIn, outcome: outcome)
        var result = (try? snapshot()) ?? SyncStatusSnapshot()
        result.lastPassOpsApplied = opsApplied
        result.isWaitingOnDownloads = waitingOnDownloads
        return result
    }

    // MARK: - Outbound

    /// Re-publish everything if this device's log is missing from the folder.
    ///
    /// The shadow table records what this device has ALREADY PUBLISHED, so if the
    /// published log disappears the shadow becomes a lie: the next diff finds
    /// nothing changed, this device emits nothing, and the peer is left with no
    /// bootstrap it can ever obtain. Nothing recovers on its own, and there is no
    /// user-visible symptom beyond a peer that stays empty forever.
    ///
    /// That is not hypothetical. It is exactly the state the #353 layout change
    /// creates: the old log is still on disk but at a path sync no longer reads,
    /// while both devices still report 0 pending. Switching to a fresh folder, or
    /// deleting the folder's contents by hand, produces the same dead end.
    ///
    /// So the FOLDER is treated as authoritative for what has been published. No
    /// segments of ours in it means nothing of ours has been published, and the
    /// shadow is discarded so the next diff re-emits the whole store.
    ///
    /// ⚠️ PHASE 3 MUST REVISIT THIS. Log compaction will legitimately remove old
    /// segments, at which point "no segments" stops meaning "never published" and
    /// this check would re-emit everything on every pass. Compaction has to leave
    /// a marker (a snapshot, or a floor sequence in `meta.json`) for this to test
    /// against instead.
    private func republishIfLogMissing(folder: SyncFolder, state: SyncDeviceState) throws {
        let published = (try? folder.segmentSequences(for: state.deviceUUID)) ?? []
        guard published.isEmpty else { return }

        let shadows = try modelContext.fetch(FetchDescriptor<SyncShadow>())
        guard !shadows.isEmpty else { return }

        SyncLog.line(
            "SyncEngine: no published segments for this device but \(shadows.count) tracked records. "
            + "Treating the log as lost and re-publishing everything."
        )
        for shadow in shadows { modelContext.delete(shadow) }
        // Sequence restarts too, so the peer's cursor sees a clean log from #1
        // rather than a gap it would refuse to read past.
        state.nextSegmentSequence = 1
        try modelContext.save()
    }

    private func emitLocalChanges(folder: SyncFolder, state: SyncDeviceState) async throws -> Int {
        try republishIfLogMissing(folder: folder, state: state)
        let changes = try computeLocalChanges()
        guard !changes.isEmpty else { return 0 }

        var ops: [SyncOp] = []
        var lamport = state.lamport
        let now = Date()

        for record in changes.upserts {
            lamport += 1
            ops.append(SyncOp(
                opID: UUID(),
                deviceUUID: state.deviceUUID,
                lamport: lamport,
                wallClock: now,
                entity: record.entity,
                recordID: record.recordID,
                kind: .upsert,
                payload: record.json,
                contentHash: record.contentHash
            ))
        }

        for delete in changes.deletes {
            lamport += 1
            ops.append(SyncOp(
                opID: UUID(),
                deviceUUID: state.deviceUUID,
                lamport: lamport,
                wallClock: now,
                entity: delete.entity,
                recordID: delete.recordID,
                kind: .delete,
                payload: nil,
                contentHash: nil
            ))
        }

        // Take the highest of our counter and what is actually on disk. Those
        // can disagree: one user-global store is shared by every worktree and
        // agent on this Mac, so two app instances can hold the same identity and
        // the same counter at once. Trusting the counter alone would clobber a
        // sealed segment the peer had not read yet.
        let onDisk = (try? folder.segmentSequences(for: state.deviceUUID)) ?? []
        let sequence = max(state.nextSegmentSequence, (onDisk.max() ?? 0) + 1)

        let segment = SyncSegment(
            deviceUUID: state.deviceUUID,
            deviceName: state.deviceName,
            sequence: sequence,
            ops: ops
        )

        // Encode on the main actor (SwiftData objects are long gone by now, this
        // is pure value work), then hop the write off it. The first pass emits
        // every record in the store, so this can be multi-megabyte.
        let data = try DataArchive.makeEncoder().encode(segment)
        let destination = folder.segmentURL(state.deviceUUID, sequence: sequence)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SyncFolderError.segmentAlreadyExists(sequence)
        }
        try await Task.detached(priority: .utility) {
            try SyncFolder.coordinatedWrite(data, to: destination, replacing: false)
        }.value

        // ⚠️ SHADOW UPDATE COMES AFTER THE WRITE, ON PURPOSE.
        //
        // If the shadow said "already sent" and the write then failed, the change
        // would never be emitted again: the next diff would find it unchanged and
        // skip it, and the peer would never learn about it. Silent, permanent
        // data divergence.
        //
        // In the other order the worst case is that the write succeeds and this
        // save fails, so the next pass re-emits the same records in a new
        // segment. Duplicate upserts of identical content are harmless under
        // last-writer-wins. Losing a change is not.
        // Per-op clocks, not the batch maximum. A tombstone stamped with the
        // batch max would claim to be newer than it is, and in phase 2 that
        // tombstone would beat a legitimate later upsert from the peer and
        // resurrect-block a record the user had recreated. Cheap to get right
        // now, extremely annoying to debug later.
        var lamportByKey: [String: Int64] = [:]
        for op in ops {
            lamportByKey[SyncKey.make(entity: op.entity, recordID: op.recordID)] = op.lamport
        }
        applyShadowUpdates(changes: changes, lamportByKey: lamportByKey, deviceUUID: state.deviceUUID)

        state.lamport = lamport
        state.nextSegmentSequence = sequence + 1
        state.opsEmitted += ops.count
        state.lastEmitAt = now
        try modelContext.save()

        return ops.count
    }

    private func applyShadowUpdates(
        changes: LocalChanges,
        lamportByKey: [String: Int64],
        deviceUUID: UUID
    ) {
        var existing: [String: SyncShadow] = [:]
        if let shadows = try? modelContext.fetch(FetchDescriptor<SyncShadow>()) {
            for shadow in shadows { existing[shadow.key] = shadow }
        }

        for record in changes.upserts {
            let key = SyncKey.make(entity: record.entity, recordID: record.recordID)
            let lamport = lamportByKey[key] ?? 0
            if let shadow = existing[key] {
                shadow.contentHash = record.contentHash
                shadow.lastEmittedLamport = lamport
                // The LWW clock and writer move too, not just the emitted clock.
                // Bumping only `lastEmittedLamport` left a record that had once
                // been applied from a peer pinned to that peer's older clock, so
                // the next comparison read stale and a superseded peer op could
                // win over this newer local write (#380). `lastKnownLamport` now
                // also takes the max on read, so this is belt and braces, but the
                // stored state should be honest on its own.
                shadow.lastKnownLamport = lamport
                shadow.lastWriterDeviceUUID = deviceUUID
                shadow.updatedAt = Date()
            } else {
                let shadow = SyncShadow(
                    entity: record.entity,
                    recordID: record.recordID,
                    contentHash: record.contentHash,
                    lastEmittedLamport: lamport
                )
                // Named writer from the start, so the LWW tie-break is a total
                // order. Left nil, `beatsLocal` hands an equal-clock tie to the
                // peer by default, and Lamport values from two devices do collide.
                shadow.lastKnownLamport = lamport
                shadow.lastWriterDeviceUUID = deviceUUID
                modelContext.insert(shadow)
            }
        }

        for delete in changes.deletes {
            let key = SyncKey.make(entity: delete.entity, recordID: delete.recordID)
            if let shadow = existing[key] {
                modelContext.delete(shadow)
            }
            // Tombstone survives shadow removal and log compaction, so a stale
            // upsert replayed later cannot resurrect the record.
            if !tombstoneExists(key: key) {
                modelContext.insert(SyncTombstone(
                    entity: delete.entity,
                    recordID: delete.recordID,
                    lamport: lamportByKey[key] ?? 0,
                    deviceUUID: deviceUUID
                ))
            }
        }
    }

    private func tombstoneExists(key: String) -> Bool {
        var descriptor = FetchDescriptor<SyncTombstone>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    // MARK: - Inbound (dry run)

    /// Read peers' logs and record what WOULD be applied.
    ///
    /// Two things happen for real here, and only two: our Lamport clock advances
    /// past what the peer has said, and the peer cursor moves. Neither touches
    /// user data. Everything else is counted and discarded.
    private func readPeers(
        folder: SyncFolder,
        state: SyncDeviceState
    ) async throws -> (decoded: Int, applied: Int, waitingOnDownloads: Bool) {
        let peers = try folder.peerDeviceUUIDs(excluding: state.deviceUUID)
        var applied = 0
        /// Set when a peer had a segment that iCloud has not delivered yet, so the
        /// caller can retry in seconds rather than at the next 30s tick (#451).
        var isWaitingOnDownloads = false
        var deletedLocally = 0
        // Only prune once the enumeration above has SUCCEEDED. `peerDeviceUUIDs`
        // throws if the folder could not be read, so reaching this line means the
        // empty-or-not answer is real rather than an access failure. Pruning on a
        // failed read would delete the whole peer list every time the bookmark
        // went stale, which is the moment the list matters most.
        pruneCursors(keeping: peers)
        // What this pass actually decoded, including segments a replay is reading
        // for the second time. Drives the "Read" stat, which would otherwise show
        // zero for the one pass that did the most work. The cursor's own cumulative
        // counter takes only newly inspected ops, further down.
        var decodedThisPass = 0

        // Read once per pass, not per segment: a toggle flipped mid-pass would
        // otherwise leave one peer's cursors advanced under one rule and the
        // next peer's under the other.
        let applying = SyncSettings.applyEnabled

        for peer in peers {
            let cursor = try peerCursor(for: peer)
            let available = (try? folder.segmentSequences(for: peer)) ?? []
            // WHICH CURSOR GATES THE WORK DEPENDS ON WHAT THIS PASS CAN DO (#380).
            //
            // Applying: start from the apply cursor, which means segments already
            // inspected during a dry run get decoded again and actually applied.
            // That re-read is the entire fix. Replaying them is safe by
            // construction: a tombstone outranks a stale op, record-level LWW
            // rejects anything older than the local copy, and identical content is
            // skipped.
            //
            // Not applying: start from the inspection mark, so a dry run does not
            // re-decode a multi-megabyte baseline every 30 seconds to recount ops
            // it has already counted.
            let floor = applying ? cursor.highestSegmentRead : cursor.highestSegmentInspected
            let pending = available.filter { $0 > floor }

            if let meta = folder.readMeta(deviceUUID: peer) {
                cursor.peerName = meta.deviceName
            }
            cursor.lastSeenAt = Date()

            var highestRead = cursor.highestSegmentRead
            var highestInspected = cursor.highestSegmentInspected
            var decoded = 0
            var wouldApply = 0
            var failure: String?

            // Ask for ALL of them at once, before waiting on the first (#451).
            // Segments still apply in order below; this only means iCloud is
            // fetching the rest while we wait, instead of learning about segment
            // n+1 a poll interval after segment n lands.
            SyncFolder.requestDownloads(pending.map { folder.segmentURL(peer, sequence: $0) })

            for sequence in pending {
                let url = folder.segmentURL(peer, sequence: sequence)
                // A file can be listed while its bytes are still cloud-only.
                // Reading it then fails in a way indistinguishable from a corrupt
                // segment, so wait for it rather than misdiagnosing it.
                //
                // Five seconds, not twenty (#451). The long wait made a manual
                // refresh hang for the whole timeout and return nothing, which
                // reads as a broken button. The download is already requested and
                // keeps running after this returns, so a shorter wait does not
                // lose progress — it just hands control back and lets the retry
                // below pick the segment up when it has landed.
                guard await SyncFolder.materialize(url, timeout: 5) else {
                    failure = "Segment \(sequence) not yet downloaded from iCloud"
                    // Said out loud, because this used to be completely silent: the
                    // pass reported `in=0`, which is exactly what a pass with
                    // nothing to do reports. That is why a 93-second delivery was
                    // reported as sync not working at all.
                    SyncLog.line(
                        "SyncEngine: waiting on iCloud for \(peer.uuidString.prefix(8)) "
                        + "seg \(sequence) — deferring, will retry shortly"
                    )
                    isWaitingOnDownloads = true
                    break
                }
                do {
                    let segment = try folder.readSegment(deviceUUID: peer, sequence: sequence)
                    // Count each segment once ever, even when a replay decodes it a
                    // second time. These are cumulative counters on the cursor, so
                    // recounting a replayed baseline would inflate "ops decoded"
                    // into a number that no longer means anything.
                    decodedThisPass += segment.ops.count
                    if sequence > highestInspected {
                        decoded += segment.ops.count
                        wouldApply += countWouldApply(segment.ops)
                    }
                    // PHASE 2. Everything above this line is still a dry run; this
                    // is the only place a peer's changes reach the store. Gated on
                    // its own setting, separate from `enabled`, so publishing
                    // outbound never implies accepting inbound.
                    if applying {
                        let outcome = try SyncApplier(modelContext: modelContext)
                            .apply(segment.ops, localDeviceUUID: state.deviceUUID)
                        applied += outcome.applied
                        deletedLocally += outcome.deleted
                        if outcome.rejectedCorrupt > 0 || outcome.rejectedTombstoned > 0 || outcome.touchedAnything {
                            SyncLog.line("SyncApplier: seg \(sequence) from \(peer.uuidString.prefix(8)) — \(outcome.summary)")
                        }
                        // Only advance the APPLY cursor here, inside the branch that
                        // actually applied. Advancing it on a bare decode is what
                        // made a dry run silently consume a peer's baseline (#380).
                        highestRead = sequence
                    }
                    // Advance our clock past the peer's. This is the whole
                    // reason inbound runs before outbound.
                    state.lamport = max(state.lamport, segment.lamportHigh)
                    // Inspection advances on any clean decode. Stop at the first
                    // failure either way, so segments are consumed strictly in
                    // order: a gap would let a later op win over an earlier one it
                    // should have lost to.
                    highestInspected = max(highestInspected, sequence)
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
            }

            cursor.highestSegmentRead = highestRead
            cursor.highestSegmentInspected = highestInspected
            cursor.opsDecoded += decoded
            cursor.opsWouldApply += wouldApply
            cursor.lastError = failure
        }

        try modelContext.save()
        if applied > 0 || deletedLocally > 0 {
            SyncLog.line("SyncEngine: APPLIED \(applied) record(s), deleted \(deletedLocally) locally")
            // Tell the manual-fetch surfaces to re-read.
            //
            // Tasks, Notes and Lists cache their rows in a view model loaded by
            // `.task`, rather than using the auto-updating `@Query` that keeps
            // Activity, Finance and Itineraries live. So a write from outside the
            // UI is invisible to them until the view is recreated: the row stays
            // on screen after a peer deleted it, and only navigating away and back
            // clears it.
            //
            // `localStoreDidChange` exists for exactly this, and those three views
            // already observe it — `ExecuteDraftAction` posts it after AI capture
            // and chat writes for the same reason. Sync is the same shape and
            // simply failed to post it. Posted once per pass rather than per
            // segment, so a multi-segment catch-up triggers one reload.
            NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        }
        return (
            decoded: decodedThisPass,
            applied: applied + deletedLocally,
            waitingOnDownloads: isWaitingOnDownloads
        )
    }

    /// How many of these ops would change something locally.
    ///
    /// Phase 1 answers this by content hash only, which is the cheap and honest
    /// version: an upsert whose hash already matches our shadow is genuinely a
    /// no-op, and anything else would do something. It deliberately does NOT
    /// simulate conflict resolution, because record-level LWW does not exist
    /// until phase 2 and guessing at it here would make the dry-run numbers
    /// disagree with the real thing.
    private func countWouldApply(_ ops: [SyncOp]) -> Int {
        guard !ops.isEmpty else { return 0 }
        var shadowHashes: [String: String] = [:]
        if let shadows = try? modelContext.fetch(FetchDescriptor<SyncShadow>()) {
            for shadow in shadows { shadowHashes[shadow.key] = shadow.contentHash }
        }
        var count = 0
        for op in ops {
            let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
            switch op.kind {
            case .upsert:
                if shadowHashes[key] != op.contentHash { count += 1 }
            case .delete:
                if shadowHashes[key] != nil { count += 1 }
            }
        }
        return count
    }

    // MARK: - Replay

    /// Rewind every peer's APPLY cursor to zero, so the next pass re-reads each
    /// peer's log from the first segment and applies it.
    ///
    /// This exists because the #380 fix cannot repair a device that already has
    /// the damage. A cursor that advanced during the dry run is indistinguishable
    /// from one that advanced legitimately: both are just an integer. The device
    /// cannot know which segments it skipped, and the peer will never re-emit
    /// them, so the only way back is to read the whole log again.
    ///
    /// Rewinding is safe because the applier does not trust the log's order for
    /// correctness, only for determinism. A replayed op has to beat a tombstone
    /// and beat the local record's clock before it writes anything, and identical
    /// content is skipped outright. The one thing a replay CAN do is recreate a
    /// record that was deleted here before sync ever ran, because such a record
    /// has neither a shadow nor a tombstone to defend it while the peer's copy is
    /// still legitimately present. That is the same "absence never means delete"
    /// invariant the whole design rests on, not a new hazard, but it is the reason
    /// the caller confirms with the user first and takes a fresh backup.
    ///
    /// The inspection mark is deliberately left where it is: it only feeds the
    /// stats, and resetting it would recount every op in the log.
    @discardableResult
    func resetPeerApplyCursors() throws -> Int {
        let cursors = try modelContext.fetch(FetchDescriptor<SyncPeerCursor>())
        var rewound = 0
        for cursor in cursors where cursor.highestSegmentRead > 0 {
            SyncLog.line(
                "SyncEngine: rewinding apply cursor for \(cursor.peerName) "
                + "\(cursor.peerDeviceUUID.uuidString.prefix(8)) from segment \(cursor.highestSegmentRead) to 0"
            )
            cursor.highestSegmentRead = 0
            cursor.lastError = nil
            rewound += 1
        }
        try modelContext.save()
        return rewound
    }

    /// Drop cursors for devices that are no longer in the folder.
    ///
    /// Cursors used to be create-only, so the peer list was an append-only history
    /// of every device id ever seen rather than a view of what is actually there
    /// (#356). Retiring a device, reinstalling, or repointing sync at another
    /// folder each left a permanent phantom peer stuck at "0 segments read", which
    /// reads exactly like a broken sync on the surface people actually check.
    private func pruneCursors(keeping present: [UUID]) {
        let keep = Set(present)
        guard let cursors = try? modelContext.fetch(FetchDescriptor<SyncPeerCursor>()) else { return }
        var pruned: [String] = []
        for cursor in cursors where !keep.contains(cursor.peerDeviceUUID) {
            pruned.append("\(cursor.peerName) \(cursor.peerDeviceUUID.uuidString.prefix(8))")
            modelContext.delete(cursor)
        }
        guard !pruned.isEmpty else { return }
        SyncLog.line("SyncEngine: pruned \(pruned.count) stale peer(s): \(pruned.joined(separator: ", "))")
    }

    private func peerCursor(for peer: UUID) throws -> SyncPeerCursor {
        var descriptor = FetchDescriptor<SyncPeerCursor>(predicate: #Predicate { $0.peerDeviceUUID == peer })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let cursor = SyncPeerCursor(peerDeviceUUID: peer, peerName: "Unknown device")
        modelContext.insert(cursor)
        return cursor
    }

    // MARK: - Status

    private func recordPass(started: Date, opsOut: Int, opsIn: Int, outcome: String) {
        guard let state = try? deviceState() else { return }
        let durationMS = Int(Date().timeIntervalSince(started) * 1000)
        state.lastPassStartedAt = started
        state.lastPassDurationMS = durationMS
        state.lastPassOpsOut = opsOut
        state.lastPassOpsIn = opsIn
        state.lastPassOutcome = outcome
        try? modelContext.save()

        // Logged on every pass, not just failures. During the phase 1 dry run
        // this line IS the audit trail: it is how "did my edit get captured"
        // gets answered without opening the UI, and it is what a verification
        // script can assert against. Cheap enough to keep permanently.
        SyncLog.line(
            "SyncEngine: pass device=\(state.deviceUUID.uuidString.prefix(8)) "
            + "seq=\(state.nextSegmentSequence - 1) lamport=\(state.lamport) "
            + "out=\(opsOut) in=\(opsIn) shadows=\(shadowCount()) \(durationMS)ms: \(outcome)"
        )
    }

    private func shadowCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<SyncShadow>())) ?? -1
    }

    /// Build a fresh snapshot for the status UI, recomputing pending changes so
    /// the view shows what sync would do right now rather than at the last pass.
    func snapshot() throws -> SyncStatusSnapshot {
        var snapshot = SyncStatusSnapshot()
        snapshot.health = SyncFolder.health()

        let state = try deviceState()
        snapshot.deviceUUID = state.deviceUUID
        snapshot.deviceName = state.deviceName
        snapshot.lamport = state.lamport
        snapshot.opsEmitted = state.opsEmitted
        snapshot.lastEmitAt = state.lastEmitAt
        snapshot.nextSegmentSequence = state.nextSegmentSequence
        snapshot.lastPassStartedAt = state.lastPassStartedAt
        snapshot.lastPassDurationMS = state.lastPassDurationMS
        snapshot.lastPassOpsOut = state.lastPassOpsOut
        snapshot.lastPassOpsIn = state.lastPassOpsIn
        snapshot.lastPassOutcome = state.lastPassOutcome

        if let changes = try? computeLocalChanges() {
            snapshot.pendingUpserts = changes.upserts.count
            snapshot.pendingDeletes = changes.deletes.count
            snapshot.pendingByEntity = Dictionary(
                grouping: changes.upserts, by: \.entity
            ).mapValues(\.count)
        }

        snapshot.shadowCount = (try? modelContext.fetchCount(FetchDescriptor<SyncShadow>())) ?? 0
        snapshot.tombstoneCount = (try? modelContext.fetchCount(FetchDescriptor<SyncTombstone>())) ?? 0

        let cursors = (try? modelContext.fetch(FetchDescriptor<SyncPeerCursor>())) ?? []
        let folder = try? SyncFolder.resolve()
        let didAccess = folder?.beginAccess() ?? false
        defer { if didAccess { folder?.endAccess() } }

        snapshot.hasLegacyFolder = (didAccess ? folder?.hasLegacyLayout() : false) ?? false

        snapshot.peers = cursors.map { cursor in
            let available = folder.flatMap { try? $0.segmentSequences(for: cursor.peerDeviceUUID) } ?? []
            return SyncStatusSnapshot.Peer(
                id: cursor.peerDeviceUUID,
                name: cursor.peerName,
                lastSeenAt: cursor.lastSeenAt,
                highestSegmentRead: cursor.highestSegmentRead,
                highestSegmentInspected: cursor.highestSegmentInspected,
                highestSegmentAvailable: available.max() ?? 0,
                opsDecoded: cursor.opsDecoded,
                opsWouldApply: cursor.opsWouldApply,
                lastError: cursor.lastError
            )
        }.sorted { $0.name < $1.name }

        return snapshot
    }
}
