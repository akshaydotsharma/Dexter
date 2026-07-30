import Foundation

/// Which section of the Tasks list a due date belongs to.
enum TaskDueBucket: Equatable {
    case overdue
    case today
    case tomorrow
    case thisWeek
    case later
}

/// The day boundaries the Tasks list buckets on (#418).
///
/// Lifted out of `TasksView.computeBuckets` because this is pure, locale-sensitive
/// date arithmetic that was living as a private function inside a SwiftUI view,
/// where no test could reach it. What it hid: `weekEnd` was `today + 7 days`, so on
/// Friday 31 July a task due Thursday 6 August sat under **This Week**. That is a
/// rolling seven-day window wearing a calendar-week label.
///
/// ## Why the week is anchored to Monday rather than the locale
///
/// `Calendar.current.firstWeekday` is **1 (Sunday)** in this user's region, so
/// `dateInterval(of: .weekOfYear)` would close the week on Saturday. On a Friday
/// that leaves This Week empty (Saturday is already Tomorrow) and drops Sunday into
/// Later, which is a second wrong answer rather than a fix. "This week" ends when
/// the weekend does, so the week is anchored to start on Monday and the boundary
/// holds whatever the device is set to.
///
/// ## The accepted consequence
///
/// Late in the week This Week holds a day or two, and on Saturday and Sunday it is
/// empty and hides itself. That is what a calendar week is, and it is the point:
/// Today and Tomorrow already cover the near term, so nothing becomes unreachable.
struct TaskBucketWindow {
    /// Start of today. A due date before this is overdue.
    let today: Date
    /// Start of tomorrow, the exclusive upper bound of Today.
    let tomorrow: Date
    /// Start of the day after tomorrow, the exclusive upper bound of Tomorrow.
    let dayAfterTomorrow: Date
    /// Start of the Monday that follows this week, the exclusive upper bound of
    /// This Week. Everything from here on is Later.
    let weekEnd: Date

    /// `calendar` is injectable so a test can pin the first weekday; `now` so it can
    /// pin the day. Both default to the live values the app runs on.
    init(now: Date = Date(), calendar: Calendar = .current) {
        let start = calendar.startOfDay(for: now)
        today = start
        tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: start) ?? start
        weekEnd = Self.startOfNextWeek(containing: start, calendar: calendar)
    }

    func bucket(for due: Date) -> TaskDueBucket {
        if due < today { return .overdue }
        if due < tomorrow { return .today }
        if due < dayAfterTomorrow { return .tomorrow }
        if due < weekEnd { return .thisWeek }
        return .later
    }

    /// The last day This Week covers, at the start of that day. Nil when the week
    /// ends before the section can hold anything, which is every Saturday and
    /// Sunday. Used to place a task typed into the This Week section on a day that
    /// section actually shows: seeding it `today + 3` (the old behaviour) could put
    /// it straight into Later, so the row would vanish as it was created.
    var lastDayOfThisWeek: Date? {
        guard let last = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -1, to: weekEnd),
              last >= dayAfterTomorrow else { return nil }
        return last
    }

    /// Start of the week AFTER the one containing `day`, with the week anchored to
    /// Monday so it always closes on a Sunday. Falls back to seven days out if the
    /// calendar cannot produce an interval, which keeps the old behaviour rather
    /// than collapsing the bucket entirely.
    private static func startOfNextWeek(containing day: Date, calendar: Calendar) -> Date {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2   // Monday, so the week ends on Sunday
        if let interval = weekCalendar.dateInterval(of: .weekOfYear, for: day) {
            return interval.end
        }
        return calendar.date(byAdding: .day, value: 7, to: day) ?? day
    }
}
