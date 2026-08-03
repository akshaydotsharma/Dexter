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

    /// DESTINATION PATHS currently being generated, not trip UUIDs.
    ///
    /// Keyed on the artwork rather than the trip because the artwork is the shared
    /// resource. Keyed on the trip, two trips to Hong Kong in the same sweep both passed
    /// the guard and both paid — measured, and exactly the waste destination-keying exists
    /// to remove. The second now skips and picks the finished file up on the next pass,
    /// free.
    ///
    /// This still covers the original case: the same trip twice concurrently maps to the
    /// same path.
    private var inFlight: Set<String> = []

    /// Latch for the repair sweep. `.task` fires per WINDOW on macOS, not per
    /// process, and macOS restores multiple windows on relaunch — the same trap
    /// `AppMaintenance.didRunLaunchPass` documents.
    private var didRunRepairSweep = false

    /// Set once the account refuses everything. See `TripCoverArtProviderError`
    /// `.permanentlyRefused`: a spend cap or a revoked key will not start working because
    /// we asked again, so the rest of this process stops asking. The trips stay `failed`,
    /// so a later launch tries ONCE and recovers by itself when he tops up.
    private var generationBlocked = false

    /// Last time any sweep ran, so the foreground pass cannot fire on every activation.
    private var lastSweepAt: Date?
    /// Minimum gap between foreground sweeps. macOS `.active` fires on window focus, so
    /// without this a click back into the window would start a sweep.
    private let foregroundSweepInterval: TimeInterval = 2 * 60

    /// Ceiling on how many trips one sweep will generate.
    ///
    /// 12, so a normal library finishes in ONE pass. It was 2, which meant four trips
    /// needed two launches and the list stayed visibly half-filled in between — the
    /// backfill behaviour that was actually reported as wrong. This is not a
    /// performance budget any more, it is a stampede guard: the point is that a store
    /// with 200 trips cannot open 200 generations, not that a store with four should be
    /// rationed across launches.
    ///
    /// Safe to raise because the work is idempotent and bounded from both ends. A trip
    /// holding current-version art is never regenerated (`needsFetch`), so a relaunch
    /// with a filled library costs zero generations and zero spend.
    private let sweepBudget = 12

    /// How many generations may be in flight at once.
    ///
    /// Each generation is 20 to 45 seconds of almost entirely waiting on the network, so
    /// running them strictly serially made a four-trip backfill take minutes of wall
    /// clock for seconds of work. Three at a time gets a normal library done in about
    /// the time one image takes, and caps concurrent spend and memory.
    private let maxConcurrentGenerations = 3

    /// Stagger between STARTS, so a sweep opens three requests over a moment rather
    /// than in the same instant.
    private let sweepGap: Duration = .milliseconds(250)

    /// The context every read and write in this service goes through.
    ///
    /// Injectable, and that is load-bearing rather than tidiness: the failure this
    /// feature actually shipped — art that appeared and was gone on relaunch — is
    /// invisible to any test that cannot open a SECOND container on the same store
    /// file and check what landed. Resolving `SwiftDataStore.shared.context` inside
    /// each method made that untestable, so the bug had to be found by hand on a
    /// device.
    ///
    /// Resolved once at init rather than per call, so every mutation and the save
    /// that follows it are provably against the same context.
    private let context: ModelContext

    init(
        provider: TripCoverArtProvider = OpenAITripCoverArtProvider(),
        storage: ReceiptStorage = .tripCovers,
        context: ModelContext? = nil
    ) {
        self.provider = provider
        self.storage = storage
        self.context = context ?? SwiftDataStore.shared.context
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

    /// Recovery pass when the app comes back to the foreground.
    ///
    /// The launch sweep alone left a trip stranded: a `failed` trip waited for the user to
    /// relaunch, because nothing retried in-session. Throttled and idempotent, so the cost
    /// of calling it on every activation is a fetch and a filter.
    func runForegroundSweep() async {
        if let lastSweepAt, Date().timeIntervalSince(lastSweepAt) < foregroundSweepInterval {
            return
        }
        await sweep(reason: "foreground")
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
        // Collect art no trip references any more before generating anything, so a file
        // written moments from now cannot be mistaken for an orphan.
        reapOrphanedCovers()
        await sweep(reason: "launch")
    }

    private func sweep(reason: String) async {
        guard !generationBlocked else {
            NSLog("TripCoverService: %@ sweep skipped, generation is blocked", reason)
            return
        }
        lastSweepAt = Date()

        let trips: [LocalTrip]
        do {
            trips = try context.fetch(FetchDescriptor<LocalTrip>())
        } catch {
            NSLog("TripCoverService: sweep could not read trips: %@", String(describing: error))
            return
        }

        // Soonest-starting first, so the trips the user is about to look at get the
        // budget before a five-year-old one does. UUIDs, not models: the identifiers
        // cross into child tasks below and `LocalTrip` is not `Sendable`.
        let pending = trips
            .filter { needsFetch($0) }
            .sorted { abs($0.startDate.timeIntervalSinceNow) < abs($1.startDate.timeIntervalSinceNow) }
            .prefix(sweepBudget)
            .map(\.clientUUID)

        guard !pending.isEmpty else { return }
        NSLog("TripCoverService: %@ sweep generating %d cover(s), %d at a time",
              reason, pending.count, maxConcurrentGenerations)

        // Bounded concurrency: seed up to `maxConcurrentGenerations`, then start one
        // more each time one finishes. A plain `for` loop over `addTask` would launch
        // every pending generation at once and defeat the cap.
        await withTaskGroup(of: Void.self) { group in
            var queue = pending.makeIterator()
            var started = 0

            while started < maxConcurrentGenerations, let id = queue.next() {
                group.addTask { [weak self] in
                    await self?.resolveIfNeeded(tripUUID: id)
                }
                started += 1
                try? await Task.sleep(for: sweepGap)
            }

            while await group.next() != nil {
                guard let id = queue.next() else { continue }
                group.addTask { [weak self] in
                    await self?.resolveIfNeeded(tripUUID: id)
                }
            }
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
            // Art is keyed on the destination now, so a path that is not this
            // destination's key belongs to a place this trip is no longer going to —
            // a rename, or a row from before content-addressing.
            if let expected = TripCoverDestination.relativePath(for: trip.name),
               path != expected {
                return true
            }
            return storage.load(relativePath: path) == nil
        }
        // `failed`, or an unrecognised string written by a newer build.
        return true
    }

    /// Generate, crop, cache and stamp a cover onto one trip. Idempotent and
    /// single-flight.
    private func resolveIfNeeded(tripUUID: UUID) async {
        guard let trip = fetchTrip(tripUUID), needsFetch(trip) else { return }
        let destination = trip.name

        // A name that is not a place at all. Settled, not a failure: the tile draws
        // the airplane-glyph art, which is a first-class state. Checked BEFORE the
        // request, because an image model will happily illustrate "Work offsite" and
        // charge for the privilege.
        guard TripCoverPlaceness.isLikelyPlace(destination) else {
            stamp(tripUUID) { trip in
                trip.coverImagePath = nil
                trip.coverArtPromptVersion = nil
                trip.coverImageState = TripCoverState.none.rawValue
            }
            return
        }

        guard let relativePath = TripCoverDestination.relativePath(for: destination) else {
            stamp(tripUUID) { $0.coverImageState = TripCoverState.none.rawValue }
            return
        }

        // Already generated, for THIS destination, by another trip or by a version of this
        // trip that has since been deleted. No API call, no wait, no spend: the second
        // trip to Hong Kong is instant.
        if storage.load(relativePath: relativePath) != nil {
            NSLog("TripCoverService: reused cached art for %@", destination)
            stampResolved(tripUUID, path: relativePath, expecting: destination)
            return
        }

        guard !generationBlocked else { return }
        // Another trip to this same place is already generating it. Skip rather than pay
        // twice; the next sweep finds the file on disk and resolves for nothing.
        guard !inFlight.contains(relativePath) else {
            NSLog("TripCoverService: %@ already generating, will reuse it", destination)
            return
        }

        inFlight.insert(relativePath)
        defer { inFlight.remove(relativePath) }

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

            _ = try storage.write(data: prepared.0, relativePath: relativePath)
            NSLog("TripCoverService: generated cover for %@ — crop %@",
                  destination, prepared.1)

            // Re-read the trip: a generation takes tens of seconds, so it may well
            // have been deleted or renamed again meanwhile. If it is gone or renamed,
            // drop the file rather than orphaning it or captioning the wrong city.
            guard let current = fetchTrip(tripUUID) else {
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

            // The ONE durability point in this whole feature, so the error is handled
            // rather than discarded.
            //
            // A `try?` here is what turns a persistence failure into "it worked, then it
            // vanished": the in-memory model is already mutated, the view has already
            // observed it, and the illustration has already faded in. Everything looks
            // correct until the process restarts. That is a defect nobody can diagnose
            // from the outside, and it costs a device QA round trip to even notice.
            do {
                try context.save()
            } catch {
                // The mutation never reached the store, so roll it back and make memory
                // agree with disk rather than leaving the UI asserting something false.
                // The file just written is unreferenced now, so drop it. `failed` (not
                // `none`) so the next sweep retries.
                NSLog("TripCoverService: SAVE FAILED for %@, rolling back: %@",
                      destination, String(describing: error))
                context.rollback()
                try? storage.delete(relativePath: relativePath)
                stamp(tripUUID) { trip in
                    trip.coverImageState = TripCoverState.failed.rawValue
                }
                return
            }

            // The previous file is deliberately NOT deleted. Art is shared by destination
            // now, so another trip may be using it, and this code cannot tell. The reaper
            // decides what is genuinely unreferenced by asking the store.
            _ = previousPath
        } catch let refusal as TripCoverArtProviderError where isPermanent(refusal) {
            // The account is refusing everything. Stop asking for the rest of this
            // process rather than sending two more generations at a wall that has already
            // said no — that is how a hard spend limit gets hammered instead of respected.
            // Still `failed`, so a launch after he raises the cap retries once and heals.
            generationBlocked = true
            NSLog("TripCoverService: generation BLOCKED for this session: %@",
                  refusal.localizedDescription)
            stamp(tripUUID) { trip in
                trip.coverImageState = TripCoverState.failed.rawValue
            }
        } catch {
            // `failed`, never `none`. Generation is slow and can time out, hit a rate
            // limit, or be cancelled when the app backgrounds mid-flight; every one of
            // those deserves another attempt on the next launch. `none` is permanent
            // and is reserved for "this name is not a place".
            NSLog("TripCoverService: cover generation failed for %@: %@",
                  destination, String(describing: error))
            stamp(tripUUID) { trip in
                trip.coverImageState = TripCoverState.failed.rawValue
            }
        }
    }

    /// Whether a provider error means "do not ask again this session".
    private func isPermanent(_ error: TripCoverArtProviderError) -> Bool {
        switch error {
        case .permanentlyRefused, .notConfigured: return true
        default: return false
        }
    }

    /// Point a trip at art that is already on disk.
    ///
    /// Re-reads the trip and re-checks its name for the same reason the generation path
    /// does: this can be called after an await, and a trip renamed meanwhile must not be
    /// captioned with the previous city's art.
    private func stampResolved(_ uuid: UUID, path: String, expecting destination: String) {
        guard let trip = fetchTrip(uuid), trip.name == destination else { return }
        trip.coverImagePath = path
        trip.coverArtPromptVersion = TripCoverPrompt.version
        trip.coverImageSourceURL = nil
        trip.coverImageState = TripCoverState.resolved.rawValue
        trip.updatedAt = Date()
        do {
            try context.save()
        } catch {
            NSLog("TripCoverService: SAVE FAILED reusing cached art for %@: %@",
                  destination, String(describing: error))
            context.rollback()
            stamp(uuid) { $0.coverImageState = TripCoverState.failed.rawValue }
        }
    }

    // MARK: - Reaping

    /// Delete cover files no trip references.
    ///
    /// ## Why reaping rather than reference counting
    ///
    /// Once art is keyed on the destination, a file can be shared, so the old rule —
    /// delete the cover when its trip is deleted — became actively wrong: removing one
    /// Hong Kong would blank the other. Reference counting was the alternative and was
    /// rejected. A count is a second source of truth that has to be kept in step with the
    /// store across deletes, renames, archive restores AND sync applies, with no
    /// transaction spanning the file system and SwiftData; when it drifts it either leaks
    /// files forever or deletes one still in use. Reaping derives the answer from the
    /// store every time, so it cannot drift, and the cost of being wrong in the safe
    /// direction is a few hundred kilobytes until the next launch.
    ///
    /// Cover art also earns this treatment specifically: it is small and always
    /// re-derivable from the trip's name. A receipt photograph is neither, which is why
    /// its delete-with-the-row rule stays as it is.
    ///
    /// Called at launch BEFORE any generation, so a file about to be written cannot look
    /// unreferenced. The in-flight guard is belt and braces for any later caller.
    func reapOrphanedCovers() {
        guard inFlight.isEmpty else { return }
        let onDisk = storage.existingRelativePaths()
        guard !onDisk.isEmpty else { return }

        let referenced: Set<String>
        do {
            referenced = Set(
                try context.fetch(FetchDescriptor<LocalTrip>()).compactMap(\.coverImagePath)
            )
        } catch {
            // Without the store's answer every file looks unreferenced, and reaping on a
            // failed read would delete the entire cache.
            NSLog("TripCoverService: reap skipped, could not read trips: %@",
                  String(describing: error))
            return
        }

        var reaped = 0
        for path in onDisk where !referenced.contains(path) {
            do {
                try storage.delete(relativePath: path)
                reaped += 1
            } catch {
                NSLog("TripCoverService: could not reap %@: %@", path, String(describing: error))
            }
        }
        if reaped > 0 {
            NSLog("TripCoverService: reaped %d orphaned cover file(s), %d still referenced",
                  reaped, referenced.count)
        }
    }

    // MARK: - Store helpers

    /// A fetch failure is logged rather than silently read as "the trip is gone",
    /// because those two mean very different things and only one of them is normal.
    private func fetchTrip(_ uuid: UUID) -> LocalTrip? {
        let descriptor = FetchDescriptor<LocalTrip>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        do {
            return try context.fetch(descriptor).first
        } catch {
            NSLog("TripCoverService: trip fetch failed: %@", String(describing: error))
            return nil
        }
    }

    /// Apply a mutation to a trip that may have been deleted while we were awaiting.
    ///
    /// `updatedAt` is deliberately NOT bumped for the failure / `none` paths: those
    /// record an ATTEMPT, not a user edit, and bumping it would republish the row to
    /// every sync peer on every failed launch.
    ///
    /// The save is checked here too. This one only ever writes a state string, so a
    /// failure is less damaging than losing a path — but a silently unsaved `none` is a
    /// trip that re-generates forever, and a silently unsaved `failed` is a retry
    /// decision that never sticks. Both are worth a log line.
    private func stamp(
        _ uuid: UUID,
        _ mutate: (LocalTrip) -> Void
    ) {
        guard let trip = fetchTrip(uuid) else { return }
        mutate(trip)
        do {
            try context.save()
        } catch {
            NSLog("TripCoverService: state save failed for %@: %@",
                  uuid.uuidString, String(describing: error))
        }
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
/// Self-invalidating: a re-generation writes a NEW UUID filename, so the key changes
/// and the stale entry is simply never asked for again.
///
/// ## SUCCESSES ONLY. A miss is never cached.
///
/// It used to cache misses too, as `[String: PlatformImage?]`, to save a `fileExists`
/// per render. That was wrong, and wrong in a way that produced exactly the symptom
/// device QA reported — art that is there and then is not.
///
/// `if let cached = entries[path]` on a dictionary of OPTIONALS unwraps one level, so a
/// stored `nil` is a cache HIT that returns nil. One transient miss for a path
/// therefore blanked that trip for the entire remaining life of the process, no matter
/// what appeared on disk afterwards. Nothing could recover it: the sweep only mints a
/// new path when it decides to regenerate, and a trip whose art is present and correct
/// on disk is never regenerated, so the poisoned entry was permanent and invisible.
///
/// The cost of dropping it is one `fileExists` stat per render for a trip with no
/// readable art. That is microseconds, it only applies to the bounded set of trips the
/// sweep is actively filling, and it buys back the ability to recover. Blanking a
/// trip for a whole session to save a stat is not a trade worth making.
@MainActor
enum TripCoverImageCache {
    /// Non-optional values on purpose: it must be impossible to store a miss here.
    private static var entries: [String: PlatformImage] = [:]

    /// One-pixel columns lifted from the artwork's left and right edges (#441).
    ///
    /// A band wider than the file's 4:1 — every macOS window past ~528 pt of card
    /// width — has empty space either side of the artwork once the artwork is no longer
    /// scaled to the width. Stretching these two columns across that space continues
    /// whatever the illustration has at its edge: flat sky above, and the groundline
    /// or water below, which a single sampled colour would have flattened into sky and
    /// left a visible step at the bottom corners.
    ///
    /// Cached because they are derived per FILE, not per render, and a `cropping(to:)`
    /// on every frame of a live window resize is exactly the kind of work the decode
    /// cache exists to keep off the render path.
    private static var edgeEntries: [String: TripCoverEdges] = [:]

    /// The decoded cover for a relative path, or nil when there is no usable file.
    /// Never touches the network.
    static func image(forRelativePath path: String?) -> PlatformImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = entries[path] { return cached }
        guard let url = ReceiptStorage.tripCovers.load(relativePath: path),
              let image = PlatformImage(contentsOfFile: url.path) else {
            // Deliberately NOT recorded. The next render tries again, which is what
            // makes a file arriving late — or a path stamped a moment before its
            // bytes are visible — recoverable rather than terminal.
            return nil
        }
        entries[path] = image
        return image
    }

    /// The decoded cover plus its two edge columns, or nil when there is no usable
    /// file. One lookup, so the band cannot end up drawing one trip's artwork with
    /// another's edges after a path change mid-render.
    static func artwork(forRelativePath path: String?) -> TripCoverArtwork? {
        guard let path, let image = image(forRelativePath: path) else { return nil }
        if let cached = edgeEntries[path] {
            return TripCoverArtwork(image: image, edges: cached)
        }
        // Edges are an OPTIMISATION, not a requirement: a file whose CGImage cannot be
        // cropped still draws its artwork, just against a bare band either side. So a
        // failure here returns artwork with no edges rather than no artwork.
        guard let edges = TripCoverEdges(image: image) else {
            return TripCoverArtwork(image: image, edges: nil)
        }
        edgeEntries[path] = edges
        return TripCoverArtwork(image: image, edges: edges)
    }

    /// Drop everything. Test hook only; the cache needs no invalidation in the app
    /// because every regeneration mints a new key.
    static func reset() {
        entries.removeAll()
        edgeEntries.removeAll()
    }
}

/// A cover ready to draw: the artwork, and the columns that continue it sideways.
struct TripCoverArtwork {
    let image: PlatformImage
    let edges: TripCoverEdges?
}

/// The leftmost and rightmost pixel column of a cover, each as a full-height
/// one-pixel-wide bitmap (#441).
struct TripCoverEdges {
    let leading: PlatformImage
    let trailing: PlatformImage

    /// Nil when the bitmap has no `CGImage` backing or is degenerate. Cropping a
    /// 1 × height rect off each end is cheap and allocation-light: `cropping(to:)`
    /// shares the source's pixel storage rather than copying the image.
    init?(image: PlatformImage) {
        guard let cg = image.cgImageCompat, cg.width > 1, cg.height > 0 else { return nil }
        let column = CGSize(width: 1, height: CGFloat(cg.height))
        guard let left = cg.cropping(to: CGRect(origin: .zero, size: column)),
              let right = cg.cropping(
                  to: CGRect(origin: CGPoint(x: cg.width - 1, y: 0), size: column)
              )
        else { return nil }
        self.leading = PlatformImage.fromCGImage(left)
        self.trailing = PlatformImage.fromCGImage(right)
    }
}
