import Foundation
import CryptoKit

// Wire format for the sync oplog (#348).
//
// An op is the unit of change. Segments are batches of ops, sealed and never
// rewritten. Both are plain Codable structs written as JSON into the shared
// iCloud folder, deliberately kept decoupled from the `@Model` classes exactly
// as `DataArchive` is: a SwiftData schema change must not silently alter the
// wire format that another device is parsing.

// MARK: - JSONValue

/// A minimal recursive JSON value, used to embed a record's DTO inside an op.
///
/// The alternative was to embed the DTO as an escaped JSON string. That is
/// strictly lossless, but it makes the log unreadable, and reading the log by
/// eye is the entire verification method for phase 1's dry run. So the payload
/// is stored as real nested JSON, and every op additionally carries a
/// `contentHash` of the ORIGINAL encoded DTO bytes. On apply, re-encoding the
/// decoded DTO and comparing hashes turns any fidelity loss into a loud
/// mismatch instead of a silent corruption. That check is what makes readable
/// JSON safe to use here.
///
/// Dates are not a special case: `DataArchive.makeEncoder()` is configured for
/// `.iso8601`, so they arrive as strings and round-trip through `.string`.
indirect enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised JSON value in sync op payload"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:               try container.encodeNil()
        case .bool(let value):    try container.encode(value)
        case .number(let value):  try container.encode(value)
        case .string(let value):  try container.encode(value)
        case .array(let value):   try container.encode(value)
        case .object(let value):  try container.encode(value)
        }
    }

    /// Round-trip an already-encoded DTO into a `JSONValue`.
    static func from(encoded data: Data) throws -> JSONValue {
        try DataArchive.makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Re-encode back to bytes a DTO decoder can consume.
    func encodedData() throws -> Data {
        try DataArchive.makeEncoder().encode(self)
    }

    /// Restore the keys Swift's `Codable` dropped, as explicit nulls (#516).
    ///
    /// Synthesized `Codable` encodes optionals with `encodeIfPresent`, so a nil field
    /// simply is not on the wire. `preservingFieldsAbsentHere` below then keeps the
    /// receiver's old value, which is right for a peer that has never HEARD of the
    /// field and wrong for a peer that deliberately CLEARED it. The two were
    /// indistinguishable, so clearing anything stopped propagating: three trip
    /// expenses kept a split on the Mac that the phone had removed, and the devices
    /// disagreed about the user's share by 95 euro.
    ///
    /// Absence is the signal, so the sender has to stop being absent about fields it
    /// knows. This walks the value's own `Mirror` and writes `.null` for every
    /// property the encoder omitted, which makes "I know this field and it is empty"
    /// say something different from "I have never heard of this field". The receiver
    /// already reads the difference correctly and needs no change.
    ///
    /// The key set is DERIVED, never restated. A hand-kept list per entity is the
    /// failure #449 recorded, where a field missing from a second list was invisible
    /// until the data was gone; here a new DTO property is filled the moment it
    /// exists.
    ///
    /// Recursion matters for the composite records: a list ships with its checklist
    /// items and a vision block with its members, so nulls have to reach inside the
    /// nested objects and arrays too.
    ///
    /// ## Where it deliberately does nothing
    ///
    /// A DTO that renamed keys with custom `CodingKeys` would encode keys that are not
    /// property labels. Filling from labels there would invent keys the decoder
    /// ignores and change the hash for nothing, so a mismatch between the encoded keys
    /// and the labels leaves the object exactly as encoded. No DTO does this today;
    /// the guard is what keeps that from becoming a silent trap later.
    static func fillingNulls(of value: Any, into json: JSONValue) -> JSONValue {
        let mirror = Mirror(reflecting: unwrappingOptional(value))
        switch json {
        case .object(var fields):
            guard mirror.displayStyle == .struct || mirror.displayStyle == .class else { return json }
            var byLabel: [String: Any] = [:]
            for child in mirror.children {
                guard let label = child.label else { return json }
                byLabel[label] = child.value
            }
            guard fields.keys.allSatisfy({ byLabel[$0] != nil }) else { return json }
            for (label, child) in byLabel {
                if let existing = fields[label] {
                    fields[label] = fillingNulls(of: child, into: existing)
                } else {
                    fields[label] = .null
                }
            }
            return .object(fields)
        case .array(let elements):
            let children = Array(mirror.children)
            guard children.count == elements.count else { return json }
            return .array(zip(children, elements).map { fillingNulls(of: $0.value, into: $1) })
        default:
            return json
        }
    }

    /// The value inside an `Optional`, so a present optional is walked as the struct
    /// it wraps rather than as a one-child container. A nil optional is returned as
    /// itself and stops the walk, which is correct: it has no keys to fill.
    private static func unwrappingOptional(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.map { unwrappingOptional($0.value) } ?? value
    }

    /// Overlay this payload onto `local`, keeping any local key this payload does not
    /// mention at all.
    ///
    /// ## Why this exists: a peer cannot have an opinion about a field it has never
    /// heard of
    ///
    /// Ops carry a whole-row snapshot, and the applier rewrites the row from it. So a
    /// peer running an OLDER build — whose DTO simply has no such property — sends a
    /// payload with the key missing, and the rewrite nulls a column the peer has never
    /// known about. Measured on the user's phone: five `LocalTrip` rows had
    /// `coverImagePath`, `coverImageState` and `coverArtPromptVersion` all NULL while
    /// fifteen cover JPEGs sat on disk, because the Mac was on a build predating those
    /// fields and its upserts kept erasing them. `updatedAt` moved with each erasure,
    /// which is what made it look like a local write had failed.
    ///
    /// This is not specific to covers. EVERY additively-added field is exposed to it,
    /// and the same family has bitten this project twice before: a peer with a narrower
    /// schema dropping a model's table, and an insert-only merge that could not heal
    /// missing fields. So the rule is general and lives here rather than in any one
    /// entity's mapping.
    ///
    /// ## Absent versus explicitly null
    ///
    /// Absence is the signal. A key present with a `null` value IS an opinion and
    /// overwrites, because `merged[key] == nil` tests for a MISSING key —
    /// `JSONValue.null` is `.some(.null)` and passes through untouched.
    ///
    /// ## The honest limitation
    ///
    /// Swift's synthesized `Codable` encodes optionals with `encodeIfPresent`, so a
    /// field a same-version peer deliberately CLEARED is also absent from the wire, and
    /// is therefore preserved rather than cleared. Clearing an optional does not
    /// propagate any more. That affects real actions — un-archiving (`archivedAt` back
    /// to nil) and un-deleting (`deletedAt` back to nil) — and it is a deliberate
    /// trade: a stale value the owning device can overwrite with a new one is strictly
    /// recoverable, whereas the erasure this replaces destroyed data on the receiving
    /// device with nothing left to recover from. Making clears propagate again needs
    /// the DTOs to encode explicit nulls, which changes every content hash and forces a
    /// one-time full re-publish, so it belongs in its own change rather than riding
    /// along with a data-loss fix.
    func preservingFieldsAbsentHere(from local: JSONValue) -> JSONValue {
        guard case .object(let incoming) = self,
              case .object(let localFields) = local else { return self }
        var merged = incoming
        for (key, value) in localFields where merged[key] == nil {
            merged[key] = value
        }
        return .object(merged)
    }
}

// MARK: - Ops

enum SyncOpKind: String, Codable {
    case upsert
    case delete
}

/// One change to one record.
///
/// Upserts carry the FULL record, not a field-level delta. That follows from the
/// epic's decision to ship record-level last-writer-wins first and defer
/// field-level to phase 4: with record-level LWW a partial delta would buy
/// nothing, and carrying the whole record lets sync reuse `DataArchive`'s DTOs,
/// which have already been hardened for fidelity by #319. Sync and the backup
/// archive therefore agree on what a record is, by construction rather than by
/// discipline.
struct SyncOp: Codable, Equatable {
    let opID: UUID
    let deviceUUID: UUID
    let lamport: Int64
    /// Display and last-resort tiebreak only. Never used for ordering: the two
    /// devices' clocks are not comparable.
    let wallClock: Date
    /// Swift type name, e.g. `LocalTodo`. Matches `DataArchive.exportedModels`.
    let entity: String
    /// `clientUUID` stringified. String rather than UUID because
    /// `LocalExpense.clientUUID` is already a String.
    let recordID: String
    let kind: SyncOpKind
    /// The record's DTO as nested JSON. Nil for `.delete`.
    let payload: JSONValue?
    /// Hex SHA-256 of the original encoded DTO bytes. Nil for `.delete`.
    /// See the `JSONValue` note above for why this exists.
    let contentHash: String?

    var isDelete: Bool { kind == .delete }
}

// MARK: - Segments

/// A sealed batch of ops.
///
/// Immutability is load-bearing, not tidiness. iCloud Drive resolves two
/// writers touching one file by silently creating conflict copies
/// ("seg-000003 2.json"), which would fork the log. Because each device writes
/// only inside its own directory and never reopens a sealed segment, iCloud only
/// ever has new files to upload and never a merge to attempt.
struct SyncSegment: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let deviceUUID: UUID
    let deviceName: String
    let sequence: Int
    let sealedAt: Date
    let lamportLow: Int64
    let lamportHigh: Int64
    let ops: [SyncOp]

    init(
        formatVersion: Int = SyncSegment.currentFormatVersion,
        deviceUUID: UUID,
        deviceName: String,
        sequence: Int,
        sealedAt: Date = Date(),
        ops: [SyncOp]
    ) {
        self.formatVersion = formatVersion
        self.deviceUUID = deviceUUID
        self.deviceName = deviceName
        self.sequence = sequence
        self.sealedAt = sealedAt
        self.lamportLow = ops.map(\.lamport).min() ?? 0
        self.lamportHigh = ops.map(\.lamport).max() ?? 0
        self.ops = ops
    }
}

/// Per-device pointer file. A HINT ONLY.
///
/// This is the one mutable file a device writes, so it is the one file that can
/// fork into an iCloud conflict copy. Nothing may depend on it being correct:
/// the truth is the set of `seg-*.json` files actually present on disk. It
/// exists so a peer can show "last seen" and a friendly name without opening
/// every segment.
struct SyncDeviceMeta: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let deviceUUID: UUID
    let deviceName: String
    let updatedAt: Date
    let highestSealedSequence: Int
    let lamport: Int64

    init(
        formatVersion: Int = SyncDeviceMeta.currentFormatVersion,
        deviceUUID: UUID,
        deviceName: String,
        updatedAt: Date = Date(),
        highestSealedSequence: Int,
        lamport: Int64
    ) {
        self.formatVersion = formatVersion
        self.deviceUUID = deviceUUID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.highestSealedSequence = highestSealedSequence
        self.lamport = lamport
    }
}

// MARK: - Hashing

// MARK: - Logging

/// Sync's log sink. Writes to BOTH `NSLog` and stderr, deliberately.
///
/// `NSLog` alone is not enough. Once a macOS app connects to the window server,
/// NSLog output stops being mirrored to stderr and goes only to the unified log,
/// where `log show` may also drop it depending on `OS_ACTIVITY_MODE`. That cost
/// a full debugging round on #348: a pass was silently failing and every log
/// line about it was invisible, so the symptom looked like the pass never ran.
///
/// Phase 1 is a dry run whose entire value is being auditable from outside the
/// UI, so the audit trail has to survive being launched from a script. stderr is
/// the only stream that reliably does.
enum SyncLog {
    static func line(_ message: String) {
        NSLog("%@", message)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum SyncHash {
    /// Hex SHA-256. Stable across runs only because the caller encodes with
    /// `DataArchive.makeEncoder()`, which sets `.sortedKeys`. A plain
    /// `JSONEncoder` orders keys arbitrarily and would make every record look
    /// changed on every pass, flooding the log.
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
