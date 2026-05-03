import Foundation
import UserNotifications

/// Bridges `UNUserNotificationCenter` taps into `AppRouter` deeplinks.
///
/// Without this delegate, tapping a capture-confirmation notification would
/// just open the app at its last screen. With it, the userInfo's
/// `CaptureNotification.deeplinkKey` is parsed and `AppRouter.shared.handle`
/// drops the user on the right surface.
final class CaptureNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CaptureNotificationDelegate()

    /// Show capture banners even when the app is in the foreground; otherwise
    /// the user gets the dialog from the App Intent and nothing else, which
    /// makes the deeplink invisible.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Tap handler. Parses the deeplink from userInfo and routes via the
    /// shared `AppRouter`.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        guard let raw = info[CaptureNotification.deeplinkKey] as? String,
              let url = URL(string: raw) else {
            return
        }
        Task { @MainActor in
            AppRouter.shared.handle(url: url)
        }
    }
}
