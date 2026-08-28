import Foundation
import SwiftData

// Reattaching rows that #411 detached from their files (#471).
//
// ## Why this is possible at all
//
// #411 blanked `attachmentPath` on every sync apply, and the blanking then
// PUBLISHED, so the peer's copy was blanked too. Both devices lost the only link
// between a row and its file, and a re-apply cannot bring it back: the replayed
// op carries the Lamport value the shadow already recorded, so last-writer-wins
// correctly declines it.
//
// The oplog, though, is append-only and has never been compacted. Every op this
// pair of devices ever published is still sitting in `seg-*.json`, INCLUDING the
// upserts that carried the original path. So the link is not gone; it is just no
// longer in the store. This reads it back out of the log.
//
// ## The signature, measured
//
// A #411 blanking is unmistakable in the log. The path disappears in the very next
// op, with `updatedAt` byte-identical to the op that carried it:
//
//     lam=9134  upsert  path=…4b97bdc1ad5b.jpg  updatedAt=2026-07-29T18:10:22Z
//     lam=9135  upsert  path=(empty)            updatedAt=2026-07-29T18:10:22Z
//
// That is what `.replaceMatching` does: it re-inserts the row from the peer's DTO,
// so every other field — `updatedAt` included — comes through untouched while the
// path is dropped. All twelve damaged rows on this pair of devices have exactly
// that shape.
//
// A person detaching a file is the opposite: the service layer stamps a new
// `updatedAt`, because that is what a real edit does. So an unchanged `updatedAt`
// across the loss is the discriminator, and it is the reason this repair cannot
// resurrect something the user deliberately removed.
//
// ## What it will and will not touch
//
// It only ever writes a path onto a row whose column is EMPTY, and only a path
// that this same record once carried. It never overwrites a live path, never
// invents one, and never deletes anything.

@MainActor
struct SyncAssetRepair {

    /// The asset column on each entity that carries a path, keyed by the entity
    /// name the oplog uses. Mirrors the six columns `SyncAssetTransfer` moves.
    static let assetColumns: [String: String] = [
        "LocalTaskTicket":    "attachmentPath",
        "LocalItineraryItem": "attachmentPath",
        "LocalWalletCard":    "attachmentPath",
        "LocalExpense":       "receiptImagePath",
        "LocalNoteImage":     "relativePath",
        "LocalTrip":          "coverImagePath",
    ]

    /// Set once the log has been read all the way through. Latched because the
    /// scan reads every segment ever written, which is megabytes of JSON, and
    /// there is nothing to find a second time.
    private static let didRepairKey = "sync.assets.didRepairDetachedPaths"

    struct Outcome {
        var repaired = 0
        var candidates = 0
        /// Segments iCloud had not delivered. A non-zero value means the scan was
        /// incomplete, so the latch is NOT set and the whole thing runs again.
        var undelivered = 0

        var summary: String {
            "repaired \(repaired) of \(candidates) candidate(s), \(undelivered) segment(s) undelivered"
        }
    }

    /// One observation of a record's asset column, as published.
    struct Observation: Sendable {
        let lamport: Int64
        let deviceUUID: UUID
        let path: String
        let updatedAt: String
    }

    let modelContext: ModelContext

    // MARK: - Entry point

    /// Read the whole log once and reattach what #411 detached.
    ///
    /// Returns nil when the latch says this has already run to completion.
    func runOnceIfNeeded(folder: SyncFolder, deviceUUIDs: [UUID]) async -> Outcome? {
        guard !UserDefaults.standard.bool(forKey: Self.didRepairKey) else { return nil }

        // The scan is pure file IO and value decoding, and it reads every segment
        // in the folder. On this store that is 587 files and tens of megabytes, so
        // it stays off the main actor.
        let scan = await Task.detached(priority: .utility) {
            await Self.readObservations(folder: folder, deviceUUIDs: deviceUUIDs)
        }.value

        var outcome = Outcome()
        outcome.undelivered = scan.undelivered

        let candidates = Self.detachedPaths(in: scan.observations)
        outcome.candidates = candidates.count
        outcome.repaired = apply(candidates)

        if outcome.repaired > 0 {
            try? modelContext.save()
            SyncLog.line("SyncAssetRepair: \(outcome.summary)")
            NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        }

        // Only latch on a COMPLETE read. A partial scan that latched would make a
        // partial repair permanent, and the rows it missed are exactly the ones
        // whose segments were slowest to arrive.
        if outcome.undelivered == 0 {
            UserDefaults.standard.set(true, forKey: Self.didRepairKey)
        } else {
            SyncLog.line(
                "SyncAssetRepair: \(outcome.undelivered) segment(s) not delivered yet, will scan again"
            )
        }
        return outcome
    }

    // MARK: - Reading the log

    /// Every published value of every asset column, keyed `entity|recordID`.
    nonisolated static func readObservations(
        folder: SyncFolder,
        deviceUUIDs: [UUID]
    ) async -> (observations: [String: [Observation]], undelivered: Int) {
        var observations: [String: [Observation]] = [:]
        var undelivered = 0

        for device in deviceUUIDs {
            let sequences = (try? folder.segmentSequences(for: device)) ?? []
            SyncFolder.requestDownloads(sequences.map { folder.segmentURL(device, sequence: $0) })
            for sequence in sequences {
                let url = folder.segmentURL(device, sequence: sequence)
                guard await SyncFolder.materialize(url, timeout: 5) else {
                    undelivered += 1
                    continue
                }
                guard let segment = try? folder.readSegment(deviceUUID: device, sequence: sequence) else {
                    // A segment that will not decode is not a delivery problem, so
                    // it must not hold the latch open forever. Skipped and logged.
                    SyncLog.line("SyncAssetRepair: could not decode seg \(sequence) from \(device.uuidString.prefix(8))")
                    continue
                }
                for op in segment.ops where op.kind == .upsert {
                    guard let column = assetColumns[op.entity],
                          case .object(let fields)? = op.payload else { continue }
                    let path: String
                    switch fields[column] {
                    case .string(let value): path = value
                    default:                 path = ""      // absent or explicit null
                    }
                    let updatedAt: String
                    if case .string(let value)? = fields["updatedAt"] { updatedAt = value } else { updatedAt = "" }
                    let key = SyncKey.make(entity: op.entity, recordID: op.recordID)
                    observations[key, default: []].append(Observation(
                        lamport: op.lamport,
                        deviceUUID: op.deviceUUID,
                        path: path,
                        updatedAt: updatedAt
                    ))
                }
            }
        }
        return (observations, undelivered)
    }

    // MARK: - The rule

    /// Records whose path was dropped by a machine rewrite rather than by a person.
    ///
    /// Pure, and separated from the IO so a test can prove it REFUSES a deliberate
    /// clear. A rule that only recognised the damage would pass just as happily
    /// while resurrecting a file the user had detached on purpose.
    static func detachedPaths(in observations: [String: [Observation]]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, unsorted) in observations {
            // Lamport order, device id as the tiebreak, so both devices read the
            // same history in the same order. Same total order the applier uses.
            let ops = unsorted.sorted {
                $0.lamport != $1.lamport
                    ? $0.lamport < $1.lamport
                    : $0.deviceUUID.uuidString < $1.deviceUUID.uuidString
            }
            var held: Observation?
            var candidate: String?
            for op in ops {
                if !op.path.isEmpty {
                    held = op
                    candidate = nil          // a later real path supersedes any candidate
                    continue
                }
                // Only the blank that IMMEDIATELY follows a held path says anything
                // about intent. Once the path is gone, later ops republishing the
                // now-blank row carry no information, and reading them as a
                // deliberate clear would void a candidate that is real. The live
                // log has exactly that shape:
                //
                //     lam=9134  path=…4b97bdc1ad5b.jpg  updatedAt=2026-07-29T18:10:22Z
                //     lam=9135  path=(empty)            updatedAt=2026-07-29T18:10:22Z  <- #411
                //     lam=9147  path=(empty)            updatedAt=2026-07-30T06:44:37Z  <- just a later republish
                //
                // So `held` is cleared either way, and a blank with nothing held is
                // skipped.
                guard let previous = held else { continue }
                held = nil
                if op.updatedAt == previous.updatedAt {
                    // Content changed, `updatedAt` did not: a `.replaceMatching`
                    // rewrite, which is #411.
                    candidate = previous.path
                } else {
                    // A real edit cleared it. Not ours to undo, and any earlier
                    // candidate is void.
                    candidate = nil
                }
            }
            if let candidate { out[key] = candidate }
        }
        return out
    }

    // MARK: - Writing it back

    /// Set each recovered path, but ONLY where the column is currently empty.
    private func apply(_ candidates: [String: String]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        var repaired = 0

        for (key, path) in candidates {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (entity, recordID) = (parts[0], parts[1])

            switch entity {
            case "LocalTaskTicket":
                repaired += set(LocalTaskTicket.self, recordID, \.clientUUID, path) {
                    $0.attachmentPath.isEmpty ? { $0.attachmentPath = path } : nil
                }
            case "LocalItineraryItem":
                repaired += set(LocalItineraryItem.self, recordID, \.clientUUID, path) {
                    $0.attachmentPath.isEmpty ? { $0.attachmentPath = path } : nil
                }
            case "LocalWalletCard":
                repaired += set(LocalWalletCard.self, recordID, \.clientUUID, path) {
                    $0.attachmentPath.isEmpty ? { $0.attachmentPath = path } : nil
                }
            case "LocalNoteImage":
                repaired += set(LocalNoteImage.self, recordID, \.clientUUID, path) {
                    $0.relativePath.isEmpty ? { $0.relativePath = path } : nil
                }
            case "LocalTrip":
                repaired += set(LocalTrip.self, recordID, \.clientUUID, path) {
                    ($0.coverImagePath ?? "").isEmpty ? { $0.coverImagePath = path } : nil
                }
            case "LocalExpense":
                // The only one of the six keyed on a String rather than a UUID.
                let rows = (try? modelContext.fetch(FetchDescriptor<LocalExpense>())) ?? []
                for row in rows where row.clientUUID == recordID {
                    guard (row.receiptImagePath ?? "").isEmpty else { continue }
                    row.receiptImagePath = path
                    repaired += 1
                }
            default:
                continue
            }
        }
        return repaired
    }

    /// Fetch by `clientUUID` and apply the closure the caller returns, if any.
    ///
    /// The closure is returned rather than called so the "is it empty" test lives
    /// with the property it is about — each entity names its asset column
    /// differently, and a generic key path cannot span `String` and `String?`.
    private func set<M: PersistentModel>(
        _ type: M.Type,
        _ recordID: String,
        _ key: KeyPath<M, UUID>,
        _ path: String,
        _ mutation: (M) -> ((M) -> Void)?
    ) -> Int {
        guard let target = UUID(uuidString: recordID) else { return 0 }
        var repaired = 0
        for row in ((try? modelContext.fetch(FetchDescriptor<M>())) ?? [])
        where row[keyPath: key] == target {
            guard let apply = mutation(row) else { continue }
            apply(row)
            repaired += 1
        }
        return repaired
    }
}
