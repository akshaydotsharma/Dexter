import Foundation
import SwiftData

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Sidecar models for cross-device sync (#347, phases 0+1 in #348).
//
// ⚠️ THE WHOLE POINT OF THIS FILE is that sync adds NO fields to the 15
// existing `@Model` classes. Adding a new model type is a safe SwiftData
// lightweight migration (it creates a table). Editing 15 live models is the
// one failure mode that can lose every record the user has, and only 4 of the
// 15 even have a `deletedAt` to build on. So every piece of sync state that
// would naturally want to live on a record instead lives here, keyed back to
// the record by `entity` + `recordID`.
//
// `recordID` is a String rather than a UUID because `LocalExpense.clientUUID`
// is already a String while the other twelve are UUIDs. Stringifying is the
// only key type that spans both without a per-model branch.

/// Composite key helper. SwiftData cannot express a multi-column unique
/// constraint, so the two-part identity is flattened into one unique String.
/// `entity` never contains a pipe (they are Swift type names), so the join is
/// unambiguous.
enum SyncKey {
    static func make(entity: String, recordID: String) -> String {
        "\(entity)|\(recordID)"
    }

    /// Split on the FIRST pipe. Entity names are Swift type names and can never
    /// contain a pipe, but a record id can in principle (`LocalProcessedEmail`
    /// is keyed on an IMAP message key, which is not a UUID), so splitting on
    /// the first separator rather than the last is the safe direction.
    static func entity(of key: String) -> String {
        String(key.prefix(while: { $0 != "|" }))
    }

    static func recordID(of key: String) -> String {
        guard let index = key.firstIndex(of: "|") else { return "" }
        return String(key[key.index(after: index)...])
    }
}

// ⚠️ TWO SEPARATE SwiftData TRAPS WERE HIT HERE. Both cost a debugging round,
// both were found by the verification rig rather than by reading the code, and
// neither produces an error that names the property responsible.
//
// 1. NEVER NAME A STORED PROPERTY `entity` ON A @Model CLASS. Models are
//    NSManagedObject-backed and `NSManagedObject.entity` already exists,
//    returning an `NSEntityDescription`. `var entity: String` compiles, builds,
//    creates the column, and then aborts on first save with
//    "Could not cast value of type 'NSEntityDescription' to 'NSString'".
//
// 2. Renaming it to `entityName` fixed the save but NOT the read: the getter
//    aborted with "Could not cast value of type 'Swift.Optional<Any>' to
//    'Swift.String'" even though every row in the column held a valid string,
//    and even though `key` on the same object read back fine.
//
// So neither model below stores the entity name at all. `key` is
// "Entity|recordID", which already carries both facts, and the two parts are
// exposed as COMPUTED properties. That dodges trap 2 entirely and is the better
// design anyway: three columns encoding two facts can disagree, and this cannot.
//
// The wire format in SyncOp keeps a plain `entity` field. Those are ordinary
// Codable structs with no CoreData involvement, so neither trap applies.

/// Singleton row holding this install's sync identity, its Lamport clock, and
/// the stats the status UI reads.
///
/// Identity deliberately lives in the STORE, not in `UserDefaults`. It has to
/// follow the data, not the install: point the app at a scratch store via
/// `DEXTER_STORE_PATH` and it must present as a different logical device, or
/// its ops interleave with the real device's log under the same id and both
/// logs become unreadable. Keeping it in the store makes that correct for free.
@Model
final class SyncDeviceState {
    /// Always `SyncDeviceState.singleton`. Unique, so a race cannot mint two.
    @Attribute(.unique) var singletonKey: String

    var deviceUUID: UUID
    var deviceName: String

    /// Monotonic Lamport counter. Advanced past any value seen from a peer, so
    /// causal ordering survives clock skew between the phone and the Mac.
    /// Wall clock is recorded on ops for display and last-resort tiebreak only.
    var lamport: Int64

    /// Sequence number for the NEXT segment this device seals. Segments are
    /// immutable once written, so this only ever increases.
    var nextSegmentSequence: Int

    // MARK: Cumulative stats (status UI)
    var opsEmitted: Int
    var lastEmitAt: Date?

    // MARK: Last pass (status UI)
    var lastPassStartedAt: Date?
    var lastPassDurationMS: Int
    var lastPassOpsOut: Int
    var lastPassOpsIn: Int
    /// Free text so the UI can show a real error rather than a bare bool.
    /// Empty means "never run".
    var lastPassOutcome: String

    static let singleton = "self"

    init(
        deviceUUID: UUID = UUID(),
        deviceName: String,
        lamport: Int64 = 0,
        nextSegmentSequence: Int = 1,
        opsEmitted: Int = 0,
        lastEmitAt: Date? = nil,
        lastPassStartedAt: Date? = nil,
        lastPassDurationMS: Int = 0,
        lastPassOpsOut: Int = 0,
        lastPassOpsIn: Int = 0,
        lastPassOutcome: String = ""
    ) {
        self.singletonKey = Self.singleton
        self.deviceUUID = deviceUUID
        self.deviceName = deviceName
        self.lamport = lamport
        self.nextSegmentSequence = nextSegmentSequence
        self.opsEmitted = opsEmitted
        self.lastEmitAt = lastEmitAt
        self.lastPassStartedAt = lastPassStartedAt
        self.lastPassDurationMS = lastPassDurationMS
        self.lastPassOpsOut = lastPassOpsOut
        self.lastPassOpsIn = lastPassOpsIn
        self.lastPassOutcome = lastPassOutcome
    }
}

/// One row per synced record, holding a content hash of the last state this
/// device emitted an op for.
///
/// This is how local changes are detected. The alternative (emit an op at every
/// mutation site) was rejected: writes reach the store from the service layer,
/// the AI tool-use dispatcher, email ingest, statement import and the archive
/// importer, and missing one site means that data silently never syncs while
/// every status indicator still reads healthy. Diffing against a hash catches
/// every writer, including ones added later by someone who has never heard of
/// this file.
@Model
final class SyncShadow {
    /// "Entity|recordID". The single stored identity; see the warning above.
    @Attribute(.unique) var key: String
    /// Hex SHA-256 of the record's DTO encoded with `DataArchive.makeEncoder()`.
    /// That encoder sets `.sortedKeys`, which is what makes the hash stable
    /// across runs. Do not swap it for a plain encoder.
    var contentHash: String
    var lastEmittedLamport: Int64
    var updatedAt: Date

    // MARK: Phase 2 last-writer-wins (#359)
    //
    // BOTH OPTIONAL ON PURPOSE. These land on a model that already exists in live
    // stores on two devices, and the project rule is that only additive, nullable
    // fields are safe: a failed SwiftData lightweight migration does not degrade,
    // it refuses to open the store. Optionals cannot fail, and nil reads as
    // "never applied a remote write", which is exactly right for every row that
    // predates phase 2.

    /// Clock of the newest write known for this record, whether emitted locally or
    /// applied from a peer. Distinct from `lastEmittedLamport`, which only ever
    /// tracks what THIS device published, and would therefore lose to a remote
    /// write and let the same op apply repeatedly.
    var lastKnownLamportValue: Int64?

    /// Which device produced that write. Needed for the LWW tie-break: comparing
    /// clocks alone is not a total order, and a non-total tie-break lets the two
    /// devices pick different winners and diverge while both think they converged.
    var lastWriterDeviceUUID: UUID?

    /// Clock of the newest write known for this record, from either source.
    ///
    /// `max`, not `??`. A row written before phase 2 has no remote-write clock, so
    /// the emitted one is the best available answer, which is what the original
    /// `?? lastEmittedLamport` fallback expressed. But the same is true whenever
    /// the stored remote clock is BEHIND what this device has since published, and
    /// that case is reachable: the outbound path used to bump only
    /// `lastEmittedLamport`, so a record applied from a peer and then edited
    /// locally kept the peer's older clock here forever. The comparison then read
    /// stale and a peer's superseded op could beat newer local content. Seen in the
    /// field on a checklist: emitted at 9007, this field frozen at 9000, and the
    /// peer's op at 9003 won (#380).
    ///
    /// A write this device published IS a write it knows about, so taking the
    /// larger of the two is both correct and monotonic. It also repairs rows
    /// already carrying a stale value, with no migration.
    var lastKnownLamport: Int64 {
        get { max(lastKnownLamportValue ?? 0, lastEmittedLamport) }
        set { lastKnownLamportValue = newValue }
    }

    /// Swift type name, e.g. `LocalTodo`. Computed, never stored.
    var entityName: String { SyncKey.entity(of: key) }
    /// `clientUUID` stringified. Computed, never stored.
    var recordID: String { SyncKey.recordID(of: key) }

    init(entity: String, recordID: String, contentHash: String, lastEmittedLamport: Int64, updatedAt: Date = Date()) {
        self.key = SyncKey.make(entity: entity, recordID: recordID)
        self.contentHash = contentHash
        self.lastEmittedLamport = lastEmittedLamport
        self.updatedAt = updatedAt
    }
}

/// A record this device has deleted. Kept so a delete is durable across log
/// compaction: without it, replaying a stale upsert from a peer would resurrect
/// something the user deleted.
///
/// Note there is no matching "absence means delete" rule anywhere in sync. A
/// local record is removed only when a tombstone op arrives explicitly. That
/// invariant is what makes a stale device safe, and it is the reason the
/// original snapshot-as-truth design was rejected.
@Model
final class SyncTombstone {
    /// "Entity|recordID". The single stored identity; see the warning above.
    @Attribute(.unique) var key: String
    var lamport: Int64
    var deviceUUID: UUID
    var createdAt: Date

    /// Swift type name, e.g. `LocalTodo`. Computed, never stored.
    var entityName: String { SyncKey.entity(of: key) }
    /// `clientUUID` stringified. Computed, never stored.
    var recordID: String { SyncKey.recordID(of: key) }

    init(entity: String, recordID: String, lamport: Int64, deviceUUID: UUID, createdAt: Date = Date()) {
        self.key = SyncKey.make(entity: entity, recordID: recordID)
        self.lamport = lamport
        self.deviceUUID = deviceUUID
        self.createdAt = createdAt
    }
}

/// How far this device has read into each peer's log.
///
/// TWO CURSORS, AND KEEPING THEM APART IS THE WHOLE POINT (#380).
///
/// Phase 1's comment here said "phase 2 adds a separate applied cursor, and
/// conflating the two would make a dry run look like it had already caught up".
/// Phase 2 (#359) never added it, so `highestSegmentRead` kept advancing on a
/// clean DECODE while applying was off. Every segment a device inspected during
/// the dry run was therefore skipped forever once applying was turned on: the
/// peer's shadow table already marks those records as published, so nothing
/// re-emits them, and there is no error anywhere. It cost the phone a whole trip
/// and two notes that only ever existed in the Mac's baseline segment, while the
/// status screen read "segments read 21 of 21".
///
/// So: `highestSegmentRead` is the APPLY cursor and only moves when an applier
/// actually ran. `highestSegmentInspected` is the stats high-water mark and moves
/// on every decode. When the two disagree, this device has seen ops it never
/// applied, which is a repairable state rather than a healthy one.
@Model
final class SyncPeerCursor {
    @Attribute(.unique) var peerDeviceUUID: UUID
    var peerName: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    /// Highest sealed segment sequence from this peer whose ops have been through
    /// `SyncApplier`. Advances ONLY while `SyncSettings.applyEnabled` is on.
    var highestSegmentRead: Int
    var opsDecoded: Int
    /// Phase 1: how many decoded ops WOULD have been applied. Phase 2 turns
    /// this into the actual applied count.
    var opsWouldApply: Int
    var lastError: String?

    // MARK: Inspection cursor (#380)
    //
    // Optional for the same reason the phase 2 fields on `SyncShadow` are: this
    // lands on a model that already exists in live stores on two devices, and only
    // additive nullable fields are safe here. A failed SwiftData lightweight
    // migration does not degrade, it refuses to open the store.

    /// Highest sealed segment sequence decoded from this peer at all, applied or
    /// not. Kept so a dry run does not re-decode the peer's entire log on every
    /// pass just to recount the same ops.
    var highestSegmentInspectedValue: Int?

    /// `highestSegmentInspectedValue` with the pre-#380 fallback applied. A cursor
    /// written before this split has no separate inspection mark, and whatever it
    /// read is exactly what `highestSegmentRead` holds.
    var highestSegmentInspected: Int {
        get { highestSegmentInspectedValue ?? highestSegmentRead }
        set { highestSegmentInspectedValue = newValue }
    }

    /// Segments this device decoded but never applied. Non-zero means ops were
    /// consumed while applying was off and are now unreachable without a replay.
    var unappliedSegmentCount: Int { max(0, highestSegmentInspected - highestSegmentRead) }

    init(
        peerDeviceUUID: UUID,
        peerName: String,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        highestSegmentRead: Int = 0,
        opsDecoded: Int = 0,
        opsWouldApply: Int = 0,
        lastError: String? = nil
    ) {
        self.peerDeviceUUID = peerDeviceUUID
        self.peerName = peerName
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.highestSegmentRead = highestSegmentRead
        self.opsDecoded = opsDecoded
        self.opsWouldApply = opsWouldApply
        self.lastError = lastError
    }
}

// MARK: - Device naming

enum SyncDeviceNaming {
    /// Best-effort human label for the status UI. iOS returns a generic model
    /// name ("iPhone") without a device-name entitlement, which is fine: the
    /// `deviceUUID` is the identity, this is only for display.
    static func currentDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #elseif canImport(AppKit)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Unknown device"
        #endif
    }
}
