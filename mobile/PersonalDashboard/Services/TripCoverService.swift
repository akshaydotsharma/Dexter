import Foundation
import SwiftData

/// The three values `LocalTrip.coverImageState` can hold, plus nil for "never
/// attempted" (#428).
///
/// Genuinely three-valued, and the distinction is what stops a runaway: `none`
/// means "this name is not a place", which is a settled answer, where `failed`
/// means "generation let us down", which is worth another go. Collapsing the two
/// would make the app re-generate forever for a trip called "Work offsite" — at
/// tens of seconds and real money per attempt.
enum TripCoverState: String {
    case resolved
    case none
    case failed
}

/// Failures raised by the service itself, as opposed to by the provider.
enum TripCoverServiceError: LocalizedError {
    /// The model returned an image the crop could not make sense of — blank, or
    /// with no detectable silhouette. Recorded as `failed` so a re-roll happens,
    /// because a second generation of the same prompt usually differs.
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .cropFailed: return "The generated cover art had no detectable skyline."
        }
    }
}

/// Generates a destination illustration, crops it to the band, and caches it on
/// disk, so the tile can render a cover with no network call on any path (#428).
///
/// Two entry points, both off the render path:
///   - `resolveOnWrite(tripUUID:)` from `TripEditorSheet.save()`, for a new or
///     renamed trip. This is the PRIMARY path, and it matters more than it did
///     under photography: generation takes tens of seconds, so doing it at write
///     time — when the user has just told us the destination — is the only way the
///     art is usually already there by the time they look at the list.
///   - `runRepairSweep()` from `AppMaintenance`, once per launch, for trips whose
///     state is nil or `failed`, whose cached file has gone missing, or whose art
///     was made by a superseded prompt version.
///
/// Nothing here is called from a view body, a `.task` on a row, or any other
/// render path. That is what makes "there is no loading state" true rather than
/// aspirational, and it is why the tile has no spinner, shimmer or
/// placeholder-flash question to answer. It matters far more now: a spinner tied to
/// a 30-second generation would be a 30-second spinner.
@MainActor
final class TripCoverService {

    static let shared = TripCoverService()

    private let provider: TripCoverArtProvider
    private let storage: ReceiptStorage

    /// Trips currently being generated. Both entry points can fire for the same
    /// trip (save a rename, then a sweep on the next launch mid-flight), and two
    /// concurrent generations would write two files, leak one, and bill twice.
    private var inFlight: Set<UUID> = []

    /// Latch for the repair sweep. `.task` fires per WINDOW on macOS, not per
    /// process, and macOS restores multiple windows on relaunch — the same trap
    /// `AppMaintenance.didRunLaunchPass` documents.
    private var didRunRepairSweep = false

    /// Ceiling on how many trips one sweep will generate.
    ///
    /// Cut from 6 to 2 for the pivot to generated art. Under photography a sweep was
    /// three quick HTTP requests per trip and six of them took about ten seconds;
    /// generation is tens of seconds EACH, so six would be several minutes of
    /// background work and several images' worth of spend on every cold launch. Two
    /// keeps a launch bounded, and the rest are picked up by the next launch's sweep.
    /// Write-time generation is the path that is meant to do the work.
    private let sweepBudget = 2

    /// Gap between generations inside a sweep. Now trivial next to the generation
    /// time itself, kept so the sweep never becomes a tight loop if generation starts
    /// failing fast.
    private let sweepGap: Duration = .seconds(1)

    init(
        provider: TripCoverArtProvider = OpenAITripCoverArtProvider(),
        storage: ReceiptStorage = .tripCovers
    ) {
        self.provider = provider
        self.storage = storage
    }

    // MARK: - Entry points

    /// Generate a cover for a trip the user has just created or renamed.
    ///
    /// A rename invalidates whatever art was there: the destination changed, so the
    /// illustration is now of the wrong city. The old fields (and file) are cleared
    /// by `TripEditorSheet` before this runs, which puts the trip back into the nil
    /// state this method generates for.
    func resolveOnWrite(tripUUID: UUID) async {
        await resolveIfNeeded(tripUUID: tripUUID)
    }

    /// Once-per-launch pass over trips that have no usable cover.
    ///
    /// Four populations qualify:
    ///   - state nil — never attempted (every pre-existing trip on first launch
    ///     after this ships, including every trip that still carries a fetched
    ///     PHOTOGRAPH from build 1102, because those have no prompt version).
    ///   - state `failed` — generation let us down last time.
    ///   - state `resolved` but the file is not on disk. That is the sync case:
    ///     `coverImagePath` carries a UUID filename minted on the OTHER device,
    ///     which this device does not have.
    ///   - state `resolved` with art from a superseded `coverArtPromptVersion`.
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
    /// The `resolved`-but-missing-file branch is the self-healing rule, and its
    /// MECHANISM changed with the pivot while its property did not. There is no
    /// remote URL to re-fetch any more: a peer that received the row but not the file
    /// regenerates the illustration from the destination name instead. Cover art is
    /// still always re-derivable, so a missing file still cannot be data loss.
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
            return false  // Not a place. Settled.
        }
        if raw == TripCoverState.resolved.rawValue {
            // Art from a superseded prompt. This is the entire reason
            // `coverArtPromptVersion` exists: without it, a prompt change would leave
            // a device showing a mix of old and new art with no way to tell which is
            // which. It also catches every fetched PHOTOGRAPH from build 1102, whose
            // version is nil, so those get replaced by illustrations.
            if trip.coverArtPromptVersion != TripCoverPrompt.version { return true }
            guard let path = trip.coverImagePath, !path.isEmpty else { return true }
            return storage.load(relativePath: path) == nil
        }
        // `failed`, or an unrecognised string written by a newer build.
        return true
    }

    /// Generate, crop, cache and stamp a cover onto one trip. Idempotent and
    /// single-flight.
    private func resolveIfNeeded(tripUUID: UUID) async {
        guard !inFlight.contains(tripUUID) else { return }
        let context = SwiftDataStore.shared.context

        guard let trip = fetchTrip(tripUUID, in: context), needsFetch(trip) else { return }
        let destination = trip.name

        // A name that is not a place at all. Settled, not a failure: the tile draws
        // the airplane-glyph art, which is a first-class state. Checked BEFORE the
        // request, because an image model will happily illustrate "Work offsite" and
        // charge for the privilege.
        guard TripCoverPlaceness.isLikelyPlace(destination) else {
            stamp(tripUUID, in: context) { trip in
                trip.coverImagePath = nil
                trip.coverArtPromptVersion = nil
                trip.coverImageState = TripCoverState.none.rawValue
            }
            return
        }

        inFlight.insert(tripUUID)
        defer { inFlight.remove(tripUUID) }

        do {
            let generated = try await provider.illustration(forDestination: destination)

            // Crop and re-encode off the main actor. Both steps are pure pixel work
            // on value types, and the crop reads every row of a 1536x1024 bitmap, so
            // it has no business on the main actor.
            let storage = self.storage
            let prepared = try await Task.detached(priority: .utility) { () -> (Data, String) in
                guard let cropped = TripCoverCrop.crop(generated) else {
                    throw TripCoverServiceError.cropFailed
                }
                // Reuses the receipt pipeline's 1600 px / q0.75 normalisation. The
                // cropped band is 1536 wide, so this re-encodes without downsizing.
                let compressed = try storage.compress(imageData: cropped.imageData)
                return (compressed, cropped.summary)
            }.value

            let relativePath = try storage.saveCompressedJpeg(prepared.0)
            NSLog("TripCoverService: generated cover for %@ — crop %@",
                  destination, prepared.1)

            // Re-read the trip: a generation takes tens of seconds, so it may well
            // have been deleted or renamed again meanwhile. If it is gone or renamed,
            // drop the file rather than orphaning it or captioning the wrong city.
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
            current.coverArtPromptVersion = TripCoverPrompt.version
            // `coverImageSourceURL` stays nil deliberately. There is no remote source
            // for generated art, and repurposing this field would make the sync
            // self-heal ambiguous — a non-nil value would have to mean two different
            // things depending on which build wrote it.
            current.coverImageSourceURL = nil
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
            // `failed`, never `none`. Generation is slow and can time out, hit a rate
            // limit, or be cancelled when the app backgrounds mid-flight; every one of
            // those deserves another attempt on the next launch. `none` is permanent
            // and is reserved for "this name is not a place".
            NSLog("TripCoverService: cover generation failed for %@: %@",
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
