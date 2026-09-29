import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Runs the Shortcut's queued captures, one at a time, after the intent has
/// already replied (#685).
///
/// ## Who owns it
///
/// App-level and shared, like `SyncCoordinator` and `ImportJobCenter`. Not the
/// intent struct, which is gone the moment `perform()` returns, and not a view,
/// whose state dies with it (project memory:
/// view_owned_job_state_dies_with_the_view). The intent runs in the app
/// process (there is no extension), so the same `shared` instance serves the
/// Shortcut, the launch pass and the foreground pass.
///
/// ## When it runs
///
/// `kick(reason:)` from three places: the intent after it enqueues
/// ("shortcut"), `AppDelegate.didFinishLaunching` ("launch", which also fires
/// for the background launch a Shortcut causes), and the scene becoming active
/// ("foreground"). A kick while a pass is running sets `pendingKick`, and the
/// pass looks again before it ends, so a job enqueued in the last moment of a
/// pass is never stranded until the next launch.
///
/// ## Time
///
/// Each job races `capSeconds` (60 s, `CaptureService.timeoutSeconds`). The cap
/// is terminal: the job fails with a notification and the next one runs. The
/// whole pass sits inside one `beginBackgroundTask`, and when iOS expires it,
/// the job in hand is cancelled and left resumable: back to `queued` if no
/// write started, failed-partial if one did (see `CaptureJob`). Every job logs
/// `backgroundTimeRemaining` at its start, at each model turn and at each
/// write, plus its total elapsed, because how long iOS really allows a
/// Shortcut-launched app is not documented and is the thing to learn here.
///
/// `BGContinuedProcessingTaskRequest` is not used: it runs "on behalf of the
/// currently foregrounded app", and during a Shortcut Dexter is not. Worth a
/// look as a follow-up for the case where the capture starts inside the app.
@MainActor
final class CaptureQueueRunner {

    /// The model run for one job. Live: `CaptureService.runCapture`. Tests
    /// inject a stub, so no test touches the real store or the network.
    typealias Executor = @MainActor (CaptureJob, ChatToDrafts.Hooks) async -> CaptureResponse
    /// Post one notification; returns a short status for the log.
    typealias Notifier = @MainActor (CaptureJob) async -> String

    static let shared = CaptureQueueRunner(
        queue: .shared,
        executor: { job, hooks in
            await CaptureService.runCapture(input: job.input, timezone: job.timezone, hooks: hooks)
        },
        notifier: { job in await CaptureNotifications.post(job) },
        background: SystemBackgroundTime()
    )

    /// Starts allowed per job before it fails. Only iOS interruptions with no
    /// write started count against it; each start is a paid model run.
    static let maxAttempts = 3

    let queue: CaptureQueue
    let capSeconds: Double
    /// This process's id. A job in flight under any other id is stale.
    let session = UUID()

    private let executor: Executor
    private let notifier: Notifier
    private let background: CaptureBackgroundTime

    private var drainTask: Task<Void, Never>?
    private var pendingKick = false
    private var expired = false

    init(
        queue: CaptureQueue,
        capSeconds: Double = Double(CaptureService.timeoutSeconds),
        executor: @escaping Executor,
        notifier: @escaping Notifier,
        background: CaptureBackgroundTime
    ) {
        self.queue = queue
        self.capSeconds = capSeconds
        self.executor = executor
        self.notifier = notifier
        self.background = background
    }

    // MARK: - Kick

    /// Start a pass, or ask the running one to look again. Synchronous up to
    /// the background task on purpose: the intent calls this just before
    /// `perform()` returns, and the task must be held by then.
    @discardableResult
    func kick(reason: String) -> Task<Void, Never> {
        if let drainTask {
            pendingKick = true
            CaptureQueueLog.line("kick reason=\(reason) (pass already running) bgRemaining=\(remainingText)")
            return drainTask
        }
        expired = false
        pendingKick = false
        CaptureQueueLog.line("kick reason=\(reason) bgRemaining=\(remainingText)")
        let begunAt = Date()
        background.begin { [weak self] in
            // Main thread, per UIKit. Cancel the job in hand and give the time
            // back now: an app that overruns its expiration is killed, and a
            // killed app is exactly the case the job states already cover.
            guard let self else { return }
            self.expired = true
            CaptureQueueLog.line(String(format: "background time EXPIRED %.1fs after it began", Date().timeIntervalSince(begunAt)))
            self.drainTask?.cancel()
            self.background.end()
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
            CaptureQueueLog.line(String(format: "pass over after %.1fs bgRemaining=%@", Date().timeIntervalSince(begunAt), self.remainingText))
            self.background.end()
            self.drainTask = nil
            if self.pendingKick {
                // A kick landed while an expired pass was unwinding.
                self.kick(reason: "pending")
            }
        }
        drainTask = task
        return task
    }

    /// Wait until no pass is running, including one a pending kick started.
    func waitUntilIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    // MARK: - Pass

    private func drain() async {
        await queue.recoverInterrupted(currentSession: session, maxAttempts: Self.maxAttempts)
        await deliverNotifications()
        while !expired, !Task.isCancelled {
            guard let job = await queue.claimNext(session: session) else {
                if pendingKick {
                    pendingKick = false
                    continue
                }
                break
            }
            await run(job)
            await deliverNotifications()
        }
    }

    private enum Race {
        case finished(CaptureResponse)
        case capped
        case interrupted
    }

    private func run(_ job: CaptureJob) async {
        let started = Date()
        let tag = "job=\(job.shortID)"
        func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(started)) }
        CaptureQueueLog.line("\(tag) start attempt=\(job.attempts) bgRemaining=\(remainingText)")

        var tools: [String] = []
        let queue = self.queue
        let hooks = ChatToDrafts.Hooks(
            onTurn: { [weak self] turn in
                CaptureQueueLog.line("\(tag) turn=\(turn) elapsed=\(elapsed()) bgRemaining=\(self?.remainingText ?? "?")")
            },
            beforeWrite: { [weak self] tool in
                try await queue.markWriting(id: job.id, tool: tool)
                tools.append(tool)
                CaptureQueueLog.line("\(tag) write tool=\(tool) elapsed=\(elapsed()) bgRemaining=\(self?.remainingText ?? "?")")
            }
        )

        let capNanos = UInt64(capSeconds * 1_000_000_000)
        let executor = self.executor
        let race: Race = await withTaskGroup(of: Race.self) { group in
            group.addTask { @MainActor in
                let response = await executor(job, hooks)
                // A run cut short by cancellation reports whatever error that
                // produced. It is not an answer, so it never becomes one.
                return Task.isCancelled ? .interrupted : .finished(response)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: capNanos)
                    return .capped
                } catch {
                    return .interrupted
                }
            }
            let first = await group.next() ?? .interrupted
            group.cancelAll()
            return first
        }

        switch race {
        case .finished(let response):
            let text = CaptureToDashboardIntent.notificationText(for: response)
            let open = CaptureToDashboardIntent.openIntent(for: response.executed ?? [])
            let content = CaptureJobText.Content(
                title: text.title,
                body: text.body,
                openSection: open?.section,
                openID: open.flatMap { $0.rawIdentifier.isEmpty ? nil : $0.rawIdentifier }
            )
            await queue.finish(id: job.id, state: response.status == .error ? .failed : .done, text: content)
            CaptureQueueLog.line("\(tag) end result=\(response.status.rawValue) writes=\(tools.count) elapsed=\(elapsed()) bgRemaining=\(remainingText)")
        case .capped:
            await queue.finish(id: job.id, state: .failed, text: CaptureJobText.capped(seconds: capSeconds, tools: tools))
            CaptureQueueLog.line("\(tag) end result=capped writes=\(tools.count) elapsed=\(elapsed()) bgRemaining=\(remainingText)")
        case .interrupted:
            if !tools.isEmpty {
                await queue.finish(id: job.id, state: .failed, text: CaptureJobText.partial(tools: tools, reason: .interrupted))
                CaptureQueueLog.line("\(tag) end result=interrupted-after-write, NOT re-run writes=\(tools.count) elapsed=\(elapsed())")
            } else if job.attempts >= Self.maxAttempts {
                await queue.finish(id: job.id, state: .failed, text: CaptureJobText.exhausted(attempts: job.attempts))
                CaptureQueueLog.line("\(tag) end result=interrupted, attempts used up elapsed=\(elapsed())")
            } else {
                await queue.requeue(id: job.id)
                CaptureQueueLog.line("\(tag) end result=interrupted, requeued (no write started) elapsed=\(elapsed())")
            }
        }
    }

    private func deliverNotifications() async {
        for job in await queue.unnotified() {
            let status = await notifier(job)
            CaptureQueueLog.line("job=\(job.shortID) notification \(status)")
            await queue.markNotified(id: job.id)
        }
    }

    private var remainingText: String {
        guard let seconds = background.remaining else { return "foreground" }
        return String(format: "%.1fs", seconds)
    }
}

// MARK: - Background time

/// The slice of `UIApplication` background time the runner uses, so tests can
/// run the queue with no app and no expiry.
@MainActor
protocol CaptureBackgroundTime: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void)
    func end()
    /// Seconds left, or nil while the app is in the foreground (iOS reports
    /// `.greatestFiniteMagnitude` then).
    var remaining: TimeInterval? { get }
}

@MainActor
final class SystemBackgroundTime: CaptureBackgroundTime {
    #if canImport(UIKit)
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(expiration: @escaping @MainActor () -> Void) {
        guard id == .invalid else { return }
        id = UIApplication.shared.beginBackgroundTask(withName: "Dexter capture") {
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated { expiration() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        let held = id
        // Cleared BEFORE the call, so an expiration firing during
        // `endBackgroundTask` cannot end the same identifier twice.
        id = .invalid
        UIApplication.shared.endBackgroundTask(held)
    }

    var remaining: TimeInterval? {
        let value = UIApplication.shared.backgroundTimeRemaining
        return value > 1_000_000 ? nil : value
    }
    #else
    func begin(expiration: @escaping @MainActor () -> Void) {}
    func end() {}
    var remaining: TimeInterval? { nil }
    #endif
}

// MARK: - Notifications

/// The capture result as a local notification (#685).
///
/// Permission: reuses the app's one flow (`EmailIngestNotifications`
/// `.requestAuthorizationIfNeeded`), asked on a foreground pass once the queue
/// has been used, because iOS shows no prompt to a backgrounded app. Without
/// permission the capture still lands in the data; the post is skipped and the
/// log says so. The shared delegate in `EmailIngestCoordinator` shows the
/// banner while Dexter is open too, and sends a tap to `destination(from:)`,
/// which opens the section (and row) the capture wrote to.
enum CaptureNotifications {
    static let threadID = "capture"
    static let sectionKey = "captureOpenSection"
    static let idKey = "captureOpenID"

    @MainActor
    static func post(_ job: CaptureJob) async -> String {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return "skipped (authorization=\(settings.authorizationStatus.rawValue)); the result is in the data"
        }
        let content = UNMutableNotificationContent()
        content.title = job.outcomeTitle ?? "Capture"
        content.subtitle = "\u{201C}\(String(job.input.prefix(60)))\(job.input.count > 60 ? "…" : "")\u{201D}"
        content.body = job.outcomeBody ?? "Done."
        content.sound = .default
        content.threadIdentifier = threadID
        var info: [String: String] = [:]
        if let section = job.openSection { info[sectionKey] = section }
        if let id = job.openID { info[idKey] = id }
        content.userInfo = info
        // The job id, so a re-post after a kill replaces instead of doubling.
        let request = UNNotificationRequest(identifier: "capture-\(job.id.uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
            return "delivered"
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    /// The section and row a tapped capture notification opens, or nil when
    /// the notification is not one of ours.
    static func destination(from userInfo: [AnyHashable: Any]) -> (section: String, id: UUID?)? {
        guard let section = userInfo[sectionKey] as? String else { return nil }
        return (section, (userInfo[idKey] as? String).flatMap(UUID.init(uuidString:)))
    }

    /// Ask once, from the foreground, after the queue has been used.
    static func requestAuthorizationIfUsed() async {
        guard CaptureQueue.shared.hasFile else { return }
        await EmailIngestNotifications.requestAuthorizationIfNeeded()
    }
}
