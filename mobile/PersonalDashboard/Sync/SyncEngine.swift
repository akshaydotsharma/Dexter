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
        let highestSegmentAvailable: Int
        let opsDecoded: Int
        let opsWouldApply: Int
        let lastError: String?

        var isBehind: Bool { highestSegmentAvailable > highestSegmentRead }
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
            opsIn = try await readPeers(folder: folder, state: state)

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
        return (try? snapshot()) ?? SyncStatusSnapshot()
    }

    // MARK: - Outbound

    private func emitLocalChanges(folder: SyncFolder, state: SyncDeviceState) async throws -> Int {
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
                shadow.updatedAt = Date()
            } else {
                modelContext.insert(SyncShadow(
                    entity: record.entity,
                    recordID: record.recordID,
                    contentHash: record.contentHash,
                    lastEmittedLamport: lamport
                ))
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
    private func readPeers(folder: SyncFolder, state: SyncDeviceState) async throws -> Int {
        let peers = try folder.peerDeviceUUIDs(excluding: state.deviceUUID)
        var totalDecoded = 0

        for peer in peers {
            let cursor = try peerCursor(for: peer)
            let available = (try? folder.segmentSequences(for: peer)) ?? []
            let pending = available.filter { $0 > cursor.highestSegmentRead }

            if let meta = folder.readMeta(deviceUUID: peer) {
                cursor.peerName = meta.deviceName
            }
            cursor.lastSeenAt = Date()

            var highestRead = cursor.highestSegmentRead
            var decoded = 0
            var wouldApply = 0
            var failure: String?

            for sequence in pending {
                let url = folder.segmentURL(peer, sequence: sequence)
                // A file can be listed while its bytes are still cloud-only.
                // Reading it then fails in a way indistinguishable from a corrupt
                // segment, so wait for it rather than misdiagnosing it.
                guard await SyncFolder.materialize(url) else {
                    failure = "Segment \(sequence) not yet downloaded from iCloud"
                    break
                }
                do {
                    let segment = try folder.readSegment(deviceUUID: peer, sequence: sequence)
                    decoded += segment.ops.count
                    wouldApply += countWouldApply(segment.ops)
                    // Advance our clock past the peer's. This is the whole
                    // reason inbound runs before outbound.
                    state.lamport = max(state.lamport, segment.lamportHigh)
                    // Only advance on a clean decode, and stop at the first
                    // failure so segments are consumed strictly in order. A gap
                    // would let a later op win over an earlier one it should
                    // have lost to.
                    highestRead = sequence
                } catch {
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
            }

            cursor.highestSegmentRead = highestRead
            cursor.opsDecoded += decoded
            cursor.opsWouldApply += wouldApply
            cursor.lastError = failure
            totalDecoded += decoded
        }

        try modelContext.save()
        return totalDecoded
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
                highestSegmentAvailable: available.max() ?? 0,
                opsDecoded: cursor.opsDecoded,
                opsWouldApply: cursor.opsWouldApply,
                lastError: cursor.lastError
            )
        }.sorted { $0.name < $1.name }

        return snapshot
    }
}
