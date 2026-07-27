import Foundation
import Observation

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
