import Foundation
import UserNotifications

/// Local-notification surface for recurring-expense materialisation (#236).
///
/// One shape: a summary posted when one or more recurring expenses land in a
/// materialisation pass (e.g. "2 recurring expenses added" / "Rent, Netflix").
/// No actions — the rows are ordinary editable expenses, so there's nothing to
/// undo from the banner.
///
/// The app's single `UNUserNotificationCenter` delegate is owned by
/// `EmailIngestCoordinator` (set at launch), and its `willPresent` returns a
/// banner while foregrounded — so this notification presents correctly without
/// registering a second delegate. Authorization is requested lazily, only when
/// there's actually something to show.
enum RecurringExpenseNotifications {

    /// Request authorization if the user hasn't decided yet. Quiet no-op
    /// otherwise. Called just before the first post that carries rows, so a
    /// user who never uses recurring expenses is never prompted.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Post one summary notification for the rows that materialised. Requests
    /// authorization first (lazily). If authorization is denied the expenses
    /// still posted — only the banner is skipped.
    static func postPosted(_ rows: [RecurringExpenseService.Posted]) async {
        guard !rows.isEmpty else { return }
        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        let count = rows.count
        content.title = count == 1
            ? "Recurring expense added"
            : "\(count) recurring expenses added"

        // List the merchants/labels, de-duplicated and truncated so a big
        // backfill doesn't produce an unreadable body.
        var seen = Set<String>()
        let names = rows.compactMap { row -> String? in
            let name = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
        content.body = Self.body(names: names)
        content.sound = .default

        await post(content)
    }

    /// "Rent, Netflix" — capped at four names with a "+N more" tail.
    private static func body(names: [String]) -> String {
        guard !names.isEmpty else { return "Added to Finances." }
        let shown = names.prefix(4)
        var line = shown.joined(separator: ", ")
        if names.count > shown.count {
            line += " +\(names.count - shown.count) more"
        }
        return line
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
