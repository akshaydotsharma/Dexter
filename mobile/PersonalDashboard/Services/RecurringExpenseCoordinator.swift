import Foundation
import BackgroundTasks

/// App-level glue for recurring-expense materialisation (#236):
///  - Registers and schedules a best-effort BGAppRefreshTask.
///  - Runs a foreground materialisation pass on launch and return-to-foreground.
///
/// Foreground is the reliable path (iOS decides if/when the background task
/// runs). Mirrors `EmailIngestCoordinator`'s structure (plain class so it can
/// be poked from the nonisolated `AppDelegate`), but this type is NOT the
/// `UNUserNotificationCenter` delegate — that role is owned by
/// `EmailIngestCoordinator` (only one delegate is allowed), and the recurring
/// notification needs no custom actions, so it rides the shared delegate.
final class RecurringExpenseCoordinator {

    static let shared = RecurringExpenseCoordinator()

    /// Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist.
    static let refreshTaskId = "com.akshaysharma.personaldashboard.recurringExpenseRefresh"

    private var isRunning = false

    private init() {}

    // MARK: - Launch wiring

    /// Register the background task. Must be called before the app finishes
    /// launching (AppDelegate.didFinishLaunching) for the registration to take.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskId,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleRefreshTask(refreshTask)
        }
    }

    /// Foreground entry point — launch and return-to-foreground both call this.
    /// Runs one materialisation pass (with notification) and (re)schedules the
    /// background task.
    @MainActor
    func runForegroundMaterialize() async {
        await runCycle(notify: true)
        scheduleBackgroundRefresh()
    }

    // MARK: - Background task

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        // Earliest 6h out; iOS coalesces and decides the real time. A recurring
        // charge is a once-a-month event, so frequent polling buys nothing.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("RecurringExpenseCoordinator: couldn't schedule refresh: %@", error.localizedDescription)
        }
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        // Always schedule the next one so the chain continues.
        scheduleBackgroundRefresh()

        let work = Task { @MainActor in
            await runCycle(notify: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    @MainActor
    private func runCycle(notify: Bool) async {
        // Avoid overlapping cycles (launch + foreground can race).
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        _ = await RecurringExpenseService.default().materialize(notify: notify)
    }
}
