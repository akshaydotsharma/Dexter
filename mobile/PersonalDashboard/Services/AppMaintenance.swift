import Foundation
import SwiftData

/// Periodic work that iOS runs from its scene and macOS previously ran nowhere
/// (#309).
///
/// `App/PersonalDashboardApp.swift` wires a `.task` plus a `scenePhase` observer
/// on iOS. `App/DexterMacApp.swift` has neither, so two shipped features are
/// silently dead on the Mac: automatic backup never fires no matter what the
/// Settings toggle says, and a recurring-expense template only posts when the
/// user happens to create, edit or resume it.
///
/// This type exists so the macOS scene needs four lines rather than any logic.
/// All policy — the once-per-process latch, the single-flight guard, the
/// foreground throttle, and which passes belong to launch versus activation —
/// lives here, so the shell cannot get it wrong:
///
/// ```swift
/// .task { await AppMaintenance.runLaunchPass() }
/// .onChange(of: scenePhase) { _, phase in
///     if phase == .active { Task { await AppMaintenance.runForegroundPass() } }
/// }
/// ```
///
/// Both entry points take no arguments and resolve `SwiftDataStore.shared`
/// internally, which keeps the shell's diff minimal and sidesteps any
/// `@Environment(\.modelContext)` timing question at scene construction.
/// Neither throws: failures are logged and, for backup, recorded into
/// `BackupSettings.lastError`, which the Settings surface already renders.
@MainActor
enum AppMaintenance {

    // MARK: - State

    /// Guards `runLaunchPass` against running more than once per process.
    ///
    /// Load-bearing, and not obvious: `.task` on a root view fires **per window,
    /// not per process**, and macOS restores multiple windows on relaunch. So two
    /// windows at launch would call this twice, concurrently. That is exactly the
    /// interleaving that double-posts a recurring expense, because
    /// `RecurringExpenseService.postIfNeeded` checks its dedupe key, then
    /// suspends on an FX fetch for up to 10 s before inserting, and `dedupeKey`
    /// carries no unique constraint (#321).
    ///
    /// A plain `Bool` is sufficient rather than a lock: everything here is
    /// `@MainActor`, and the flag is read and set synchronously before the first
    /// `await`, so no second caller can observe it unset.
    private static var didRunLaunchPass = false

    /// Guards against overlapping passes of any kind. Replaces the `isRunning`
    /// guard in `RecurringExpenseCoordinator.runCycle`, which the Mac cannot use
    /// because that file imports `BackgroundTasks` and registers a
    /// `BGAppRefreshTask` whose identifier is absent from `InfoMac.plist`.
    private static var isRunning = false

    /// Last time a foreground pass actually ran.
    private static var lastForegroundRun: Date?

    /// Minimum gap between foreground passes.
    ///
    /// macOS `.active` fires far more often than iOS's does — on window focus and
    /// app activation, not just on returning from the background — so without a
    /// throttle this would run on every click back into the window.
    private static let foregroundInterval: TimeInterval = 15 * 60

    // MARK: - Entry points

    /// Launch-only pass. Idempotent per process regardless of how many windows
    /// call it.
    static func runLaunchPass() async {
        guard !didRunLaunchPass else { return }
        didRunLaunchPass = true
        await runPasses(isLaunch: true)
    }

    /// Foreground/activation pass. Safe and cheap to call on every `.active`.
    static func runForegroundPass() async {
        if let last = lastForegroundRun,
           Date().timeIntervalSince(last) < foregroundInterval {
            return
        }
        lastForegroundRun = Date()
        await runPasses(isLaunch: false)
    }

    // MARK: - Work

    private static func runPasses(isLaunch: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        await materialiseRecurringExpenses()
        await runBackupIfDue(isLaunch: isLaunch)
    }

    /// Post any recurring-expense months that have come due.
    ///
    /// `notify: false` deliberately: on iOS the coordinator passes `true` because
    /// a background pass needs to tell the user something happened. Here the pass
    /// runs while the app is in front of them, and a banner for something they can
    /// see in Finance is noise. It also means `requestAuthorizationIfNeeded` is
    /// never reached, so macOS is not prompted for notification permission it has
    /// no other use for yet.
    private static func materialiseRecurringExpenses() async {
        let posted = await RecurringExpenseService.default().materialize(notify: false)
        if !posted.isEmpty {
            NSLog("AppMaintenance: materialised %d recurring expense(s)", posted.count)
        }
    }

    /// Run a backup if the user's configured frequency says one is due.
    ///
    /// `BackupService.runBackupIfDue(force:)` is self-gating via
    /// `BackupSettings.isDue()`, which short-circuits on `enabled` and a chosen
    /// folder, so the no-op path is cheap. But `BackupFrequency.everyLaunch` has
    /// a `minimumInterval` of 0, which makes `isDue()` unconditionally true for
    /// that setting. On iOS that is harmless because `.active` means returning
    /// from the background; on macOS it fires on window focus, so calling this on
    /// every activation would zip and write the entire store every time the user
    /// clicked back into the window.
    ///
    /// So `everyLaunch` is honoured on launch only. A genuine interval
    /// (`daily`/`weekly`) is checked on both.
    private static func runBackupIfDue(isLaunch: Bool) async {
        if !isLaunch && BackupSettings.frequency == .everyLaunch { return }
        do {
            let didRun = try await BackupService(modelContext: SwiftDataStore.shared.context)
                .runBackupIfDue(force: false)
            if didRun { NSLog("AppMaintenance: wrote a scheduled backup") }
        } catch {
            // Non-forced runs are documented not to throw when simply not due, so
            // reaching here means a real failure. `BackupService` has already
            // recorded it into `BackupSettings.lastError` for the Settings screen;
            // this is not swallowed, it is surfaced there rather than thrown into
            // a scene hook that has nowhere to put it.
            NSLog("AppMaintenance: scheduled backup failed: %@", String(describing: error))
        }
    }
}

// MARK: - Sequencing note
//
// The blocker recorded here previously — `runBackupIfDue` being synchronous and
// building the whole zip inline on the main actor — is now cleared.
// `BackupService.runBackupIfDue` is `async`, and the archive build and the
// coordinated write both hop off the main actor via `Task.detached`. So this
// type is ready to be wired into the macOS scene.
//
// What is NOT resolved, and should not be described as resolved to whoever
// wires it: the main-actor hold is reduced, not eliminated. `DataExportService`
// runs 13 `FetchDescriptor` fetches against `container.mainContext` plus the
// DTO mapping, and a `ModelContext` is main-actor-confined, so those cannot
// leave the main actor without a background context or `@ModelActor`. That is a
// data-layer change filed as #334, deliberately out of scope here. Attachment
// path resolution also stays on main because `ReceiptStorage` and
// `TicketStorage` are `@MainActor`, though that is only a `fileExists` stat per
// attachment and reads no bytes.
//
// So: "fetch plus DTO mapping" still runs on the main actor on every due
// backup. On a 1541-expense store that is expected to be short but is not
// nothing, and it is the honest ceiling on what this ticket bought.
