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
