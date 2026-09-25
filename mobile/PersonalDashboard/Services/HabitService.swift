import Foundation
import SwiftData

enum HabitServiceError: LocalizedError {
    case emptyName
    case noWeekdaysSelected
    case invalidTarget
    case futureDay
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:          return "Give the habit a name."
        case .noWeekdaysSelected: return "Pick at least one day of the week."
        case .invalidTarget:      return "The daily target must be 1 or more."
        case .futureDay:          return "You can't log a day that hasn't happened yet."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// What the day editor asks for (#661).
enum HabitDaySetting: Equatable {
    /// Mark done: the count becomes the target.
    case done
    /// A count under the target. Clamped to 1...target-1.
    case partial(Int)
    case skipped
    /// Remove whatever was logged. The day reads as missed or pending again.
    case cleared
}

/// CRUD over `LocalHabit` and `LocalHabitCheckIn` (#661).
///
/// ### One check-in per habit per day
///
/// Every write goes through `upsertCheckIn`, which looks the day's row up by its
/// derived id (`HabitCheckInID`) and updates it when it exists, soft-deleted or
/// not. It inserts only when there is no row at all. The unique id is a second
/// line of defence, not the first: SwiftData collapses a same-id insert by
/// REPLACING the row, which would reset `createdAt` (#514).
///
/// ### No future days
///
/// Every check-in write compares the day with today's anchor and throws
/// `.futureDay` when it is later. The grid disables those cells too, but the
/// rule lives here so no caller can get around it.
@MainActor
struct HabitService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> HabitService {
        HabitService(store: .shared)
    }

    // MARK: - Reads

    /// Every live habit (not soft-deleted), in display order.
    func habits(includeArchived: Bool = true) throws -> [LocalHabit] {
        let rows = try store.context.fetch(
            FetchDescriptor<LocalHabit>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]
            )
        )
        return includeArchived ? rows : rows.filter { !$0.isArchived }
    }

    func checkIn(habitUUID: String, day: Date) throws -> LocalHabitCheckIn? {
        let id = HabitCheckInID.make(habitUUID: habitUUID, day: HabitLedger.key(day))
        return try store.context.fetch(
            FetchDescriptor<LocalHabitCheckIn>(predicate: #Predicate { $0.clientUUID == id })
        ).first
    }

    // MARK: - Habit writes

    @discardableResult
    func create(
        name: String,
        emoji: String = "",
        colorKey: String = HabitColor.gold.rawValue,
        schedule: HabitSchedule = .daily,
        weekdayMask: Int = 0b111_1111,
        targetCount: Int = 1,
        unit: String? = nil,
        startDay: Date? = nil,
        now: Date = Date()
    ) throws -> LocalHabit {
        let cleanName = try Self.validatedName(name)
        try Self.validate(schedule: schedule, weekdayMask: weekdayMask, targetCount: targetCount)
        let nextIndex = ((try? habits())?.map(\.sortIndex).max() ?? -1) + 1
        let habit = LocalHabit(
            name: cleanName,
            emoji: Self.cleanedEmoji(emoji),
            colorKey: colorKey,
            schedule: schedule.rawValue,
            weekdayMask: weekdayMask,
            targetCount: targetCount,
            unit: Self.cleanedUnit(unit),
            startDay: HabitLedger.key(startDay ?? HabitLedger.todayAnchor(now: now)),
            sortIndex: nextIndex,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(habit)
        try save()
        return habit
    }

    func update(
        _ habit: LocalHabit,
        name: String,
        emoji: String,
        colorKey: String,
        schedule: HabitSchedule,
        weekdayMask: Int,
        targetCount: Int,
        unit: String?,
        startDay: Date,
        now: Date = Date()
    ) throws {
        let cleanName = try Self.validatedName(name)
        try Self.validate(schedule: schedule, weekdayMask: weekdayMask, targetCount: targetCount)
        habit.name = cleanName
        habit.emoji = Self.cleanedEmoji(emoji)
        habit.colorKey = colorKey
        habit.schedule = schedule.rawValue
        habit.weekdayMask = weekdayMask
        habit.targetCount = targetCount
        habit.unit = Self.cleanedUnit(unit)
        habit.startDay = HabitLedger.key(startDay)
        habit.updatedAt = now
        try save()
    }

    /// Inline rename. Empty or whitespace-only input is a silent revert, not an
    /// error, which is the rule every inline rename in the app follows.
    func rename(_ habit: LocalHabit, to name: String, now: Date = Date()) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != habit.name else { return }
        habit.name = trimmed
        habit.updatedAt = now
        try save()
    }

    func setArchived(_ habit: LocalHabit, _ archived: Bool, now: Date = Date()) throws {
        habit.archivedAt = archived ? now : nil
        habit.updatedAt = now
        try save()
    }

    /// Soft delete. The check-ins stay: they are unreachable without the habit,
    /// and leaving them costs nothing while saving a sweep that sync would have
    /// to carry as a burst of deletes.
    func delete(_ habit: LocalHabit, now: Date = Date()) throws {
        habit.deletedAt = now
        habit.updatedAt = now
        try save()
    }

    // MARK: - Check-in writes

    /// The one-tap action on the Today card.
    ///
    /// A yes/no habit toggles: done becomes cleared, anything else becomes done.
    /// A count habit adds one per tap, and keeps counting past the target.
    func tap(_ habit: LocalHabit, today: Date? = nil, now: Date = Date()) throws {
        let day = HabitLedger.key(today ?? HabitLedger.todayAnchor(now: now))
        let existing = try checkIn(habitUUID: habit.clientUUID, day: day)
        let live = existing?.deletedAt == nil ? existing : nil
        let target = max(1, habit.targetCount)

        if target == 1 {
            let isDone = live.map { $0.statusEnum == .done && $0.count >= 1 } ?? false
            try set(habit, on: day, to: isDone ? .cleared : .done, today: day, now: now)
            return
        }
        let current = (live?.statusEnum == .done) ? (live?.count ?? 0) : 0
        try upsertCheckIn(habit, day: day, count: current + 1, status: .done, today: day, now: now)
    }

    /// The Habits strip and month grid's one-tap action: check or uncheck a
    /// day. A checked day (done, or an extra day) is cleared; anything else
    /// becomes done, which for a count habit means count = target. Unlike
    /// `tap`, it never adds one: in a review, a tap means "I did it that day".
    func toggle(_ habit: LocalHabit, on day: Date, today: Date? = nil, now: Date = Date()) throws {
        let todayKey = HabitLedger.key(today ?? HabitLedger.todayAnchor(now: now))
        let row = try checkIn(habitUUID: habit.clientUUID, day: day)
        let entry = (row?.deletedAt == nil) ? row?.entry : nil
        let state = HabitLedger.state(habit.rule, entry: entry, on: day, today: todayKey)
        // A logged day before the start reads as notStarted; treat a complete
        // entry there as checked too, so the second tap still clears it.
        let complete = entry.map { $0.status == .done && $0.count >= max(1, habit.targetCount) } ?? false
        try set(habit, on: day, to: (state.isChecked || complete) ? .cleared : .done, today: todayKey, now: now)
    }

    /// The day editor's write. `today` is injectable for tests.
    func set(
        _ habit: LocalHabit,
        on day: Date,
        to setting: HabitDaySetting,
        today: Date? = nil,
        now: Date = Date()
    ) throws {
        let target = max(1, habit.targetCount)
        switch setting {
        case .done:
            try upsertCheckIn(habit, day: day, count: target, status: .done, today: today, now: now)
        case .partial(let count):
            let clamped = min(max(1, count), max(1, target - 1))
            try upsertCheckIn(habit, day: day, count: clamped, status: .done, today: today, now: now)
        case .skipped:
            try upsertCheckIn(habit, day: day, count: 0, status: .skipped, today: today, now: now)
        case .cleared:
            try guardLoggable(habit, day: day, today: today, now: now)
            if let row = try checkIn(habitUUID: habit.clientUUID, day: day), row.deletedAt == nil {
                row.deletedAt = now
                row.updatedAt = now
                try save()
            }
        }
    }

    /// Update the day's row, or create it when the day has none.
    private func upsertCheckIn(
        _ habit: LocalHabit,
        day rawDay: Date,
        count: Int,
        status: HabitCheckInStatus,
        today: Date?,
        now: Date
    ) throws {
        let day = HabitLedger.key(rawDay)
        try guardLoggable(habit, day: day, today: today, now: now)
        // A backfill: logging a day before the start day moves the start day
        // back to it, so the history counts. Days between the new start and
        // today with no check-in then read as missed, which is the honest
        // reading. Clearing never moves the start day forward.
        if day < HabitLedger.key(habit.startDay) {
            habit.startDay = day
            habit.updatedAt = now
        }
        if let row = try checkIn(habitUUID: habit.clientUUID, day: day) {
            row.count = count
            row.status = status.rawValue
            row.deletedAt = nil
            row.updatedAt = now
        } else {
            store.context.insert(LocalHabitCheckIn(
                clientUUID: HabitCheckInID.make(habitUUID: habit.clientUUID, day: day),
                habitUUID: habit.clientUUID,
                day: day,
                count: count,
                status: status.rawValue,
                createdAt: now,
                updatedAt: now
            ))
        }
        try save()
    }

    /// Only the future is refused. A day before the start day is a backfill,
    /// and a day that is not due is an extra day; both are allowed.
    private func guardLoggable(_ habit: LocalHabit, day: Date, today: Date?, now: Date) throws {
        let todayKey = HabitLedger.key(today ?? HabitLedger.todayAnchor(now: now))
        if HabitLedger.key(day) > todayKey { throw HabitServiceError.futureDay }
    }

    // MARK: - Validation

    static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HabitServiceError.emptyName }
        return trimmed
    }

    static func validate(schedule: HabitSchedule, weekdayMask: Int, targetCount: Int) throws {
        if schedule == .weekdays, weekdayMask & 0b111_1111 == 0 { throw HabitServiceError.noWeekdaysSelected }
        if targetCount < 1 { throw HabitServiceError.invalidTarget }
    }

    /// Keep the first grapheme only. A habit's mark is one emoji.
    static func cleanedEmoji(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map(String.init) ?? ""
    }

    static func cleanedUnit(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw HabitServiceError.persistence(error)
        }
    }
}
