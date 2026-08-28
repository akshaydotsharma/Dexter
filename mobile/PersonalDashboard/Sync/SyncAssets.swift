import Foundation
import SwiftData

// Attachment file transfer for sync (#471).
//
// The oplog carries JSON. Until this landed, a ticket, receipt or note image
// reached the other device as a row while its JPEG or PDF stayed behind, and the
// card rendered a permanent "the file is on your other device" state. The only
// way to move bytes was the export archive.
//
// The transport is the folder sync already uses. There is no CloudKit here and
// there will not be: free personal-team signing rejects the entitlement.
//
// THREE JOBS, ONCE PER PASS:
//
//   1. PUBLISH — copy every attachment this device holds into its own
//      `assets/` directory, named for the SHA-256 of its contents, and seal a
//      manifest saying which relative path each blob belongs to.
//   2. FETCH   — for every row that names a file this device does not have, find
//      the blob in a peer's manifest, materialise it, verify it against its own
//      name, and write it where the row expects it.
//   3. SWEEP   — occasionally reclaim blobs in this device's own directory that
//      no local row references any more.
//
// ⚠️ #471 DEPENDS ON #411. A sync apply used to blank `attachmentPath`, so the
// reference these bytes attach to did not survive the trip. See
// `DataImportService.restoreAsset` and `UnresolvedAssetPolicy`.

// MARK: - Wire format

/// One published attachment: where the row expects it, and what it is.
///
/// Content-addressed on purpose. Re-publishing becomes a no-op, two devices
/// cannot collide on a name, the same bytes attached twice cost one copy, and a
/// downloaded blob can be checked against the name it was asked for BEFORE it is
/// written into the user's Documents. `TripCoverProvider` is the existing
/// precedent for content-addressing in this codebase.
struct SyncAssetRef: Codable, Equatable {
    /// The path rows store, e.g. `"tickets/<uuid>.pdf"`. Minted by whichever
    /// device first saved the file and carried verbatim in the row's DTO, so both
    /// devices agree on it without negotiating.
    let relativePath: String
    /// Hex SHA-256 of the file's bytes.
    let sha256: String
    /// Lowercased file extension, kept so the blob is recognisable in Finder and
    /// so the viewer's `isPDF` / `isPass` suffix checks still work if a blob is
    /// ever inspected directly.
    let ext: String
    let byteCount: Int

    var blobName: String { ext.isEmpty ? sha256 : "\(sha256).\(ext)" }
}

/// A sealed batch of published assets, one per publishing pass.
///
/// Sealed and never rewritten, for the same reason `SyncSegment` is: iCloud
/// resolves two writers touching one file by forking it, and a forked index
/// would send a peer looking for blobs that are not in its branch. Because each
/// device writes only inside its own directory and never reopens a manifest,
/// iCloud only ever has new files to upload and never a merge to attempt.
///
/// The manifests are also the ONLY index. Nothing durable is kept in the store
/// about which blob holds which attachment, so a fetch that is deferred or fails
/// simply happens again next pass. That is what let this feature ship without a
/// new `@Model`, and therefore without the branch-schema hazard that carries.
struct SyncAssetManifest: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let deviceUUID: UUID
    let sequence: Int
    let sealedAt: Date
    let assets: [SyncAssetRef]

    init(
        formatVersion: Int = SyncAssetManifest.currentFormatVersion,
        deviceUUID: UUID,
        sequence: Int,
        sealedAt: Date = Date(),
        assets: [SyncAssetRef]
    ) {
        self.formatVersion = formatVersion
        self.deviceUUID = deviceUUID
        self.sequence = sequence
        self.sealedAt = sealedAt
        self.assets = assets
    }
}

// MARK: - Where a path lives

/// Resolves a stored relative path to the store that owns it.
///
/// Keyed on the leading directory rather than on the model, because
/// `tickets/` is shared by `LocalItineraryItem` and `LocalWalletCard` and
/// because keeping the mapping here means publish, fetch and sweep are all
/// entity-agnostic. Only the row enumeration below has to know about models.
///
/// An unrecognised prefix returns nil and the path is ignored rather than
/// guessed at: writing bytes to a path this build does not understand is the one
/// mistake here that would be hard to undo.
@MainActor
enum SyncAssetStorage {

    static let directoryNames: Set<String> = [
        "tickets", "task-tickets", "receipts", "note-images", "trip-covers",
    ]

    static func isRecognised(_ relativePath: String) -> Bool {
        directoryNames.contains(directoryName(of: relativePath))
    }

    /// On-disk URL if the bytes are here, nil if they are not.
    static func existingURL(for relativePath: String) -> URL? {
        switch directoryName(of: relativePath) {
        case "tickets":      return TicketStorage.shared.load(relativePath: relativePath)
        case "task-tickets": return TicketStorage.taskTickets.load(relativePath: relativePath)
        case "receipts":     return ReceiptStorage.shared.load(relativePath: relativePath)
        case "note-images":  return ReceiptStorage.noteImages.load(relativePath: relativePath)
        case "trip-covers":  return ReceiptStorage.tripCovers.load(relativePath: relativePath)
        default:             return nil
        }
    }

    /// Write fetched bytes to the path the row already names.
    ///
    /// This can only ever CREATE a file at a path a local row points at and
    /// where nothing is currently on disk — the caller checks that first. It
    /// never overwrites, so a fetch cannot damage anything the user has.
    static func write(_ data: Data, to relativePath: String) throws {
        switch directoryName(of: relativePath) {
        case "tickets":      try TicketStorage.shared.write(data: data, relativePath: relativePath)
        case "task-tickets": try TicketStorage.taskTickets.write(data: data, relativePath: relativePath)
        case "receipts":     try ReceiptStorage.shared.write(data: data, relativePath: relativePath)
        case "note-images":  try ReceiptStorage.noteImages.write(data: data, relativePath: relativePath)
        case "trip-covers":  try ReceiptStorage.tripCovers.write(data: data, relativePath: relativePath)
        default:             throw SyncAssetError.unrecognisedPath(relativePath)
        }
    }

    private static func directoryName(of relativePath: String) -> String {
        String(relativePath.split(separator: "/").first ?? "")
    }

    static func fileExtension(of relativePath: String) -> String {
        (relativePath as NSString).pathExtension.lowercased()
    }
}

enum SyncAssetError: LocalizedError {
    case unrecognisedPath(String)

    var errorDescription: String? {
        switch self {
        case .unrecognisedPath(let path):
            return "No attachment store owns \(path)."
        }
    }
}

// MARK: - What a peer has that we do not

/// Paths a peer has published but this device has not received yet.
///
/// Read by the attachment surfaces so a missing file reads as arriving rather
/// than as permanently elsewhere. Deliberately process state and not a `@Model`:
/// it is rebuilt from the peers' manifests on every pass, so there is nothing
/// worth persisting and nothing that can go stale across a launch.
@MainActor
@Observable
final class SyncAssetInbox {
    static let shared = SyncAssetInbox()

    private(set) var arrivingPaths: Set<String> = []

    private init() {}

    /// True when some peer has published this file and it has not landed here
    /// yet. False both for a file that is present and for one nobody has, which
    /// is what keeps the "on your other device" wording honest in the case where
    /// it is still the whole truth.
    func isArriving(_ relativePath: String?) -> Bool {
        guard let relativePath, !relativePath.isEmpty else { return false }
        return arrivingPaths.contains(relativePath)
    }

    func update(_ paths: Set<String>) {
        guard paths != arrivingPaths else { return }
        arrivingPaths = paths
    }
}

/// The wording every attachment surface uses in place of a file it does not have.
///
/// One implementation so the two states cannot drift apart between the task row,
/// the ticket viewer, the receipt viewer and the note image strip. Before #471
/// "on your other device" was the whole truth and the state was permanent; it now
/// means only that no peer has published the bytes, which is why the arriving case
/// needs different words rather than a spinner bolted onto the same sentence.
///
/// `nonisolated` and pure, so a `static` helper on a view — and a test — can call
/// it without hopping to the main actor. The caller supplies `isArriving`, which
/// is the only part that has to read `SyncAssetInbox`.
enum SyncAssetMessage {

    /// Full sentence, for a row subtitle or a viewer's empty state. `noun` is
    /// capitalised by the caller: "File", "Ticket", "Receipt", "Image".
    static func missing(_ noun: String, isArriving: Bool) -> String {
        isArriving
            ? "\(noun) arriving from your other device"
            : "\(noun) on your other device"
    }
}

// MARK: - The transfer

@MainActor
struct SyncAssetTransfer {

    struct Outcome {
        var published = 0
        var fetched = 0
        /// Wanted, a peer has published it, not downloaded yet.
        var awaiting = 0
        /// Wanted, and no peer has published it. Usually a file that only ever
        /// existed on a device that is no longer in the folder.
        var unavailable = 0
        var swept = 0
        /// Downloaded bytes that did not hash to the name they were fetched
        /// under, so they were thrown away rather than written.
        var rejected = 0

        var didAnything: Bool { published > 0 || fetched > 0 || swept > 0 }

        var summary: String {
            "published \(published), fetched \(fetched), awaiting \(awaiting), "
            + "unavailable \(unavailable), swept \(swept), rejected \(rejected)"
        }
    }

    /// Ceilings per pass, so the first pass on a real library does not turn into
    /// a visible hang. Whatever does not fit is picked up by the next pass; there
    /// is no ordering requirement between assets, so stopping early costs nothing
    /// but time.
    private static let maxFilesPerPass = 40
    private static let maxBytesPerPass = 40 * 1024 * 1024

    /// How long a blob must have been unreferenced before the sweep may remove
    /// it. Cleanup is deliberately not reference-counted (a peer's references are
    /// not knowable here), so the safety comes from age instead: a peer has had a
    /// month of passes to fetch anything it wanted.
    private static let sweepGraceInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let sweepMinimumInterval: TimeInterval = 24 * 60 * 60
    private static let lastSweepKey = "sync.assets.lastSweepAt"

    let modelContext: ModelContext

    func run(folder: SyncFolder, state: SyncDeviceState) async -> Outcome {
        var outcome = Outcome()
        let referenced = referencedPaths()

        var present: [String] = []
        var missing: [String] = []
        for path in referenced {
            if SyncAssetStorage.existingURL(for: path) != nil {
                present.append(path)
            } else {
                missing.append(path)
            }
        }

        do {
            outcome.published = try publish(present, folder: folder, deviceUUID: state.deviceUUID)
        } catch {
            SyncLog.line("SyncAssetTransfer: publish failed: \(String(describing: error))")
        }

        let fetchOutcome = await fetch(missing, folder: folder, selfUUID: state.deviceUUID)
        outcome.fetched = fetchOutcome.fetched
        outcome.awaiting = fetchOutcome.awaiting
        outcome.unavailable = fetchOutcome.unavailable
        outcome.rejected = fetchOutcome.rejected

        outcome.swept = sweepIfDue(
            folder: folder,
            deviceUUID: state.deviceUUID,
            referenced: Set(referenced)
        )

        if outcome.didAnything || outcome.rejected > 0 {
            SyncLog.line("SyncAssetTransfer: \(outcome.summary)")
        }
        return outcome
    }

    // MARK: Row enumeration

    /// Every relative path a live row points at.
    ///
    /// Six columns across five directories. A full sweep of the tables rather
    /// than a hook at each save site, for the same reason
    /// `SyncEngine.computeLocalChanges` is a full diff: attachments are written
    /// from services, AI tool use, email ingest and the archive importer, and any
    /// site we forget would mean a file that silently never travels.
    private func referencedPaths() -> [String] {
        var paths: Set<String> = []

        func add(_ path: String?) {
            guard let path, !path.isEmpty, SyncAssetStorage.isRecognised(path) else { return }
            paths.insert(path)
        }

        for row in (try? modelContext.fetch(FetchDescriptor<LocalTaskTicket>())) ?? [] {
            add(row.attachmentPath)
        }
        for row in (try? modelContext.fetch(FetchDescriptor<LocalItineraryItem>())) ?? [] {
            add(row.attachmentPath)
        }
        for row in (try? modelContext.fetch(FetchDescriptor<LocalWalletCard>())) ?? [] {
            add(row.attachmentPath)
        }
        for row in (try? modelContext.fetch(FetchDescriptor<LocalExpense>())) ?? [] {
            add(row.receiptImagePath)
        }
        for row in (try? modelContext.fetch(FetchDescriptor<LocalNoteImage>())) ?? [] {
            add(row.relativePath)
        }
        // Trip covers TRAVEL rather than being regenerated on the peer (#471).
        //
        // They are the one arguable exclusion: generated art, content-addressed
        // on destination plus prompt version, so a peer could re-derive them from
        // the trip's name instead. Transferring wins on every axis that matters
        // here. A cover is 200–350 KB and about 10 MB across a whole library, so
        // the bytes are noise next to the tickets and receipts already moving.
        // Regenerating costs an image-model call per destination and needs an API
        // key the peer may not have — the Mac had no OpenAI key at all until #439,
        // which is exactly why covers stayed blank there. And because the filename
        // is derived from the destination, both devices name the same file, so the
        // blob a peer publishes is the one this device is already looking for.
        //
        // `TripCoverService.runRepairSweep` stays as the fallback for a cover no
        // peer has.
        for row in (try? modelContext.fetch(FetchDescriptor<LocalTrip>())) ?? [] {
            add(row.coverImagePath)
        }

        return paths.sorted()
    }

    // MARK: Publish

    /// Copy anything this device holds that it has not published yet.
    ///
    /// "Already published" is read from this device's own manifests rather than
    /// tracked in the store, so there is one source of truth and it is the folder
    /// itself. A path is treated as immutable, which it is: every store here
    /// mints a fresh UUID filename on save and never rewrites one in place.
    private func publish(_ paths: [String], folder: SyncFolder, deviceUUID: UUID) throws -> Int {
        let published = try publishedPaths(folder: folder, deviceUUID: deviceUUID)
        let candidates = paths.filter { !published.contains($0) }
        guard !candidates.isEmpty else { return 0 }

        var refs: [SyncAssetRef] = []
        var bytesThisPass = 0

        for path in candidates {
            if refs.count >= Self.maxFilesPerPass { break }
            if bytesThisPass >= Self.maxBytesPerPass { break }
            guard let url = SyncAssetStorage.existingURL(for: path),
                  let data = try? Data(contentsOf: url) else { continue }

            let ref = SyncAssetRef(
                relativePath: path,
                sha256: SyncHash.hex(data),
                ext: SyncAssetStorage.fileExtension(of: path),
                byteCount: data.count
            )
            do {
                try folder.writeBlob(data, deviceUUID: deviceUUID, blobName: ref.blobName)
            } catch {
                SyncLog.line("SyncAssetTransfer: could not publish \(path): \(error.localizedDescription)")
                continue
            }
            refs.append(ref)
            bytesThisPass += data.count
        }

        guard !refs.isEmpty else { return 0 }

        // Highest ON DISK plus one, not a counter in the store, for the same
        // reason `emitLocalChanges` takes the max there: one user-global store is
        // shared by every worktree on this Mac, so two instances can hold the same
        // identity, and a clobbered manifest would strand blobs a peer has not
        // read yet.
        let existing = (try? folder.assetManifestSequences(for: deviceUUID)) ?? []
        let sequence = (existing.max() ?? 0) + 1
        try folder.writeAssetManifest(SyncAssetManifest(
            deviceUUID: deviceUUID,
            sequence: sequence,
            assets: refs
        ))
        return refs.count
    }

    private func publishedPaths(folder: SyncFolder, deviceUUID: UUID) throws -> Set<String> {
        var paths: Set<String> = []
        for sequence in try folder.assetManifestSequences(for: deviceUUID) {
            guard let manifest = try? folder.readAssetManifest(deviceUUID: deviceUUID, sequence: sequence) else {
                continue
            }
            for asset in manifest.assets { paths.insert(asset.relativePath) }
        }
        return paths
    }

    // MARK: Fetch

    private struct FetchOutcome {
        var fetched = 0
        var awaiting = 0
        var unavailable = 0
        var rejected = 0
    }

    private func fetch(
        _ wanted: [String],
        folder: SyncFolder,
        selfUUID: UUID
    ) async -> FetchOutcome {
        var outcome = FetchOutcome()
        guard !wanted.isEmpty else {
            SyncAssetInbox.shared.update([])
            return outcome
        }

        let offers = await peerOffers(folder: folder, selfUUID: selfUUID, wanted: Set(wanted))
        let available = wanted.filter { offers[$0] != nil }
        outcome.unavailable = wanted.count - available.count

        // Everything this device wants is marked arriving up front, so the UI
        // switches wording on the pass that DISCOVERS the file rather than on the
        // one that finishes downloading it. A slow iCloud delivery then reads as
        // progress instead of as the permanent state it used to render.
        SyncAssetInbox.shared.update(Set(available))
        guard !available.isEmpty else { return outcome }

        // Ask for all of them before waiting on any, exactly as segment reads do
        // (#451): iCloud fetches in parallel while we wait on the first.
        SyncFolder.requestDownloads(available.compactMap { path in
            offers[path].map { folder.blobURL($0.deviceUUID, blobName: $0.ref.blobName) }
        })

        var landed: Set<String> = []
        var bytesThisPass = 0

        for path in available {
            if landed.count >= Self.maxFilesPerPass { break }
            if bytesThisPass >= Self.maxBytesPerPass { break }
            guard let offer = offers[path] else { continue }
            let url = folder.blobURL(offer.deviceUUID, blobName: offer.ref.blobName)

            // Five seconds, matching the segment reader. A file that is not here
            // yet is the ordinary case, not an error: it stays marked arriving and
            // the next pass asks again.
            guard await SyncFolder.materialize(url, timeout: 5) else {
                outcome.awaiting += 1
                continue
            }
            guard let data = try? folder.readBlob(url) else {
                outcome.awaiting += 1
                continue
            }
            // Verify BEFORE writing into the user's Documents. A truncated or
            // mangled download would otherwise be indistinguishable from a corrupt
            // original, and the row would render a broken image forever.
            guard SyncHash.hex(data) == offer.ref.sha256 else {
                SyncLog.line("SyncAssetTransfer: REJECTED \(path) — bytes do not match \(offer.ref.sha256.prefix(8))")
                outcome.rejected += 1
                continue
            }
            // Re-check the destination: a concurrent restore or a second pass may
            // have filled it since the enumeration above. Never overwrite.
            guard SyncAssetStorage.existingURL(for: path) == nil else {
                landed.insert(path)
                continue
            }
            do {
                try SyncAssetStorage.write(data, to: path)
                landed.insert(path)
                outcome.fetched += 1
                bytesThisPass += data.count
            } catch {
                SyncLog.line("SyncAssetTransfer: could not write \(path): \(error.localizedDescription)")
                outcome.awaiting += 1
            }
        }

        SyncAssetInbox.shared.update(Set(available).subtracting(landed))
        if outcome.fetched > 0 {
            // The attachment surfaces read from disk, not from the store, so a row
            // that is already on screen has no reason to look again. Same signal
            // the applier posts when rows change.
            NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        }
        return outcome
    }

    private struct Offer {
        let deviceUUID: UUID
        let ref: SyncAssetRef
    }

    /// Which peer, if any, has published each wanted path.
    ///
    /// Manifests are tiny, so materialising them is cheap even when the blobs
    /// themselves are still in the cloud. A manifest that has not arrived is
    /// skipped rather than waited on: it will be there next pass.
    private func peerOffers(
        folder: SyncFolder,
        selfUUID: UUID,
        wanted: Set<String>
    ) async -> [String: Offer] {
        var offers: [String: Offer] = [:]
        let peers = (try? folder.peerDeviceUUIDs(excluding: selfUUID)) ?? []
        for peer in peers {
            let sequences = (try? folder.assetManifestSequences(for: peer)) ?? []
            SyncFolder.requestDownloads(sequences.map { folder.assetManifestURL(peer, sequence: $0) })
            for sequence in sequences {
                let url = folder.assetManifestURL(peer, sequence: sequence)
                guard await SyncFolder.materialize(url, timeout: 3) else { continue }
                guard let manifest = try? folder.readAssetManifest(deviceUUID: peer, sequence: sequence) else {
                    continue
                }
                for asset in manifest.assets where wanted.contains(asset.relativePath) {
                    // First peer to claim a path wins. Content addressing makes
                    // that safe: two peers offering the same path offer the same
                    // bytes, or the hash check throws the imposter out.
                    if offers[asset.relativePath] == nil {
                        offers[asset.relativePath] = Offer(deviceUUID: peer, ref: asset)
                    }
                }
            }
        }
        return offers
    }

    // MARK: Sweep

    /// Reclaim blobs in THIS device's own directory that no local row references.
    ///
    /// Deliberately not reference-counted, as the ticket specifies: a peer's
    /// references are not knowable from here, and getting deletion exactly right
    /// on every path is not worth the risk of getting it wrong. The safety is
    /// twofold instead — a device only ever deletes inside its own subtree, and
    /// only blobs whose paths have been unreferenced for a month, by which point
    /// any peer that wanted them has had hundreds of passes to ask.
    ///
    /// Manifests are never deleted. A peer that reads one and finds no blob just
    /// keeps the row's missing state, which is exactly what it should do.
    private func sweepIfDue(folder: SyncFolder, deviceUUID: UUID, referenced: Set<String>) -> Int {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastSweepKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.sweepMinimumInterval { return 0 }
        defaults.set(Date(), forKey: Self.lastSweepKey)

        guard let sequences = try? folder.assetManifestSequences(for: deviceUUID) else { return 0 }
        /// Blob name -> every path this device ever published it for. A blob stays
        /// while ANY of its paths is still referenced, which is what makes the
        /// sweep safe for content-addressed art shared by several trips.
        var pathsByBlob: [String: Set<String>] = [:]
        for sequence in sequences {
            guard let manifest = try? folder.readAssetManifest(deviceUUID: deviceUUID, sequence: sequence) else {
                continue
            }
            for asset in manifest.assets {
                pathsByBlob[asset.blobName, default: []].insert(asset.relativePath)
            }
        }

        let doomed = Self.blobsToSweep(
            blobNames: folder.blobNames(for: deviceUUID),
            pathsByBlob: pathsByBlob,
            referenced: referenced,
            createdAt: { name in
                let url = folder.blobURL(deviceUUID, blobName: name)
                return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            },
            now: Date()
        )

        var swept = 0
        for blobName in doomed {
            do {
                try folder.deleteBlob(deviceUUID: deviceUUID, blobName: blobName)
                swept += 1
            } catch {
                SyncLog.line("SyncAssetTransfer: could not sweep \(blobName): \(error.localizedDescription)")
            }
        }
        if swept > 0 {
            SyncLog.line("SyncAssetTransfer: swept \(swept) unreferenced blob(s)")
        }
        return swept
    }

    /// The sweep rule, as a pure function of what is on disk and what is still
    /// referenced.
    ///
    /// Separated from the IO so a test can prove it REFUSES the three cases that
    /// would lose data: a blob still referenced by a row, a blob too young for a
    /// peer to have fetched it, and a blob this device never published (so it
    /// belongs to nobody's manifest here and must not be guessed at). A test that
    /// only checked the happy path would pass just as happily with any of those
    /// three broken.
    ///
    /// A blob survives if ANY path it was published for is still referenced. That
    /// matters for content-addressed art: one trip-cover blob can serve several
    /// trips, and deleting it when the first of them goes would blank the rest.
    static func blobsToSweep(
        blobNames: Set<String>,
        pathsByBlob: [String: Set<String>],
        referenced: Set<String>,
        createdAt: (String) -> Date?,
        now: Date
    ) -> [String] {
        let cutoff = now.addingTimeInterval(-sweepGraceInterval)
        return blobNames.filter { name in
            // Not in any manifest of ours: not ours to reason about.
            guard let paths = pathsByBlob[name] else { return false }
            guard paths.isDisjoint(with: referenced) else { return false }
            guard let created = createdAt(name) else { return false }
            return created < cutoff
        }.sorted()
    }
}
