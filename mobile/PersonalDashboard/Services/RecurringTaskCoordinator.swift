import Foundation

/// App-level glue for recurring-task materialisation (#524).
///
/// ### Why this is not `RecurringExpenseCoordinator`
///
/// That one imports `BackgroundTasks` and registers a `BGAppRefreshTask`, which
/// makes it iOS-only, and it is not in the `DexterMac` source list. The other
/// candidate, `AppMaintenance.runPasses`, has been dead on every platform since
/// #309 built it, so wiring into it would switch on two unrelated features as a
/// side effect. This is deliberately neither: a plain foreground pass with a
/// single-flight guard, called from both apps' launch and activation hooks.
///
/// ### Why no background task
///
/// There is nothing to deliver. An occurrence only has to exist by the time the
/// person looks at their tasks, and looking at them means the app is in front of
/// them, which has already run this. The reminder on the occurrence is a real
/// `UNNotificationRequest` scheduled by `TaskReminderScheduler`, and that fires
/// whether or not the app ever woke up in between.
@MainActor
final class RecurringTaskCoordinator {

    static let shared = RecurringTaskCoordinator()

    private var isRunning = false

    private init() {}

    /// Run one pass. Launch, return-to-foreground, and the Tasks list's own reload
    /// all call this; the guard is what makes calling it from three places free.
    ///
    /// Returns the tasks created, so a caller that is already on screen (the
    /// editor, after saving a new template) can react to a first occurrence
    /// appearing immediately.
    @discardableResult
    func runPass(reference: Date = Date()) async -> [RecurringTaskService.Created] {
        guard !isRunning else { return [] }
        isRunning = true
        defer { isRunning = false }

        let created = RecurringTaskService.default().materialize(reference: reference)
        if !created.isEmpty {
            // A new occurrence may carry an armed reminder, and the service writes
            // rows straight into the context rather than through `TodoService`, so
            // the reconcile that normally rides every task write happens here
            // instead — once for the whole pass, not once per row.
            await TaskReminderScheduler.reconcile(store: .shared)
            NSLog("RecurringTaskCoordinator: created %d recurring task(s)", created.count)
        }
        return created
    }
}
