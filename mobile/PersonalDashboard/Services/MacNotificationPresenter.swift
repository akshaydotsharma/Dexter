#if os(macOS)
import Foundation
import UserNotifications

/// The macOS app's `UNUserNotificationCenter` delegate (#444).
///
/// Without a delegate returning `.banner` from `willPresent`, the system
/// suppresses notifications for whichever app is frontmost — so a task reminder
/// firing while you are looking at Dexter would show nothing at all, which is
/// exactly the moment it looks broken.
///
/// iOS has had this since #143, where `EmailIngestCoordinator` acts as the
/// delegate. That type is iOS-only (it is built on `BackgroundTasks` and
/// `UIApplication`) and is deliberately outside the Mac target's sources, so the
/// Mac had no delegate at all. This is its counterpart, and it also fixes the
/// same latent gap for the recurring-expense banners that already ship here.
final class MacNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = MacNotificationPresenter()

    private override init() { super.init() }

    /// Claim the delegate. Idempotent — the Mac's `.task` runs once per window,
    /// and re-assigning the same object is a no-op.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// `.list` matters as much as `.banner`: it is what puts the notification in
    /// Notification Center so it survives the banner timing out. Without it one that
    /// arrives while Dexter is frontmost is gone the moment the banner fades, with
    /// nothing left to go back to.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
#endif
