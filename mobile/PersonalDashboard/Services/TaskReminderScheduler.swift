import Foundation
import SwiftData
import UserNotifications

/// Local notifications for tasks whose "Remind me" is armed (#444).
///
/// ## Why this is a reconciler and not a set of arm/disarm calls
///
/// A task's due date and completion state are written from a lot of places: the
/// editor, the inline rename row, the calendar popover, the AI's `add_todo` /
/// `update_todo` / `delete_todo` tools, an archive restore and a sync pass that
/// applies a peer's edit. Hanging an `arm()` and a `disarm()` off each of those
/// would mean every future write site has to remember to call them, and the
/// failure when one forgets is silent and delayed: a banner for a task you
/// finished last week.
///
/// So nothing arms anything. `reconcile()` reads the store, works out the set of
/// reminders that *should* be pending, diffs that against what the OS is actually
/// holding, and fixes the difference. It is idempotent and cheap, so it can be
/// called liberally: after every write through `TodoService`, at launch, on
/// return-to-foreground, and whenever `localStoreDidChange` says something wrote
/// to the store behind our back.
///
/// ## Delivery
///
/// A `UNCalendarNotificationTrigger` hands the fire date to the OS, which
/// delivers it whether or not Dexter is running on that device — that is the
/// whole point, and it is why nothing here polls. It is a notification and not an
/// alarm: default sound, default interruption level, so Focus and Do Not Disturb
/// treat it like any other banner.
///
/// The reminder moment IS the due moment. There is deliberately no separate
/// reminder time and no lead time.
@MainActor
enum TaskReminderScheduler {

    /// Prefix on every identifier this type owns, so a reconcile can find and
    /// prune its own pending requests without touching the recurring-expense or
    /// email-ingest notifications sharing the same center.
    static let identifierPrefix = "task-reminder."

    /// Task `clientUUID` on the delivered notification, for a future tap handler
    /// that wants to open the task itself.
    static let todoUUIDKey = "todoClientUUID"

    /// How many reminders to keep armed with the OS.
    ///
    /// iOS allows 64 pending local notifications per app and silently drops the
    /// rest, and this app is not the only thing scheduling them. Staying well
    /// under the cap means the ones nearest in time are always the ones armed;
    /// each launch and foreground tops the list up as earlier ones fire. Anyone
    /// with more than 50 future reminders armed at once loses only the furthest
    /// away, which will have been topped up long before it comes due.
    static let maxPending = 50

    static func identifier(for uuid: UUID) -> String {
        identifierPrefix + uuid.uuidString
    }

    // MARK: - Authorization

    /// Ask for notification permission, but only if the user has never been asked.
    ///
    /// Called when a reminder is armed for the first time rather than at launch,
    /// so someone who never uses reminders is never prompted. Returns whether we
    /// can actually post, so the editor can say so instead of pretending.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                SyncLog.line("TaskReminders: authorization requested -> granted=\(granted)")
                // The grant is the thing that unblocks scheduling, and it arrives
                // AFTER the save that armed the reminder has already reconciled
                // against a `notDetermined` permission and scheduled nothing. So
                // reconcile again here, or the first reminder a person ever sets is
                // silently never armed.
                if granted { await reconcile() }
                return granted
            } catch {
                SyncLog.line("TaskReminders: authorization request FAILED: \(error)")
                return false
            }
        }
        SyncLog.line("TaskReminders: authorization already decided -> \(describe(status))")
        return status == .authorized || status == .provisional
    }

    /// Seconds-precision stamp for the log, because the seconds are the point.
    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Store observation

    /// Reconcile whenever something writes to the store outside `TodoService`.
    ///
    /// This is what covers the AI tools, a sync pass applying a peer's edit, and
    /// an archive restore: all of them post `localStoreDidChange`, none of them go
    /// through `TodoService`. Idempotent, so calling it once per launch per
    /// process is enough and a second call is harmless.
    static func startObservingStoreChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .localStoreDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await reconcile() }
        }
    }

    private static var observer: NSObjectProtocol?

    // MARK: - Reconcile

    /// Make the OS's pending task reminders match the store.
    static func reconcile(store: SwiftDataStore = .shared) async {
        let center = UNUserNotificationCenter.current()

        // Only ours. Another feature's pending notification is not this
        // reconcile's business, and removing one would break it.
        let ours = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }

        // No permission means nothing we schedule would ever arrive, so drop what
        // we are holding rather than leave stale requests parked in the OS against
        // a permission that may be granted much later.
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            SyncLog.line("TaskReminders: reconcile skipped, authorization=\(describe(status)) (dropped \(ours.count) pending)")
            if !ours.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ours.map(\.identifier))
            }
            return
        }

        let desired = self.desired(store: store)
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })

        // Prune: armed with the OS but no longer deserved (completed, deleted,
        // toggled off, due date cleared, now in the past, or pushed past the cap).
        //
        // PENDING only. A reminder that has already been delivered is left alone on
        // the lock screen and in Notification Center until the person swipes it —
        // completing the task afterwards must not make the banner they have not read
        // yet disappear from under them.
        let stale = ours.filter { desiredByID[$0.identifier] == nil }.map(\.identifier)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        // Add or refresh. A pending request that already says the same thing at the
        // same moment is left alone, so a reconcile on an unchanged store does no
        // work at all and never re-triggers anything.
        let existingByID = Dictionary(uniqueKeysWithValues: ours.map { ($0.identifier, $0) })
        var added = 0
        for reminder in desired {
            if let existing = existingByID[reminder.identifier], reminder.matches(existing) {
                continue
            }
            do {
                try await center.add(reminder.request())
                added += 1
                // The exact instant, seconds included. The whole class of bug here
                // is "fired, but not when I asked", which a count cannot show.
                SyncLog.line("TaskReminders: armed \(reminder.title) for \(Self.logStamp.string(from: reminder.fireDate))")
            } catch {
                // Swallowing this is how a reminder goes missing with nothing to
                // show for it, which is the one failure mode this feature cannot
                // afford to be quiet about.
                SyncLog.line("TaskReminders: add FAILED for \(reminder.identifier) at \(reminder.fireDate): \(error)")
            }
        }
        SyncLog.line("TaskReminders: reconcile ok, desired=\(desired.count) added=\(added) pruned=\(stale.count) authorization=\(describe(status))")
    }

    /// Cancel everything this type owns, delivered banners included. Used by the
    /// reset-data path.
    ///
    /// This is the ONE place that touches delivered notifications. Reconcile never
    /// does, deliberately: a reminder that has already arrived belongs to the person,
    /// stays on the lock screen and in Notification Center, and goes away when they
    /// swipe it and not before. Wiping the tasks is the exception, because a banner
    /// for a task that no longer exists is nothing but noise.
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()

        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
        if !pending.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
        }

        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        if !delivered.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }

    // MARK: - What should be armed

    /// The reminders the store says should be pending, soonest first.
    ///
    /// Filtering happens in Swift rather than in the `#Predicate`: the task table
    /// is small enough that one fetch plus a filter is trivial, and expressing
    /// "due in the future" against an optional `Date` in a predicate buys nothing
    /// but a way to get it subtly wrong.
    /// The instant a reminder for `dueDate` actually fires: the START of the minute
    /// the person chose.
    ///
    /// The date picker only exposes hours and minutes, but the `Date` behind it
    /// keeps whatever seconds it was seeded with — `Date().addingTimeInterval(3600)`
    /// for a new task, or the stored value for an existing one. So a reminder set
    /// for 4:28 PM was firing at 4:28:44, which reads as the reminder being up to a
    /// minute late for no visible reason.
    ///
    /// The editor now stores minute-precision due dates, so for anything written
    /// since #444 this is the identity. It stays because it is the safety net for
    /// the rows that already carry stray seconds and for dates the AI supplies from
    /// an ISO string with its own seconds in it — neither of which the editor's
    /// normalisation reaches.
    static func fireDate(for dueDate: Date) -> Date {
        WallClock.minutePrecision(dueDate)
    }

    /// Whether one task earns a pending reminder.
    ///
    /// Split out and `internal` so the rule is unit-testable without a store: it is
    /// the whole feature in five clauses, and each of them is a way to get a banner
    /// for a task that should not produce one.
    static func shouldArm(
        remindMe: Bool,
        completed: Bool,
        deletedAt: Date?,
        dueDate: Date?,
        now: Date
    ) -> Bool {
        guard remindMe else { return false }
        guard !completed else { return false }
        guard deletedAt == nil else { return false }
        guard let dueDate else { return false }
        // Compared against the moment it would actually fire, not the raw due date.
        // Gating on the raw value would let a task whose truncated minute has just
        // passed count as armed, and then nothing would ever be delivered for it.
        return fireDate(for: dueDate) > now
    }

    private static func desired(store: SwiftDataStore) -> [Reminder] {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let rows = (try? store.context.fetch(descriptor)) ?? []
        let now = Date()

        return rows
            .compactMap { row -> Reminder? in
                guard shouldArm(
                    remindMe: row.remindMe,
                    completed: row.completed,
                    deletedAt: row.deletedAt,
                    dueDate: row.dueDate,
                    now: now
                ), let due = row.dueDate else { return nil }
                return Reminder(
                    todoUUID: row.clientUUID,
                    fireDate: fireDate(for: due),
                    title: row.title,
                    notes: row.todoDescription
                )
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(maxPending)
            .map { $0 }
    }

    // MARK: - Reminder

    /// One task's reminder, and how it turns into a notification request.
    ///
    /// `@MainActor` because a nested type does not inherit its enclosing type's
    /// isolation, and this one reads the outer statics.
    @MainActor
    private struct Reminder {
        let todoUUID: UUID
        let fireDate: Date
        let title: String
        let notes: String?

        var identifier: String { TaskReminderScheduler.identifier(for: todoUUID) }

        /// What the banner says. The title carries the task, so the body is for
        /// what the title cannot hold: the notes if there are any, otherwise the
        /// time it was due, which is the next most useful thing and stops the
        /// banner from being a bare line of text.
        var body: String {
            let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
            return "Due \(fireDate.formatted(date: .omitted, time: .shortened))"
        }

        func request() -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            // A task saved with no typed title falls back to a placeholder name,
            // so this is belt-and-braces against an empty banner headline.
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            content.title = trimmedTitle.isEmpty ? "Task reminder" : trimmedTitle
            content.body = body
            content.sound = .default
            content.userInfo = [TaskReminderScheduler.todoUUIDKey: todoUUID.uuidString]

            // Wall-clock components, not a time interval: the OS then fires at the
            // moment shown on the task even if the device sleeps, reboots, or the
            // app never runs again between now and then.
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

            return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        }

        /// Whether an already-pending request says the same thing at the same
        /// moment, and can therefore be left alone.
        func matches(_ existing: UNNotificationRequest) -> Bool {
            guard let trigger = existing.trigger as? UNCalendarNotificationTrigger,
                  let existingDate = trigger.nextTriggerDate() else { return false }
            // Second granularity: the components the trigger was built from carry
            // no sub-second part, so comparing raw `Date`s would never match.
            let sameMoment = abs(existingDate.timeIntervalSince(fireDate)) < 1
            return sameMoment
                && existing.content.title == (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Task reminder" : title.trimmingCharacters(in: .whitespacesAndNewlines))
                && existing.content.body == body
        }
    }
}
