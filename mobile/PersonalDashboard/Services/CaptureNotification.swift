import Foundation
import UserNotifications

/// Posts a tappable confirmation notification after the side-button capture
/// flow lands. Tapping the banner deeplinks into the app via a
/// `personaldashboard://` URL stored in the notification's `userInfo`.
///
/// Issue #13: the App Intent's own `ProvidesDialog` is read-only — a separate
/// notification carries the navigation intent and persists in Notification
/// Center until the user dismisses it.
enum CaptureNotification {
    /// Key under which the deeplink URL is stored in `UNNotificationContent.userInfo`.
    /// `CaptureNotificationDelegate` reads this on tap and routes via `AppRouter`.
    static let deeplinkKey = "personaldashboard.deeplink"

    /// Schedule a confirmation notification for an executed capture.
    ///
    /// - Parameter title: notification title (e.g. "Captured to Dashboard").
    /// - Parameter body: human-readable description of what was applied.
    /// - Parameter deeplink: target URL for the tap action; nil suppresses
    ///   navigation (still posts the notification but tapping just opens the
    ///   app at its last screen).
    static func schedule(title: String, body: String, deeplink: URL?) async {
        let granted = await ensureAuthorization()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.interruptionLevel = .active
        if let deeplink {
            content.userInfo[deeplinkKey] = deeplink.absoluteString
        }

        // Identifier is unique-per-call so two rapid captures don't replace each
        // other in Notification Center.
        let identifier = "capture.\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            // nil trigger fires immediately. The App Intent is already async,
            // so we want the banner to land as the dialog is dismissed.
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Best-effort. Failing to post a confirmation notification is not
            // recoverable from inside the App Intent and should not abort the
            // capture flow that already succeeded.
        }
    }

    /// Build a deeplink URL for the most-relevant action in a capture batch.
    ///
    /// Single executed action -> deeplink to its section + UUID.
    /// Multiple actions of the same section -> deeplink to that section, no UUID.
    /// Mixed sections -> nil (caller posts the notification without a target;
    /// tapping just opens the app).
    static func deeplink(for executed: [ExecutedDraft]) -> URL? {
        guard !executed.isEmpty else { return nil }

        if executed.count == 1 {
            let only = executed[0]
            return url(for: only.type, id: only.id)
        }

        let sections = Set(executed.map(sectionHost(for:)))
        guard sections.count == 1, let host = sections.first, !host.isEmpty else { return nil }
        return url(host: host, id: nil)
    }

    private static func url(for entityType: String, id: String?) -> URL? {
        let host = sectionHost(for: ExecutedDraft.placeholder(type: entityType))
        guard !host.isEmpty else { return nil }
        return url(host: host, id: id)
    }

    private static func url(host: String, id: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "personaldashboard"
        components.host = host
        if let id, !id.isEmpty {
            components.path = "/\(id)"
        }
        return components.url
    }

    private static func sectionHost(for draft: ExecutedDraft) -> String {
        switch draft.type {
        case "todo":   return "tasks"
        case "note":   return "notes"
        case "list":   return "lists"
        case "folder": return "notes" // folder lives under the Notes surface
        default:       return ""
        }
    }

    private static func ensureAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
            return granted
        @unknown default:
            return false
        }
    }
}

private extension ExecutedDraft {
    /// Build a placeholder solely so `sectionHost(for:)` can be reused with a
    /// type string and no real outcome. Avoids exposing the section-mapping
    /// switch as a public surface.
    static func placeholder(type: String) -> ExecutedDraft {
        ExecutedDraft(type: type, action: "", id: "", title: nil, dueDate: nil, addedNames: nil)
    }
}
