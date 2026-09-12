import Foundation
import SwiftData

/// Errors thrown by `RecurringTaskService` CRUD. Shaped after
/// `RecurringExpenseServiceError` so the editor has useful messages to show.
enum RecurringTaskServiceError: LocalizedError {
    case emptyTitle
    case invalidInterval
    case invalidDayOfMonth
    case noWeekdaysSelected
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:           return "Give the task a title."
        case .invalidInterval:      return "Repeat every 1 or more."
        case .invalidDayOfMonth:    return "Day of month must be between 1 and 31."
        case .noWeekdaysSelected:   return "Pick at least one day of the week."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD over `RecurringTask` plus the materialiser that turns a template into a
/// real `LocalTodo` as each date comes into range (#524).
///
/// ### One occurrence at a time
///
/// A template creates nothing while it already has an open occurrence. That single
/// rule is what separates this from `RecurringExpenseService` (#236), which posts
/// every month it walks past: a daily chore would otherwise stack seven rows deep
/// in the list, and a template left alone over a holiday would come back to a
/// column of identical overdue tasks.
///
/// ### Missed dates are not resurrected
///
/// The cursor advances past any date already behind today without creating
/// anything. Last Tuesday's bins do not need taking now. An occurrence that WAS
/// created and left undone is a different thing: it is a real task, it stays open,
/// it shows in Overdue, and it holds the next one back until it is dealt with.
///
/// ### Two idempotency guards
///
/// The per-date `occurrenceKey` on the generated task, and the template's cursor.
/// The key is checked against soft-deleted rows too, so deleting an occurrence
/// means "skip this date", not "make it again on the next pass".
@MainActor
struct RecurringTaskService {
    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    static func `default`() -> RecurringTaskService {
        RecurringTaskService(store: .shared)
    }

    // MARK: - Reads

    /// All templates, newest first. The management list groups active and paused
    /// itself, so one created-desc sort is enough here.
    func templates() throws -> [RecurringTask] {
        try store.context.fetch(
            FetchDescriptor<RecurringTask>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
    }

    func template(uuid: String) -> RecurringTask? {
        let key = uuid.lowercased()
        return try? store.context.fetch(
            FetchDescriptor<RecurringTask>(predicate: #Predicate { $0.clientUUID == key })
        ).first
    }

    /// The next day this template will create a task for, or nil when it is
    /// exhausted. Shown on the management row so a rule can be checked without
    /// waiting for it to fire.
    func nextDate(for template: RecurringTask, reference: Date = Date()) -> Date? {
        let rule = RecurrenceRule(template: template)
        let cursor = template.lastOccurrenceKey.flatMap { RecurrenceRule.day(fromKey: $0) }
        guard var day = rule.nextDay(after: cursor) else { return nil }
        // Skip anything already behind today, exactly as the materialiser does, so
        // the row cannot advertise a date that will never be created.
        let today = Calendar.current.startOfDay(for: reference)
        while day < today {
            guard let next = rule.nextDay(after: day) else { return nil }
            day = next
        }
        return rule.dueDate(on: day)
    }

    // MARK: - CRUD

    @discardableResult
    func create(
        title: String,
        taskDescription: String? = nil,
        tag: String? = nil,
        priority: Int = 0,
        address: String = "",
        googleMapsLink: String = "",
        remindMe: Bool = false,
        frequency: RecurrenceFrequency,
        interval: Int = 1,
        weekdayMask: Int = 0,
        dayOfMonth: Int = 1,
        monthOfYear: Int = 1,
        timeOfDayMinutes: Int = 9 * 60,
        leadDays: Int = 3,
        isActive: Bool = true,
        startDate: Date = Date(),
        endDate: Date? = nil,
        clientUUID: String? = nil
    ) throws -> RecurringTask {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw RecurringTaskServiceError.emptyTitle }
        try validate(frequency: frequency, interval: interval, weekdayMask: weekdayMask, dayOfMonth: dayOfMonth)

        let now = Date()
        let row = RecurringTask(
            clientUUID: clientUUID?.lowercased() ?? UUID().uuidString.lowercased(),
            title: cleanTitle,
            taskDescription: taskDescription?.trimmedNonEmpty,
            tag: tag?.trimmedNonEmpty,
            priority: priority,
            address: address,
            googleMapsLink: googleMapsLink,
            remindMe: remindMe,
            frequency: frequency.rawValue,
            interval: max(1, interval),
            weekdayMask: weekdayMask,
            dayOfMonth: min(max(dayOfMonth, 1), 31),
            monthOfYear: min(max(monthOfYear, 1), 12),
            timeOfDayMinutes: timeOfDayMinutes,
            leadDays: max(0, leadDays),
            isActive: isActive,
            // Day fields are UTC-midnight anchors, never a device `startOfDay`
            // (#506): they name a calendar day, so storing them as an instant makes
            // the day they report move with the device timezone.
            startDate: WallClock.dayAnchor(from: startDate),
            endDate: endDate.map { WallClock.dayAnchor(from: $0) },
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try save()
        return row
    }

    /// Update in place. Every field optional: nil leaves it untouched.
    ///
    /// Edits only ever affect what the template makes NEXT. Tasks it already
    /// created are ordinary tasks and are never revisited, which is the same
    /// contract a recurring expense has with its posted rows (#236).
    func update(
        _ template: RecurringTask,
        title: String? = nil,
        taskDescription: String? = nil,
        tag: String? = nil,
        priority: Int? = nil,
        address: String? = nil,
        googleMapsLink: String? = nil,
        remindMe: Bool? = nil,
        frequency: RecurrenceFrequency? = nil,
        interval: Int? = nil,
        weekdayMask: Int? = nil,
        dayOfMonth: Int? = nil,
        monthOfYear: Int? = nil,
        timeOfDayMinutes: Int? = nil,
        leadDays: Int? = nil,
        isActive: Bool? = nil,
        startDate: Date? = nil,
        endDate: Date?? = nil
    ) throws {
        if let title {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw RecurringTaskServiceError.emptyTitle }
            template.title = clean
        }
        // "" clears, nil leaves alone — the convention the task rows already use (#488).
        if let taskDescription { template.taskDescription = taskDescription.trimmedNonEmpty }
        if let tag { template.tag = tag.trimmedNonEmpty }
        if let priority { template.priority = priority }
        if let address { template.address = address }
        if let googleMapsLink { template.googleMapsLink = googleMapsLink }
        if let remindMe { template.remindMe = remindMe }

        // The rule is validated as a WHOLE, against the values that will be stored:
        // a frequency changed to weekly and a weekday mask set in the same edit are
        // only valid together, so neither can be checked on its own.
        let newFrequency = frequency ?? template.frequencyEnum
        let newInterval = interval ?? template.interval
        let newMask = weekdayMask ?? template.weekdayMask
        let newDayOfMonth = dayOfMonth ?? template.dayOfMonth
        try validate(frequency: newFrequency, interval: newInterval, weekdayMask: newMask, dayOfMonth: newDayOfMonth)

        template.frequency = newFrequency.rawValue
        template.interval = max(1, newInterval)
        template.weekdayMask = newMask
        template.dayOfMonth = min(max(newDayOfMonth, 1), 31)
        if let monthOfYear { template.monthOfYear = min(max(monthOfYear, 1), 12) }
        if let timeOfDayMinutes { template.timeOfDayMinutes = timeOfDayMinutes }
        if let leadDays { template.leadDays = max(0, leadDays) }
        if let isActive { template.isActive = isActive }
        if let startDate { template.startDate = WallClock.dayAnchor(from: startDate) }
        // Double-optional: outer nil = no change, `.some(nil)` = clear the end date.
        if let endDate {
            template.endDate = endDate.map { WallClock.dayAnchor(from: $0) }
        }
        template.updatedAt = Date()
        try save()
    }

    /// Pause or resume. A paused template creates nothing until it is resumed, and
    /// resuming picks up from the next future date rather than from history,
    /// because the cursor skips past everything already gone.
    func setActive(_ template: RecurringTask, _ active: Bool) throws {
        template.isActive = active
        template.updatedAt = Date()
        try save()
    }

    /// Delete the template. Tasks it already created are left alone: they are
    /// ordinary `LocalTodo` rows now, and one of them may well be open in front of
    /// the user.
    func delete(_ template: RecurringTask) throws {
        store.context.delete(template)
        try save()
    }

    private func validate(frequency: RecurrenceFrequency, interval: Int, weekdayMask: Int, dayOfMonth: Int) throws {
        guard interval >= 1 else { throw RecurringTaskServiceError.invalidInterval }
        guard (1...31).contains(dayOfMonth) else { throw RecurringTaskServiceError.invalidDayOfMonth }
        // A weekly rule with no day selected falls back to the start date's weekday
        // in `RecurrenceRule`, so this is about the editor never SAVING an empty
        // picker, not about the rule being unable to cope with one.
        if frequency == .weekly, weekdayMask == 0 {
            throw RecurringTaskServiceError.noWeekdaysSelected
        }
    }

    // MARK: - Materialisation

    /// One task created this pass, for the caller that wants to say so.
    struct Created {
        let title: String
        let dueDate: Date
    }

    /// Create the due occurrence for every active template, up to `reference`.
    /// Returns what was created, which is empty on most passes.
    @discardableResult
    func materialize(reference: Date = Date()) -> [Created] {
        let all = (try? templates()) ?? []
        var created: [Created] = []
        for template in all where template.isActive {
            if let row = materializeTemplate(template, reference: reference) {
                created.append(row)
            }
        }
        return created
    }

    /// Bring one template up to date. At most one task comes out of this.
    private func materializeTemplate(_ template: RecurringTask, reference: Date) -> Created? {
        // Already has something open? Then there is nothing to do, whatever the
        // calendar says. This is the "one at a time" rule, and it is checked before
        // any date arithmetic so the common pass is one count query.
        guard !hasOpenOccurrence(template) else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        let rule = RecurrenceRule(template: template, calendar: calendar)

        var cursor = template.lastOccurrenceKey.flatMap { RecurrenceRule.day(fromKey: $0, calendar: calendar) }
        var advancedCursor: String? = nil

        // Bounded walk. Each turn either skips a date already gone (cheap, no row)
        // or decides. The bound only matters for a template whose start date is far
        // in the past, and it resumes from the advanced cursor next pass.
        for _ in 0..<512 {
            guard let day = rule.nextDay(after: cursor) else { break }

            if day < today {
                // Already gone. Advance past it without creating anything: last
                // Tuesday's chore is not today's problem.
                cursor = day
                advancedCursor = RecurrenceRule.dayKey(day, calendar: calendar)
                continue
            }

            // Not yet in range. Leave the cursor where it is so this same date is
            // reconsidered on a later pass, once its lead window opens.
            let appearsOn = calendar.date(byAdding: .day, value: -template.leadDays, to: day) ?? day
            if today < calendar.startOfDay(for: appearsOn) { break }

            let key = Self.occurrenceKey(templateUUID: template.clientUUID, day: day, calendar: calendar)
            if occurrenceExists(key: key) {
                // This date was created before and has since been completed or
                // deleted. Either way it is dealt with, so move past it.
                cursor = day
                advancedCursor = RecurrenceRule.dayKey(day, calendar: calendar)
                continue
            }

            guard let row = insertOccurrence(template: template, day: day, rule: rule, key: key) else { break }
            advancedCursor = RecurrenceRule.dayKey(day, calendar: calendar)
            commitCursor(template, advancedCursor)
            return Created(title: row.title, dueDate: row.dueDate ?? rule.dueDate(on: day))
        }

        commitCursor(template, advancedCursor)
        return nil
    }

    /// Whether this template has a task that is still open: not completed, not
    /// deleted. A completed one is history and does not hold anything back.
    private func hasOpenOccurrence(_ template: RecurringTask) -> Bool {
        let uuid = template.clientUUID
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate {
                $0.recurringTaskUUID == uuid && $0.completed == false && $0.deletedAt == nil
            }
        )
        return ((try? store.context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Whether this exact date was ever created, INCLUDING as a row since
    /// soft-deleted. That inclusion is the point: deleting one occurrence has to
    /// mean "skip this date", or the next pass would put it straight back.
    private func occurrenceExists(key: String) -> Bool {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.occurrenceKey == key }
        )
        return ((try? store.context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Copy the template onto a real task for one date.
    ///
    /// Written straight into the context rather than through `TodoService.create`,
    /// because that one is `async` and this walk is not; the reminder reconcile it
    /// would have run is done once by the caller instead, after the whole pass.
    private func insertOccurrence(template: RecurringTask, day: Date, rule: RecurrenceRule, key: String) -> LocalTodo? {
        let now = Date()
        let row = LocalTodo(
            title: template.title,
            todoDescription: template.taskDescription,
            completed: false,
            dueDate: rule.dueDate(on: day),
            tag: template.tag,
            address: template.address,
            googleMapsLink: template.googleMapsLink,
            priority: template.priority,
            remindMe: template.remindMe,
            recurringTaskUUID: template.clientUUID,
            occurrenceKey: key,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        do {
            try store.context.save()
        } catch {
            store.context.delete(row)
            return nil
        }
        return row
    }

    private func commitCursor(_ template: RecurringTask, _ key: String?) {
        guard let key, key != template.lastOccurrenceKey else { return }
        template.lastOccurrenceKey = key
        // `updatedAt` is deliberately NOT moved: the cursor is bookkeeping, and a
        // pass on one device must not win last-writer-wins against a real edit made
        // on the other.
        try? save()
    }

    // MARK: - Keys

    /// Stable per-date key for one occurrence, mirroring the recurring expense's
    /// `recurring:<uuid>:<yyyy-MM>` (#236) one field deeper.
    static func occurrenceKey(templateUUID: String, day: Date, calendar: Calendar = .current) -> String {
        "recurring:\(templateUUID.lowercased()):\(RecurrenceRule.dayKey(day, calendar: calendar))"
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw RecurringTaskServiceError.persistence(error)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
