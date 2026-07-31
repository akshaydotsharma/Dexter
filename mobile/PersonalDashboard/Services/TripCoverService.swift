import Foundation
import SwiftData

/// The three values `LocalTrip.coverImageState` can hold, plus nil for "never
/// attempted" (#428).
///
/// Genuinely three-valued, and the distinction is what stops a runaway: `none`
/// means "we looked and there is nothing suitable", which is a settled answer,
/// where `failed` means "the network let us down", which is worth another go.
/// Collapsing the two would make the app re-search forever for a trip called
/// "Work offsite".
enum TripCoverState: String {
    case resolved
    case none
    case failed
}

/// Fetches destination photography and caches it on disk, so the tile can render
/// a cover with no network call on any path (#428).
///
/// Two entry points, both off the render path:
///   - `resolveOnWrite(tripUUID:)` from `TripEditorSheet.save()`, for a new or
///     renamed trip.
///   - `runRepairSweep()` from `AppMaintenance`, once per launch, for trips whose
///     state is nil or `failed`, and for trips whose cached file has gone missing.
///
/// Nothing here is called from a view body, a `.task` on a row, or any other
/// render path. That is what makes "there is no loading state" true rather than
/// aspirational, and it is why the tile has no spinner, shimmer or
/// placeholder-flash question to answer.
@MainActor
final class TripCoverService {

    static let shared = TripCoverService()

    private let provider: TripCoverProvider
    private let storage: ReceiptStorage

    /// Trips currently being fetched. Both entry points can fire for the same
    /// trip (save a rename, then a sweep on the next launch mid-flight), and two
    /// concurrent fetches would write two files and leak one.
    private var inFlight: Set<UUID> = []

    /// Latch for the repair sweep. `.task` fires per WINDOW on macOS, not per
    /// process, and macOS restores multiple windows on relaunch — the same trap
    /// `AppMaintenance.didRunLaunchPass` documents.
    private var didRunRepairSweep = false

    /// Ceiling on how many trips one sweep will fetch. A user with 30 Past trips
    /// should not have the app open 90 HTTP requests on first launch after
    /// updating; the rest are picked up by the next launch's sweep.
    private let sweepBudget = 6

    /// Politeness gap between fetches inside a sweep. Wikimedia has no published
    /// rate limit for this volume, but hammering a free public API from a loop is
    /// bad manners regardless.
    private let sweepGap: Duration = .milliseconds(400)

    init(
        provider: TripCoverProvider = WikimediaTripCoverProvider(),
        storage: ReceiptStorage = .tripCovers
    ) {
        self.provider = provider
        self.storage = storage
    }

    // MARK: - Entry points

    /// Fetch a cover for a trip the user has just created or renamed.
    ///
    /// A rename invalidates whatever cover was there: the destination changed, so
    /// the photograph is now of the wrong place. The old fields (and file) are
    /// cleared by `TripEditorSheet` before this runs, which puts the trip back
    /// into the nil state this method fetches for.
    func resolveOnWrite(tripUUID: UUID) async {
        await resolveIfNeeded(tripUUID: tripUUID)
    }

    /// Once-per-launch pass over trips that have no usable cover.
    ///
    /// Three populations qualify:
    ///   - state nil — never attempted (every pre-existing trip on first launch
    ///     after this ships).
    ///   - state `failed` — a transient problem last time.
    ///   - state `resolved` but the file is not on disk. That is the sync case:
    ///     `coverImagePath` carries a UUID filename minted on the OTHER device,
    ///     which this device does not have. `coverImageSourceURL` is the portable
    ///     identity, so the cover is re-derivable and this can never be data
    ///     loss. The tile draws generated art in the meantime.
    ///
    /// `none` is deliberately absent: it is a settled answer.
    func runRepairSweep() async {
        guard !didRunRepairSweep else { return }
        didRunRepairSweep = true

        let context = SwiftDataStore.shared.context
        guard let trips = try? context.fetch(FetchDescriptor<LocalTrip>()) else { return }

        // Soonest-starting first, so the trips the user is about to look at get
        // the budget before a five-year-old one does.
        let pending = trips
            .filter { needsFetch($0) }
            .sorted { abs($0.startDate.timeIntervalSinceNow) < abs($1.startDate.timeIntervalSinceNow) }
            .prefix(sweepBudget)

        guard !pending.isEmpty else { return }

        for trip in pending {
            await resolveIfNeeded(tripUUID: trip.clientUUID)
            try? await Task.sleep(for: sweepGap)
        }
    }

    // MARK: - Core

    /// Whether this trip has no cover we can currently draw.
    ///
    /// The `resolved`-but-missing-file branch is the self-healing rule: a path
    /// that does not resolve is treated as un-fetched rather than as an error,
    /// because a cover is always re-derivable from `coverImageSourceURL`.
    ///
    /// Written against the raw string rather than a `switch` over
    /// `TripCoverState?`: `TripCoverState.none` and `Optional.none` are the same
    /// spelling, and a switch mixing them is the kind of code that reads correct
    /// and matches the wrong case.
    func needsFetch(_ trip: LocalTrip) -> Bool {
        guard let raw = trip.coverImageState else {
            return true  // Never attempted.
        }
        if raw == TripCoverState.none.rawValue {
            return false  // Searched, nothing suitable. Settled.
        }
        if raw == TripCoverState.resolved.rawValue {
            guard let path = trip.coverImagePath, !path.isEmpty else { return true }
            return storage.load(relativePath: path) == nil
        }
        // `failed`, or an unrecognised string written by a newer build.
        return true
    }

    /// Fetch, cache and stamp a cover onto one trip. Idempotent and single-flight.
    private func resolveIfNeeded(tripUUID: UUID) async {
        guard !inFlight.contains(tripUUID) else { return }
        let context = SwiftDataStore.shared.context

        guard let trip = fetchTrip(tripUUID, in: context), needsFetch(trip) else { return }
        let destination = trip.name

        inFlight.insert(tripUUID)
        defer { inFlight.remove(tripUUID) }

        do {
            guard let candidate = try await provider.cover(forDestination: destination) else {
                // A real place with no suitable photograph, or a trip name that is
                // not a place at all. Generated art is a good outcome here, not a
                // failure, so the state records it as settled.
                stamp(tripUUID, in: context) { trip in
                    trip.coverImagePath = nil
                    trip.coverImageSourceURL = nil
                    trip.coverImageAttribution = nil
                    trip.coverImageAttributionURL = nil
                    trip.coverImageState = TripCoverState.none.rawValue
                }
                return
            }

            let raw = try await TripCoverDownload.imageData(at: candidate.imageURL)
            // Reuses the receipt pipeline's 1600 px / q0.75 normalisation, off the
            // main actor: the decode and re-encode is the expensive step.
            let storage = self.storage
            let compressed = try await Task.detached(priority: .utility) {
                try storage.compress(imageData: raw)
            }.value
            let relativePath = try storage.saveCompressedJpeg(compressed)

            // Re-read the trip: an await ago it might have been deleted or
            // renamed again. If it is gone, drop the file we just wrote rather
            // than orphaning it.
            guard let current = fetchTrip(tripUUID, in: context) else {
                try? storage.delete(relativePath: relativePath)
                return
            }
            guard current.name == destination else {
                try? storage.delete(relativePath: relativePath)
                return
            }

            let previousPath = current.coverImagePath
            current.coverImagePath = relativePath
            current.coverImageSourceURL = candidate.imageURL.absoluteString
            current.coverImageAttribution = candidate.attribution
            current.coverImageAttributionURL = candidate.attributionURL?.absoluteString
            current.coverImageState = TripCoverState.resolved.rawValue
            current.updatedAt = Date()
            try? context.save()

            // The old file, if any, is now unreferenced. Deleting it after the
            // save (not before) means a failed save leaves the tile showing the
            // cover it already had.
            if let previousPath, previousPath != relativePath {
                try? storage.delete(relativePath: previousPath)
            }
        } catch {
            // Transient. Recorded as `failed` so the next launch's sweep retries,
            // rather than as `none`, which would give up permanently.
            NSLog("TripCoverService: cover fetch failed for %@: %@",
                  destination, String(describing: error))
            stamp(tripUUID, in: context) { trip in
                trip.coverImageState = TripCoverState.failed.rawValue
            }
        }
    }

    // MARK: - Store helpers

    private func fetchTrip(_ uuid: UUID, in context: ModelContext) -> LocalTrip? {
        let descriptor = FetchDescriptor<LocalTrip>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        return try? context.fetch(descriptor).first
    }

    /// Apply a mutation to a trip that may have been deleted while we were
    /// awaiting. `updatedAt` is deliberately NOT bumped for the failure/none
    /// paths: those record a fetch attempt, not a user edit, and bumping it would
    /// republish the row to every sync peer on every failed launch.
    private func stamp(
        _ uuid: UUID,
        in context: ModelContext,
        _ mutate: (LocalTrip) -> Void
    ) {
        guard let trip = fetchTrip(uuid, in: context) else { return }
        mutate(trip)
        try? context.save()
    }
}

// MARK: - Render-path image cache

/// In-memory cache of decoded cover bitmaps, keyed by relative path (#428).
///
/// The tile reads its cover synchronously, because the ticket's "no loading
/// state" guarantee rules out both a network call and a `.task` on a row. A raw
/// decode per render would be far too expensive in a scrolling `List`, so the
/// first render decodes and every later one is a dictionary lookup.
///
/// Self-invalidating: a re-fetch writes a NEW UUID filename, so the key changes
/// and the stale entry is simply never asked for again. Misses are cached too
/// (as `nil`), so a missing file does not cost a `fileExists` per render — the
/// repair sweep is what notices and mints a new path.
@MainActor
enum TripCoverImageCache {
    private static var entries: [String: PlatformImage?] = [:]

    /// The decoded cover for a relative path, or nil when there is no usable file.
    /// Never touches the network.
    static func image(forRelativePath path: String?) -> PlatformImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = entries[path] { return cached }
        let resolved: PlatformImage? = ReceiptStorage.tripCovers
            .load(relativePath: path)
            .flatMap { PlatformImage(contentsOfFile: $0.path) }
        entries[path] = resolved
        return resolved
    }
}
