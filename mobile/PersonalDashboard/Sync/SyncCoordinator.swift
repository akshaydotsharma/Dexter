import Foundation
import Observation
import SwiftData

/// Process-wide owner of the sync pass. Follows the same shape as
/// `EmailIngestCoordinator` and `RecurringExpenseCoordinator`: one shared
/// instance, foreground-driven, and cheap to call when the feature is off.
///
/// Automatic passes are gated on `SyncSettings.enabled` and the feature ships
/// OFF. Writing into the user's iCloud folder is a visible side effect, so it
/// waits for an explicit opt-in.
@MainActor
@Observable
final class SyncCoordinator {

    static let shared = SyncCoordinator()

    /// Latest status, observed by the settings screen.
    private(set) var snapshot = SyncStatusSnapshot()
    private(set) var isSyncing = false

    private var engine: SyncEngine?
    private var timerTask: Task<Void, Never>?

    /// How often a pass runs while the app is frontmost.
    ///
    /// A timer rather than a filesystem watcher, deliberately, for phase 1. The
    /// obvious upgrade is FSEvents on macOS for near-instant pickup, but in a dry
    /// run NOTHING IS APPLIED, so inbound latency is invisible to the user by
    /// definition. Paying for a watcher buys nothing until phase 2 makes remote
    /// changes actually appear on screen, and it would be code carrying risk with
    /// no observable benefit. Revisit with phase 2, not before.
    private let interval: TimeInterval = 30

    private init() {}

    private func resolvedEngine() -> SyncEngine {
        if let engine { return engine }
        let engine = SyncEngine(modelContext: SwiftDataStore.shared.context)
        self.engine = engine
        return engine
    }

    // MARK: - Triggers

    /// Launch and foreground entry point. No-ops fast when sync is off.
    func runForegroundPass(reason: String) async {
        guard SyncSettings.enabled else {
            // Logged rather than silent. "Sync did nothing" and "sync is off"
            // are indistinguishable from the outside otherwise, and telling them
            // apart is the first question worth asking when a pass seems missing.
            SyncLog.line("SyncCoordinator: pass skipped (\(reason)), sync disabled")
            return
        }
        SyncLog.line("SyncCoordinator: pass requested (\(reason))")
        await pass(reason: reason)
    }

    /// Explicit "Sync now" from the status screen. Runs regardless of the enabled
    /// toggle, because the user pressing a button on the sync screen is a clearer
    /// statement of intent than the toggle is.
    func syncNow() async {
        await pass(reason: "manual")
    }

    /// Recompute status without running a pass. Used when the status screen
    /// appears, so pending counts are current without touching the folder.
    func refreshStatus() {
        snapshot = (try? resolvedEngine().snapshot()) ?? SyncStatusSnapshot()
    }

    /// Manual refresh from iOS pull-to-refresh or the macOS toolbar / ⌘R (#363).
    ///
    /// Two deliberate differences from `syncNow()`:
    ///
    /// 1. It goes through `runForegroundPass`, so it respects `SyncSettings.enabled`.
    ///    Pulling down in Tasks is a request to SEE current data, not consent to
    ///    start publishing into the user's iCloud folder. `syncNow()` overrides the
    ///    toggle because it is a button on the sync screen itself, where the intent
    ///    is unambiguous; a gesture in an unrelated section is not that.
    ///
    /// 2. It posts `localStoreDidChange` UNCONDITIONALLY, where a pass posts it only
    ///    when something actually applied. A manual refresh has to end in a visible
    ///    re-read whether or not anything arrived, otherwise the one case the user
    ///    reaches for it in — "I expected a change and it is not here" — is the case
    ///    where it appears to do nothing.
    func refreshNow(reason: String) async {
        await runForegroundPass(reason: reason)
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
    }

    // MARK: - Replay

    /// Outcome of a replay request, so the settings screen can report what happened
    /// rather than silently finishing.
    enum ReplayOutcome {
        case done(peersRewound: Int, applied: Int)
        case blockedNoBackup
        case blockedApplyOff
        case failed(String)
    }

    /// Re-read every peer's log from the first segment and apply it (#380).
    ///
    /// The repair path for a device whose apply cursor advanced during the phase 1
    /// dry run. Those segments are unreachable otherwise: the peer's shadow table
    /// marks their records as published, so nothing re-emits them.
    ///
    /// A FRESH backup is forced first, not the one-shot pre-flight one. A replay
    /// pushes a peer's entire history through the applier in one pass, which is the
    /// largest single write sync can make, and `sync.didPreflightBackup` may have
    /// been satisfied days and many edits ago. A blocked replay is recoverable; an
    /// unbounded apply with a stale archive behind it is not.
    func replayPeerLogs() async -> ReplayOutcome {
        // Replaying with applying off would rewind the cursor and then re-inspect
        // the log without writing anything, which looks like the repair ran and did
        // nothing. Refuse and say so instead.
        guard SyncSettings.applyEnabled else { return .blockedApplyOff }
        guard BackupSettings.folderBookmark != nil else { return .blockedNoBackup }

        isSyncing = true
        do {
            try await BackupService(modelContext: SwiftDataStore.shared.context)
                .runBackupIfDue(force: true)
            SyncLog.line("SyncCoordinator: backup written before replaying peer logs")
        } catch {
            isSyncing = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            SyncLog.line("SyncCoordinator: replay BLOCKED, backup failed: \(message)")
            return .failed(message)
        }

        let rewound: Int
        do {
            rewound = try resolvedEngine().resetPeerApplyCursors()
        } catch {
            isSyncing = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            SyncLog.line("SyncCoordinator: replay FAILED to rewind cursors: \(message)")
            return .failed(message)
        }
        isSyncing = false

        await pass(reason: "replay")
        // Unconditional, like `refreshNow`: the surfaces that cache their rows have
        // to re-read or the repaired records stay off screen until the view is
        // recreated, which reads as the replay having done nothing.
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        return .done(peersRewound: rewound, applied: snapshot.lastPassOpsApplied)
    }

    /// In-flight pass, so a second caller joins it instead of being turned away.
    private var passTask: Task<Void, Never>?

    private func pass(reason: String) async {
        // Coalesce rather than drop. This used to be `guard !isSyncing else
        // { return }`, which was harmless while every caller was a timer or a
        // launch hook that could afford to skip a beat. A manual refresh cannot:
        // an automatic pass runs every 30 seconds, so a pull landing during one
        // would return instantly, having done nothing, and the spinner would
        // confirm a check that never happened. Joining the running pass makes
        // the affordance tell the truth.
        if let passTask {
            await passTask.value
            return
        }
        // `guard let self` rather than `await self?.…`: the optional-chained call
        // makes the task's result `()?`, which is not the `Task<Void, Never>` the
        // stored property needs.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPass(reason: reason)
        }
        passTask = task
        await task.value
        passTask = nil
    }

    private func performPass(reason: String) async {
        isSyncing = true
        defer { isSyncing = false }
        // Two different contracts, chosen by whether this pass can WRITE.
        //
        // Applying off: publishing is append-only into a folder and cannot damage
        // the store, so the backup is hygiene. Fire it off without awaiting,
        // because awaiting would stall the launch that enables sync on a full
        // archive build (a 57 MB zip on real data) and look like a freeze.
        //
        // Applying on: this pass can destroy data. The backup stops being hygiene
        // and becomes the recovery path #349 verified, so it must exist BEFORE
        // anything is applied. Awaited, and a failure blocks the pass outright.
        // Refusing to sync is recoverable; applying with no way back is not.
        if SyncSettings.applyEnabled {
            guard await ensurePreflightBackup() else {
                snapshot = (try? resolvedEngine().snapshot()) ?? snapshot
                SyncLog.line("SyncCoordinator: pass BLOCKED — apply is on but no pre-flight backup exists")
                return
            }
        } else {
            startPreflightBackupIfNeeded()
        }
        snapshot = await resolvedEngine().runPass(reason: reason)
        scheduleDownloadRetryIfNeeded()
    }

    // MARK: - Waiting on iCloud (#451)

    /// Backoff for retrying a pass that stopped short on an undelivered segment.
    ///
    /// Short, then longer, then it stops and lets the periodic timer take over —
    /// the sum is about one timer period, so this never becomes a second timer
    /// running forever. It exists to close a specific gap: a pass that defers on
    /// a download used to cost a full 30 seconds before anything looked again,
    /// so a peer's change could take two poll intervals ON TOP of iCloud's own
    /// delivery time. Measured on the case that prompted this: a task created at
    /// 20:55:09 was published by the phone at 20:55:20 and applied on the Mac at
    /// 20:56:42.
    private static let downloadRetryDelays: [TimeInterval] = [3, 8, 15]

    private var downloadRetryTask: Task<Void, Never>?
    private var downloadRetryIndex = 0

    private func scheduleDownloadRetryIfNeeded() {
        guard snapshot.isWaitingOnDownloads else {
            // Caught up: forget the backoff so the next wait starts short again.
            downloadRetryIndex = 0
            return
        }
        guard downloadRetryTask == nil else { return }
        guard downloadRetryIndex < Self.downloadRetryDelays.count else {
            SyncLog.line("SyncCoordinator: still waiting on iCloud — leaving it to the timer")
            downloadRetryIndex = 0
            return
        }
        let delay = Self.downloadRetryDelays[downloadRetryIndex]
        downloadRetryIndex += 1
        downloadRetryTask = Task { @MainActor [weak self] in
            defer { self?.downloadRetryTask = nil }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.runForegroundPass(reason: "download-retry")
        }
    }

    // MARK: - Pre-flight backup

    private static let didPreflightBackupKey = "sync.didPreflightBackup"

    /// Force one backup before sync ever runs, so a known-good archive exists
    /// from before any sync code touched the store.
    ///
    /// Lives here rather than on the Settings toggle deliberately: this way it
    /// fires however sync gets switched on, including from `defaults write` in a
    /// test harness, rather than only down the one UI path someone remembered to
    /// instrument.
    ///
    /// ⚠️ PHASE 2 MUST MAKE THIS BLOCKING. Right now a failed backup logs and
    /// sync proceeds, which is correct only because phase 1 physically cannot
    /// write to the store, so there is nothing to recover from and refusing to
    /// start would be theatre. The moment inbound apply lands, "no verified
    /// backup" has to stop the pass. See #349 for verifying the restore path
    /// itself, which is the other half of this being worth anything.
    private var preflightTask: Task<Void, Never>?

    /// Blocking variant used when applying is on. Returns whether a pre-flight
    /// backup exists, running one if it has not been done yet.
    private func ensurePreflightBackup() async -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.didPreflightBackupKey) { return true }
        guard BackupSettings.folderBookmark != nil else {
            SyncLog.line("SyncCoordinator: cannot take a pre-flight backup, no backup folder configured")
            return false
        }
        do {
            try await BackupService(modelContext: SwiftDataStore.shared.context)
                .runBackupIfDue(force: true)
            defaults.set(true, forKey: Self.didPreflightBackupKey)
            SyncLog.line("SyncCoordinator: pre-flight backup written before first apply")
            return true
        } catch {
            SyncLog.line(
                "SyncCoordinator: pre-flight backup FAILED, refusing to apply: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            )
            return false
        }
    }

    private func startPreflightBackupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didPreflightBackupKey) else { return }
        // No folder means no archive can be written. Don't burn the one-shot flag
        // on an attempt that was never going to produce anything.
        guard BackupSettings.folderBookmark != nil else { return }
        guard preflightTask == nil else { return }

        preflightTask = Task { [weak self] in
            do {
                try await BackupService(modelContext: SwiftDataStore.shared.context)
                    .runBackupIfDue(force: true)
                defaults.set(true, forKey: Self.didPreflightBackupKey)
                SyncLog.line("SyncCoordinator: pre-flight backup written")
            } catch {
                SyncLog.line(
                    "SyncCoordinator: pre-flight backup failed, continuing because phase 1 cannot write to the store: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                )
            }
            self?.preflightTask = nil
        }
    }

    // MARK: - Write-triggered pass (#449)

    /// How long after a local write the durability pass runs.
    ///
    /// Long enough that typing a task title, correcting it and tagging it is one
    /// pass rather than three; short enough that "durable within seconds" is
    /// true. The periodic timer stays as the floor for anything this misses.
    private let writeDebounce: TimeInterval = 3

    /// A real local change has happened and no pass has published it yet.
    ///
    /// A flag rather than "run a pass now" because a write can land WHILE a pass
    /// is running, and that pass may already have read the store — joining it
    /// would report a publish that did not include this change. Measured on the
    /// first end-to-end run of this path: an import landed 245ms into the launch
    /// pass and would have waited for the 30s timer.
    private var hasUnpublishedWrite = false

    private var writeFlushTask: Task<Void, Never>?
    private var writeObserver: NSObjectProtocol?

    /// Run a full sync pass shortly after any local write (#449).
    ///
    /// The gap this closes is durability, not speed. Local storage is already
    /// immediate — every write calls `context.save()`. What was missing was an
    /// off-store copy: until a pass ran, the only copy of a change lived in one
    /// SQLite file that another branch's build can destroy. Waiting up to 33s for
    /// the timer, or until a scene edge, is what made the #446 loss total.
    ///
    /// ⚠️ THE PASS MUST STAY FULL. `SyncEngine.runPass` reads peers BEFORE
    /// emitting, deliberately: reading advances the Lamport clock past anything
    /// they have said, so what we emit sorts after it. An outbound-only shortcut
    /// would mint ops that look concurrent with changes already observed, which
    /// is the #380 stale-`lastKnownLamport` bug. Do not add one here for speed.
    ///
    /// Listens to `ModelContext.didSave` rather than `localStoreDidChange`, which
    /// is what #449 proposed. The notification is posted by hand at about nine
    /// call sites (the AI dispatcher, imports, the reminder scheduler) and NOT by
    /// the ordinary service-layer writes — adding a task in the UI posts nothing.
    /// Triggering off it would therefore leave the most common write in the app
    /// with no durability trigger at all, which is the failure this exists to
    /// prevent. `didSave` fires for every save the process makes, by
    /// construction, and cannot be forgotten at a new call site.
    func startObservingWrites() {
        guard writeObserver == nil else { return }
        writeObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] note in
            // `queue: nil` delivers on the saving thread; hop before touching
            // any of this actor's state.
            let entities = Self.entityNames(in: note)
            Task { @MainActor in self?.noteLocalWrite(entities: entities) }
        }
    }

    func stopObservingWrites() {
        if let writeObserver { NotificationCenter.default.removeObserver(writeObserver) }
        writeObserver = nil
        writeFlushTask?.cancel()
        writeFlushTask = nil
    }

    /// Entity names touched by a `didSave`, from the identifiers SwiftData puts
    /// in the notification. Empty when the shape is not what we expect, which is
    /// read as "something changed" rather than "nothing did" — an unrecognised
    /// notification must not be able to suppress a durability pass.
    nonisolated static func entityNames(in note: Notification) -> Set<String> {
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers,
        ]
        var names: Set<String> = []
        for key in keys {
            guard let ids = note.userInfo?[key.rawValue] as? [PersistentIdentifier] else { continue }
            names.formUnion(ids.map(\.entityName))
        }
        return names
    }

    /// Whether a save was sync writing its own bookkeeping and nothing else.
    ///
    /// Without this the pass that publishes a change schedules the pass that
    /// publishes nothing, and the app syncs forever at the debounce interval. A
    /// save that touches a real model as well is a real change, so the test is
    /// "ONLY sidecars" — and an empty set (an unrecognised notification shape)
    /// is NOT bookkeeping, because failing that way would silently disable the
    /// durability trigger this whole path exists to provide.
    ///
    /// The names come from `DataArchive.excludedModels`' sync half rather than a
    /// prefix match, so a future user-facing model called `SyncSomething` cannot
    /// quietly stop syncing.
    nonisolated static func isSyncBookkeepingOnly(_ entities: Set<String>) -> Bool {
        guard !entities.isEmpty else { return false }
        return entities.isSubset(of: syncSidecarEntities)
    }

    nonisolated private static let syncSidecarEntities: Set<String> = [
        "SyncDeviceState", "SyncShadow", "SyncTombstone", "SyncPeerCursor",
    ]

    /// Record a local change and make sure a pass follows it.
    private func noteLocalWrite(entities: Set<String>) {
        guard SyncSettings.enabled else { return }
        guard !Self.isSyncBookkeepingOnly(entities) else { return }
        hasUnpublishedWrite = true
        startWriteFlush()
    }

    /// One flusher, running until nothing is left unpublished.
    ///
    /// Three properties, each of which a naive "cancel and restart a timer"
    /// version gets wrong:
    ///
    /// 1. **Coalescing.** Writes arriving during the debounce share one pass, so
    ///    typing a title and then tagging it does not cost two.
    /// 2. **No starvation.** The window is not restarted per write, so a burst of
    ///    edits still publishes about `writeDebounce` after the first one rather
    ///    than after the last.
    /// 3. **A write during a pass still gets published.** The flag is cleared
    ///    BEFORE the pass, so anything that lands while it runs sets it again and
    ///    the loop goes round. Waiting on `passTask` first matters for the same
    ///    reason: `pass(reason:)` joins an in-flight pass rather than starting a
    ///    new one, and a pass that already read the store cannot have seen this
    ///    write.
    ///
    /// The sleep is at the top of every iteration, not just the first, so the
    /// loop cannot spin. That is also the backstop against a save this code
    /// cannot classify: the worst case is a pass every few seconds plus its own
    /// duration, which is no worse than the periodic timer it sits beside.
    private func startWriteFlush() {
        guard writeFlushTask == nil else { return }
        writeFlushTask = Task { @MainActor [weak self] in
            defer { self?.writeFlushTask = nil }
            while let self, self.hasUnpublishedWrite {
                try? await Task.sleep(nanoseconds: UInt64(self.writeDebounce * 1_000_000_000))
                if Task.isCancelled { return }
                if let inFlight = self.passTask { await inFlight.value }
                self.hasUnpublishedWrite = false
                await self.runForegroundPass(reason: "local-write")
            }
        }
    }

    // MARK: - Periodic

    func startPeriodic() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.interval ?? 30) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.runForegroundPass(reason: "timer")
            }
        }
    }

    func stopPeriodic() {
        timerTask?.cancel()
        timerTask = nil
    }
}
