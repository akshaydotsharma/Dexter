import Foundation
import BackgroundTasks
import UserNotifications
import UIKit

/// App-level glue for the email-to-itinerary ingestion (#143):
///  - Registers and schedules the BGAppRefreshTask for opportunistic
///    background fetch.
///  - Triggers a foreground fetch on launch and on return-to-foreground.
///  - Acts as the UNUserNotificationCenter delegate so the Undo action on the
///    "added" notification deletes the items that were added.
///
/// Background fetch is best-effort — iOS decides when (or whether) to run the
/// refresh task. The foreground triggers are the reliable path.
final class EmailIngestCoordinator: NSObject, UNUserNotificationCenterDelegate {

    static let shared = EmailIngestCoordinator()

    /// Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist.
    static let refreshTaskId = "com.akshaysharma.personaldashboard.emailIngestRefresh"

    private var isRunning = false

    private override init() { super.init() }

    // MARK: - Launch wiring

    /// Call once early in app launch (AppDelegate.didFinishLaunching). Must run
    /// before the app finishes launching for the BGTask registration to take.
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
        UNUserNotificationCenter.current().delegate = self
        EmailIngestNotifications.registerCategories()
    }

    /// Foreground entry point — launch and return-to-foreground both call
    /// this. Requests notification authorization on first ready run, then runs
    /// one fetch cycle and (re)schedules the background task.
    @MainActor
    func runForegroundFetch() async {
        guard EmailInboxConfig.isReady else { return }
        await EmailIngestNotifications.requestAuthorizationIfNeeded()
        await runCycle()
        scheduleBackgroundRefresh()
    }

    // MARK: - Background task

    func scheduleBackgroundRefresh() {
        guard EmailInboxConfig.isReady else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        // Earliest 30 min out; iOS coalesces and decides the real time.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("EmailIngestCoordinator: couldn't schedule refresh: %@", error.localizedDescription)
        }
    }

    private func handleRefreshTask(_ task: BGAppRefreshTask) {
        // Always schedule the next one so the chain continues.
        scheduleBackgroundRefresh()

        let work = Task { @MainActor in
            await runCycle()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    @MainActor
    private func runCycle() async {
        // Avoid overlapping cycles (launch + foreground can race).
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        _ = await EmailIngestService().runFetchCycle()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle the Undo action on an "added" notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == EmailIngestNotifications.undoActionId else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[EmailIngestNotifications.logUUIDKey] as? String,
              let logUUID = UUID(uuidString: raw) else {
            return
        }
        Task { @MainActor in
            if let tripName = EmailIngestService().undo(logUUID: logUUID) {
                await EmailIngestNotifications.postUndone(tripName: tripName)
            }
        }
    }
}

/// Minimal AppDelegate that exists solely to register the background task and
/// notification delegate at the right moment in the launch sequence. The app
/// otherwise stays pure SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        EmailIngestCoordinator.shared.registerBackgroundTask()
        return true
    }
}
