import Foundation

/// The part of a habit the rules read (#661). A value copy of `LocalHabit`, so
/// the ledger can be tested without SwiftData.
struct HabitRule: Equatable, Sendable {
    var schedule: HabitSchedule
    /// Sunday-based: bit 0 = Sunday ... bit 6 = Saturday.
    var weekdayMask: Int
    /// At least 1.
    var targetCount: Int
    /// UTC day anchor.
    var startDay: Date
}

/// The part of a check-in the rules read (#661).
struct HabitDayEntry: Equatable, Sendable {
    var count: Int
    var status: HabitCheckInStatus
}

/// What one day of one habit reads as (#661).
///
/// Only `.missed` counts against the user, and only `.done` builds a streak.
/// Everything else is neutral in one of two ways: it is not the user's to act on
/// (`.future`, `.notStarted`, `.unscheduled`), or it is still open (`.pending`,
/// and `.partial` on today).
enum HabitDayState: Equatable, Sendable {
    /// After today. Cannot be logged.
    case future
    /// Before the habit's start day. Never missed.
    case notStarted
    /// The habit is not due on this weekday.
    case unscheduled
    /// Today, and nothing logged yet. Today stays pending until it ends.
    case pending
    case done
    /// Some progress but under the target. On today it is still open; on a past
    /// day it is not done, so it ends a streak, but it is not "missed" either,
    /// because something was logged.
    case partial(count: Int, target: Int)
    /// Skipped on purpose. Neutral for the streak and the rate.
    case skipped
    /// Due, in the past, and nothing done or skipped.
    case missed
    /// Done on a day the habit is NOT due: an extra day. Drawn as done, but
    /// neutral for the streak (it neither extends nor breaks it) and outside
    /// the rate, so a bonus session cannot push a rate past 100%.
    case extra

    /// True when the user may log this day: every day up to and including
    /// today. A day before the start day is loggable too, because a check-in
    /// there moves the start day back (a backfill). A day that is not due is
    /// loggable as an extra day. Only the future is locked.
    var isLoggable: Bool { self != .future }

    /// True when the day reads as checked, so a tap on it clears it.
    var isChecked: Bool {
        switch self {
        case .done, .extra: return true
        default: return false
        }
    }

    /// A short word for accessibility labels and captions.
    var label: String {
        switch self {
        case .future:      return "upcoming"
        case .notStarted:  return "before start"
        case .unscheduled: return "not due"
        case .pending:     return "not done yet"
        case .done:        return "done"
        case .partial(let count, let target): return "\(count) of \(target)"
        case .skipped:     return "skipped"
        case .missed:      return "not done"
        case .extra:       return "done, extra day"
        }
    }
}

/// The review numbers for one habit (#661).
struct HabitSummary: Equatable, Sendable {
    var today: HabitDayState
    var currentStreak: Int
    var bestStreak: Int
    /// Done days over counted days in the rate window. Nil when nothing in the
    /// window counts yet (a habit started today, or a week of skips).
    var rate: Double?
    var rateDone: Int
    var rateCounted: Int
}

/// One month of one habit, counted (#661).
struct HabitMonthSummary: Equatable, Sendable {
    var done = 0
    var skipped = 0
    var partial = 0
    var extra = 0
    /// Resolved due days: done, not done (the internal `.missed`), and past
    /// partials. A due day with nothing logged is never SHOWN as missed; it is
    /// an empty day. It still counts here, so the rate stays honest.
    var counted = 0

    /// Done over counted. Nil when nothing in the month has resolved yet.
    var rate: Double? { counted > 0 ? Double(done) / Double(counted) : nil }
}

/// The rules for "missed", "streak" and "rate" (#661).
///
/// ### Missed is derived, never stored
///
/// A day is missed only when all four hold: the habit is scheduled that
/// weekday, the day is on or after `startDay`, the day is before today, and the
/// day has no done or skipped check-in. Nothing writes a "missed" row, so
/// changing a schedule or a start day re-reads the whole history correctly.
///
/// ### All day arithmetic runs on UTC anchors
///
/// Every `Date` in and out of this type is a UTC day anchor
/// (`WallClock.dayAnchor`), and every calendar question is asked of
/// `WallClock.dayCalendar` (UTC). The device timezone enters in exactly one
/// place, turning "now" into today's anchor, and the caller does that. So
/// flying from Singapore to Rome does not move a stored day, and a Sunday
/// stays a Sunday (#506).
///
/// Pure: no SwiftUI, no SwiftData, no clock reads.
enum HabitLedger {

    // MARK: - Days

    /// Today's anchor as the device sees it. The one timezone-dependent step.
    static func todayAnchor(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return WallClock.dayCalendar.date(from: parts) ?? WallClock.startOfStoredDay(now)
    }

    /// Normalise any stored value to its anchor. Idempotent.
    static func key(_ day: Date) -> Date { WallClock.startOfStoredDay(day) }

    static func adding(_ days: Int, to day: Date) -> Date {
        WallClock.storedDay(day, byAdding: days)
    }

    /// `count` consecutive anchors ending on `end`, oldest first.
    static func days(endingOn end: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        let last = key(end)
        return (0..<count).map { adding($0 - (count - 1), to: last) }
    }

    /// 0 = Sunday ... 6 = Saturday, read from the anchor's UTC components, so
    /// it names the intended calendar day in any device timezone.
    static func weekdayIndex(of day: Date) -> Int {
        WallClock.dayCalendar.component(.weekday, from: key(day)) - 1
    }

    // MARK: - One day

    static func isScheduled(_ rule: HabitRule, on day: Date) -> Bool {
        switch rule.schedule {
        case .daily:
            return true
        case .weekdays:
            return rule.weekdayMask & (1 << weekdayIndex(of: day)) != 0
        }
    }

    /// The state of one day. `entry` is that day's check-in, if there is one.
    static func state(
        _ rule: HabitRule,
        entry: HabitDayEntry?,
        on day: Date,
        today: Date
    ) -> HabitDayState {
        let day = key(day), today = key(today)
        if day > today { return .future }
        if day < key(rule.startDay) { return .notStarted }
        let target = max(1, rule.targetCount)
        if !isScheduled(rule, on: day) {
            if let entry, entry.status == .done, entry.count >= target { return .extra }
            return .unscheduled
        }
        if let entry {
            if entry.status == .skipped { return .skipped }
            if entry.count >= target { return .done }
            if entry.count > 0 { return .partial(count: entry.count, target: target) }
        }
        return day == today ? .pending : .missed
    }

    /// States for a run of days, in the order given.
    static func states(
        _ rule: HabitRule,
        entries: [Date: HabitDayEntry],
        days: [Date],
        today: Date
    ) -> [HabitDayState] {
        days.map { state(rule, entry: entries[key($0)], on: $0, today: today) }
    }

    // MARK: - Streaks

    /// Done days in a row, counted back from today.
    ///
    /// Today adds one if it is done, and otherwise costs nothing: an open day
    /// cannot break a streak before it has ended. Skipped and unscheduled days
    /// are stepped over. A missed day, or a past day that stopped short of the
    /// target, ends the count.
    static func currentStreak(_ rule: HabitRule, entries: [Date: HabitDayEntry], today: Date) -> Int {
        let today = key(today)
        let start = key(rule.startDay)
        var streak = 0
        var day = today
        while day >= start {
            switch state(rule, entry: entries[day], on: day, today: today) {
            case .done:
                streak += 1
            case .skipped, .unscheduled, .pending, .extra:
                break
            case .partial:
                // An open partial today is neutral; a finished one ends the run.
                if day != today { return streak }
            case .missed, .notStarted, .future:
                return streak
            }
            day = adding(-1, to: day)
        }
        return streak
    }

    /// The longest run of done days anywhere in the history, by the same rules
    /// as `currentStreak`.
    ///
    /// Starts at the later of the start day and the first logged day. Nothing
    /// before the first check-in can be done, so walking it would only add
    /// misses, and a start day far in the past would cost a walk per render.
    static func bestStreak(_ rule: HabitRule, entries: [Date: HabitDayEntry], today: Date) -> Int {
        let today = key(today)
        guard let firstLogged = entries.keys.map(key).min() else { return 0 }
        var day = max(key(rule.startDay), firstLogged)
        var best = 0, run = 0
        while day <= today {
            switch state(rule, entry: entries[day], on: day, today: today) {
            case .done:
                run += 1
                best = max(best, run)
            case .skipped, .unscheduled, .pending, .notStarted, .future, .extra:
                break
            case .partial:
                if day != today { run = 0 }
            case .missed:
                run = 0
            }
            day = adding(1, to: day)
        }
        return best
    }

    // MARK: - Rate and misses

    /// Done days over counted days, from `from` through today.
    ///
    /// A counted day is a due day that has resolved: done, missed, or a past
    /// partial. Skipped days are out of both numbers. Today counts only once it
    /// is done, so the rate does not drop every morning.
    static func rate(
        _ rule: HabitRule,
        entries: [Date: HabitDayEntry],
        from: Date,
        today: Date
    ) -> (done: Int, counted: Int) {
        let today = key(today)
        var day = max(key(from), key(rule.startDay))
        var done = 0, counted = 0
        while day <= today {
            switch state(rule, entry: entries[day], on: day, today: today) {
            case .done:
                done += 1
                counted += 1
            case .missed:
                counted += 1
            case .partial:
                if day != today { counted += 1 }
            case .skipped, .unscheduled, .pending, .notStarted, .future, .extra:
                break
            }
            day = adding(1, to: day)
        }
        return (done, counted)
    }

    /// Everything the review shows, in one call.
    static func summary(
        _ rule: HabitRule,
        entries: [Date: HabitDayEntry],
        today: Date,
        rateWindowDays: Int = 7
    ) -> HabitSummary {
        let today = key(today)
        let window = rate(rule, entries: entries, from: adding(-(rateWindowDays - 1), to: today), today: today)
        return HabitSummary(
            today: state(rule, entry: entries[today], on: today, today: today),
            currentStreak: currentStreak(rule, entries: entries, today: today),
            bestStreak: bestStreak(rule, entries: entries, today: today),
            rate: window.counted > 0 ? Double(window.done) / Double(window.counted) : nil,
            rateDone: window.done,
            rateCounted: window.counted
        )
    }

    // MARK: - Months

    /// The anchor of the first day of the month holding `day`.
    static func monthStart(for day: Date) -> Date {
        let parts = WallClock.dayCalendar.dateComponents([.year, .month], from: key(day))
        return WallClock.dayCalendar.date(from: parts) ?? key(day)
    }

    /// The first day of the month `months` away from the month holding `day`.
    static func month(_ months: Int, from day: Date) -> Date {
        WallClock.dayCalendar.date(byAdding: .month, value: months, to: monthStart(for: day))
            ?? monthStart(for: day)
    }

    /// Every day of the month holding `day`, first to last.
    static func daysInMonth(of day: Date) -> [Date] {
        let first = monthStart(for: day)
        let count = WallClock.dayCalendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return (0..<count).map { adding($0, to: first) }
    }

    /// The earliest month the review can go back to: the month of the start
    /// day or of the first check-in, whichever is earlier.
    static func earliestMonth(_ rule: HabitRule, entries: [Date: HabitDayEntry]) -> Date {
        let first = ([key(rule.startDay)] + entries.keys.map(key)).min() ?? key(rule.startDay)
        return monthStart(for: first)
    }

    /// What happened in one month: done and skipped days, extra days,
    /// and the rate. The rate uses the same rule as `rate(...)`: done over
    /// resolved due days, skips left out. In the current month it stops at
    /// today, and today counts only once it is done.
    static func monthSummary(
        _ rule: HabitRule,
        entries: [Date: HabitDayEntry],
        month: Date,
        today: Date
    ) -> HabitMonthSummary {
        let today = key(today)
        var out = HabitMonthSummary()
        for day in daysInMonth(of: month) where day <= today {
            switch state(rule, entry: entries[day], on: day, today: today) {
            case .done:
                out.done += 1
                out.counted += 1
            case .missed:
                out.counted += 1
            case .partial:
                out.partial += 1
                if day != today { out.counted += 1 }
            case .skipped:
                out.skipped += 1
            case .extra:
                out.extra += 1
            case .pending, .unscheduled, .notStarted, .future:
                break
            }
        }
        return out
    }

    // MARK: - Grouping

    /// Group check-ins by habit, then by anchored day, in one pass. The card and
    /// the section fetch every check-in ONCE and call this, so no row view ever
    /// runs a query of its own (#442).
    static func group(
        _ checkIns: [(habitUUID: String, day: Date, entry: HabitDayEntry)]
    ) -> [String: [Date: HabitDayEntry]] {
        var out: [String: [Date: HabitDayEntry]] = [:]
        for item in checkIns {
            out[item.habitUUID, default: [:]][key(item.day)] = item.entry
        }
        return out
    }
}
