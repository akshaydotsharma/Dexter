import Foundation
import UserNotifications

/// Local-notification surface for the email-to-itinerary ingestion (#143).
///
/// Two notification shapes:
///  - "added": summarises what was added to which trip, and carries an Undo
///    action button plus the ingest-log UUID so the handler can delete the
///    exact items that were added.
///  - "skipped": tells the user an email didn't match any trip.
///
/// The app has no prior notification infrastructure, so this also owns
/// authorization and the notification-category registration. The actual undo
/// (deleting the added items) is performed by `EmailIngestService` when it
/// receives the action; this type only builds and posts requests and exposes
/// the identifiers the delegate routes on.
enum EmailIngestNotifications {

    static let addedCategoryId = "EMAIL_INGEST_ADDED"
    static let skippedCategoryId = "EMAIL_INGEST_SKIPPED"
    static let undoActionId = "EMAIL_INGEST_UNDO"

    /// Key in the notification userInfo carrying the `LocalEmailIngestLog`
    /// clientUUID string the undo action targets.
    static let logUUIDKey = "ingestLogUUID"

    /// Register categories (the Undo button lives on the "added" category).
    /// Safe to call repeatedly; idempotent on the system side.
    static func registerCategories() {
        let undo = UNNotificationAction(
            identifier: undoActionId,
            title: "Undo",
            options: [.destructive]
        )
        let added = UNNotificationCategory(
            identifier: addedCategoryId,
            actions: [undo],
            intentIdentifiers: [],
            options: []
        )
        let skipped = UNNotificationCategory(
            identifier: skippedCategoryId,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([added, skipped])
    }

    /// Request authorization. Quiet no-op if already decided.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Post the "items added / updated" notification with an Undo action.
    ///
    /// `updatedCount` (#165) covers rows the explicit Re-scan reconciled in
    /// place. The automatic cycle never updates, so it always passes 0 and the
    /// body reads exactly as before. Undo still only removes the ADDED items;
    /// updated items are left in place.
    static func postAdded(tripName: String, itemCount: Int, updatedCount: Int = 0, logUUID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = itemCount > 0 ? "Added to \(tripName)" : "Updated \(tripName)"
        content.body = Self.addedBody(added: itemCount, updated: updatedCount)
        content.sound = .default
        content.categoryIdentifier = addedCategoryId
        content.userInfo = [logUUIDKey: logUUID.uuidString.lowercased()]
        await post(content)
    }

    /// Build the notification body for an added/updated outcome. Mentions only
    /// non-zero counts so an updates-only Re-scan never reads "0 items added".
    private static func addedBody(added: Int, updated: Int) -> String {
        var parts: [String] = []
        if added > 0 {
            parts.append(added == 1 ? "1 item added" : "\(added) items added")
        }
        if updated > 0 {
            parts.append(updated == 1 ? "1 item updated" : "\(updated) items updated")
        }
        if parts.isEmpty { parts.append("nothing changed") }
        return parts.joined(separator: ", ") + " from a forwarded email."
    }

    /// Post the "skipped, no matching trip" notification.
    static func postSkipped(subject: String) async {
        let content = UNMutableNotificationContent()
        content.title = "No matching trip"
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = trimmed.isEmpty
            ? "A forwarded email didn't match any trip, so nothing was added."
            : "\"\(String(trimmed.prefix(80)))\" didn't match any trip, so nothing was added."
        content.sound = nil
        content.categoryIdentifier = skippedCategoryId
        await post(content)
    }

    /// Confirm an undo completed.
    static func postUndone(tripName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Undone"
        content.body = "Removed the items that were added to \(tripName)."
        content.sound = nil
        await post(content)
    }

    private static func post(_ content: UNNotificationContent) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        try? await center.add(request)
    }
}
