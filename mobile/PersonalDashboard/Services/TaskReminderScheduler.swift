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
    nonisolated static let identifierPrefix = "task-reminder."

    /// Task `clientUUID` on the delivered notification, for a future tap handler
    /// that wants to open the task itself.
    nonisolated static let todoUUIDKey = "todoClientUUID"

    /// Category for reminder notifications. Carries `.customDismissAction`, which is
    /// what makes the OS tell us the person swiped the banner away — without it a
    /// dismissal is invisible to the app and `reminderClearedAt` could never be set.
    nonisolated static let categoryIdentifier = "task-reminder"

    /// How late a reminder may arrive on a second device and still be delivered.
    ///
    /// ## Why this is a day and not ten minutes
    ///
    /// It was ten minutes, sized off a single measurement where a reminder reached
    /// the Mac 35 seconds late. That was the wrong model of the latency. iOS only
    /// runs a sync pass while the app is foregrounded or on its way to the
    /// background, so an op can sit on the phone until it is next opened — measured
    /// at **26 minutes** for a reminder due 20:27 that the Mac only saw at 20:53.
    /// Ten minutes did not cover the real world, and the second device stayed silent
    /// for exactly the case this was built for.
    ///
    /// The rule this feature was asked for has no time bound at all: show it unless
    /// it has already been dealt with. A day is the concession to one specific
    /// hazard rather than to that rule — restoring an archive full of long-finished
    /// tasks that happen to be armed and uncleared would otherwise produce a banner
    /// per row. Repeats on the same device are prevented separately, by
    /// `recordLateDelivery`.
    ///
    /// So: anything from today that nobody has dealt with still lands. A device that
    /// has been away for longer than that stays quiet.
    static let lateGrace: TimeInterval = 24 * 60 * 60

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

    /// Whether the OS will honour `.timeSensitive` for this app at all.
    ///
    /// `notSupported` is the entitlement gate showing up at runtime rather than only
    /// at code-sign time — the app has no such permission to be granted. Logged on
    /// every reconcile so the answer is never a matter of reasoning again.
    private static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "notSupported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown(\(setting.rawValue))"
        }
    }

    // MARK: - Category + dismissal

    /// Register the reminder category, preserving whatever else is registered.
    ///
    /// ⚠️ `setNotificationCategories` REPLACES the whole set, it does not add to it.
    /// iOS already registers the email-ingest categories (the Undo button lives on
    /// one of them) from `AppDelegate.didFinishLaunching`, so a naive set here would
    /// silently break Undo. Hence the read-modify-write. It also means this must run
    /// AFTER the email registration, which it does: that one is in the app delegate,
    /// this one in the SwiftUI `.task`.
    static func registerCategory() async {
        let center = UNUserNotificationCenter.current()
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        var merged = await center.notificationCategories()
            .filter { $0.identifier != categoryIdentifier }
        merged.insert(category)
        center.setNotificationCategories(merged)
    }

    /// What a notification response means for us, decided WITHOUT touching the store.
    ///
    /// `nonisolated` because the delegate callbacks it serves are nonisolated, and
    /// because it must answer "was this ours?" synchronously so the iOS delegate can
    /// decide whether to fall through to its email branch. It also reads everything
    /// it needs off the response here, so only a `UUID` crosses to the main actor
    /// rather than the non-Sendable notification object.
    ///
    /// Swiping the banner away and tapping it both count as dealing with it, because
    /// both mean it has been seen. That is what stops the OTHER device delivering the
    /// same reminder late once sync carries the fact across.
    nonisolated static func inspect(
        response: UNNotificationResponse
    ) -> (isOurs: Bool, clearedTask: UUID?) {
        let request = response.notification.request
        guard request.identifier.hasPrefix(identifierPrefix) else { return (false, nil) }

        switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier, UNNotificationDefaultActionIdentifier:
            guard let raw = request.content.userInfo[todoUUIDKey] as? String,
                  let uuid = UUID(uuidString: raw) else { return (true, nil) }
            return (true, uuid)
        default:
            return (true, nil)
        }
    }

    /// Record that this task's reminder has been dealt with, and let the store
    /// change propagate so a sync pass carries it to the other device.
    static func markCleared(todoUUID: UUID, store: SwiftDataStore = .shared) {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.clientUUID == todoUUID }
        )
        guard let row = try? store.context.fetch(descriptor).first else { return }
        guard row.reminderClearedAt == nil else { return }
        row.reminderClearedAt = Date()
        // Bumped so the sync engine treats this as a real edit and ships it. Without
        // it the change would sit on this device and the other one would still fire.
        row.updatedAt = Date()
        try? store.context.save()
        SyncLog.line("TaskReminders: cleared \(row.title)")
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
    }

    // MARK: - Per-device delivery record

    /// Reminders this DEVICE has already delivered late, so it never does it twice.
    ///
    /// Device-local on purpose, and deliberately not the synced `reminderClearedAt`:
    /// that field means "the person dealt with it" and must stay false until they do,
    /// or the other device would skip a reminder nobody has seen. This is the
    /// narrower fact "this device already put this banner up", which is nobody
    /// else's business. Keyed on the fire instant as well as the task, so moving a
    /// due date to a new time arms a genuinely new reminder.
    private static let deliveredKey = "TaskReminders.deliveredLate"

    private static func lateDeliveryKey(_ reminder: Reminder) -> String {
        "\(reminder.todoUUID.uuidString)@\(Int(reminder.fireDate.timeIntervalSince1970))"
    }

    private static func alreadyDeliveredLate(_ reminder: Reminder) -> Bool {
        let stored = UserDefaults.standard.dictionary(forKey: deliveredKey) as? [String: Double] ?? [:]
        return stored[lateDeliveryKey(reminder)] != nil
    }

    private static func recordLateDelivery(_ reminder: Reminder) {
        var stored = UserDefaults.standard.dictionary(forKey: deliveredKey) as? [String: Double] ?? [:]
        stored[lateDeliveryKey(reminder)] = reminder.fireDate.timeIntervalSince1970
        // Prune anything far enough past the grace window that it can never be a
        // candidate again, so this cannot grow without bound.
        let cutoff = Date().addingTimeInterval(-lateGrace * 6).timeIntervalSince1970
        stored = stored.filter { $0.value > cutoff }
        UserDefaults.standard.set(stored, forKey: deliveredKey)
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
        // One read, two facts. `timeSensitiveSetting` rides along on the reconcile
        // summary rather than living in its own call, because a separate diagnostic
        // at the end of the launch sequence never printed: the app can background
        // before it gets there. This line always runs.
        let settings = await center.notificationSettings()
        let status = settings.authorizationStatus
        let timeSensitive = describe(settings.timeSensitiveSetting)
        guard status == .authorized || status == .provisional else {
            SyncLog.line("TaskReminders: reconcile skipped, authorization=\(describe(status)) (dropped \(ours.count) pending)")
            if !ours.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ours.map(\.identifier))
            }
            return
        }

        let (desired, late) = self.desired(store: store)
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
        // Reminders this device is owed: their moment passed while it did not know the
        // task existed, which is the cross-device case (#444). Delivered straight
        // away rather than scheduled, because there is no future instant left to
        // schedule them for.
        var deliveredLate = 0
        for reminder in late where !alreadyDeliveredLate(reminder) {
            do {
                try await center.add(reminder.request(immediate: true))
                recordLateDelivery(reminder)
                deliveredLate += 1
                let behind = Int(Date().timeIntervalSince(reminder.fireDate))
                SyncLog.line("TaskReminders: delivered \(reminder.title) \(behind)s late (was due \(Self.logStamp.string(from: reminder.fireDate)))")
            } catch {
                SyncLog.line("TaskReminders: late delivery FAILED for \(reminder.identifier): \(error)")
            }
        }

        SyncLog.line("TaskReminders: reconcile ok, desired=\(desired.count) added=\(added) pruned=\(stale.count) late=\(deliveredLate) authorization=\(describe(status)) timeSensitive=\(timeSensitive)")
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
        timing(remindMe: remindMe, completed: completed, deletedAt: deletedAt,
               dueDate: dueDate, reminderClearedAt: nil, now: now) == .scheduled
    }

    /// What, if anything, this device should do about one task's reminder.
    enum Timing: Equatable {
        /// Hand it to the OS for its fire date, which is still ahead.
        case scheduled
        /// Its moment has passed, but recently, and nobody has dealt with it — so
        /// deliver it now. This is the cross-device case: the other device fired on
        /// time and this one only just learned the task exists.
        case deliverNow
        /// Nothing to do.
        case none
    }

    static func timing(
        remindMe: Bool,
        completed: Bool,
        deletedAt: Date?,
        dueDate: Date?,
        reminderClearedAt: Date?,
        now: Date
    ) -> Timing {
        guard remindMe else { return .none }
        guard !completed else { return .none }
        guard deletedAt == nil else { return .none }
        guard let dueDate else { return .none }

        // Compared against the moment it would actually fire, not the raw due date.
        // Gating on the raw value would let a task whose truncated minute has just
        // passed count as armed, and then nothing would ever be delivered for it.
        let fire = fireDate(for: dueDate)
        if fire > now { return .scheduled }

        // Already dealt with on some device. The whole reason `reminderClearedAt`
        // syncs: swiping the banner away on the phone is invisible here otherwise,
        // and this device would re-notify for something already seen.
        guard reminderClearedAt == nil else { return .none }

        // Late, but only usefully so. Past the grace window this is history, not a
        // reminder.
        guard now.timeIntervalSince(fire) <= lateGrace else { return .none }
        return .deliverNow
    }

    /// Everything this device should act on, split by whether it is scheduled ahead
    /// or owed right now, soonest first.
    ///
    /// Filtering happens in Swift rather than in the `#Predicate`: the task table is
    /// small enough that one fetch plus a filter is trivial, and expressing "due in
    /// the future" against an optional `Date` in a predicate buys nothing but a way
    /// to get it subtly wrong.
    private static func desired(store: SwiftDataStore) -> (scheduled: [Reminder], late: [Reminder]) {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let rows = (try? store.context.fetch(descriptor)) ?? []
        let now = Date()

        var scheduled: [Reminder] = []
        var late: [Reminder] = []

        for row in rows {
            guard let due = row.dueDate else { continue }
            let reminder = Reminder(
                todoUUID: row.clientUUID,
                fireDate: fireDate(for: due),
                title: row.title,
                notes: row.todoDescription
            )
            switch timing(
                remindMe: row.remindMe,
                completed: row.completed,
                deletedAt: row.deletedAt,
                dueDate: row.dueDate,
                reminderClearedAt: row.reminderClearedAt,
                now: now
            ) {
            case .scheduled: scheduled.append(reminder)
            case .deliverNow: late.append(reminder)
            case .none: continue
            }
        }

        return (
            scheduled: Array(scheduled.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending)),
            // Not capped: these are delivered immediately rather than parked with the
            // OS, so they do not consume the pending budget the cap protects.
            late: late.sorted { $0.fireDate < $1.fireDate }
        )
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

        /// `immediate` delivers now instead of at `fireDate`, for a reminder whose
        /// moment passed before this device heard about the task.
        func request(immediate: Bool = false) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            // A task saved with no typed title falls back to a placeholder name,
            // so this is belt-and-braces against an empty banner headline.
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            content.title = trimmedTitle.isEmpty ? "Task reminder" : trimmedTitle
            content.body = body
            content.sound = .default
            content.userInfo = [TaskReminderScheduler.todoUUIDKey: todoUUID.uuidString]

            // The only ranking knob available to this app (#444).
            //
            // Be clear about what it does NOT do: it has no effect on ordering
            // against OTHER apps' notifications. A Calendar invite still sits above
            // a reminder in Notification Center because Apple's own apps mark theirs
            // Time Sensitive, and that capability is unsignable on free personal-team
            // signing. There is no "always on top" API for anybody.
            //
            // What it does do is rank Dexter's own notifications against each other:
            // a reminder becomes the one that represents the group in a collapsed
            // stack or a Scheduled Summary, rather than an email-ingest or
            // recurring-expense notice winning on recency alone. A reminder is the
            // most consequential thing this app posts, so it takes the top score.
            content.relevanceScore = 1.0

            // Lets the OS report a dismissal back to us, which is what records
            // `reminderClearedAt` and stops the other device delivering it late.
            content.categoryIdentifier = TaskReminderScheduler.categoryIdentifier

            // A nil trigger delivers immediately. Used only for a reminder already
            // past its moment — there is nothing left to schedule.
            guard !immediate else {
                return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            }

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
