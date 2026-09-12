import Foundation

/// The date arithmetic behind a `RecurringTask` (#524).
///
/// A value type with no SwiftData coupling, so every rule below can be tested
/// against a fixed calendar without a store, a context or a schema. The template
/// holds the fields; this decides what they mean.
///
/// ### Which calendar
///
/// Device-local throughout. A task is due at "09:00 on Thursday wherever I am",
/// which is neither the UTC-anchored wall clock a ticket needs (#168, #506) nor
/// a fixed instant. The template's `startDate` / `endDate` ARE stored as UTC day
/// anchors, because they name calendar days, so they are read back through
/// `WallClock.deviceDay(from:)` before anything here compares them.
///
/// ### Which week
///
/// Weeks are Sunday-based and anchored on the template's own start date, not on
/// `Calendar.firstWeekday`. A rule must not change meaning because the device
/// moved to a locale that starts its weeks on Monday, and "every 2 weeks" has to
/// count from a fixed point or it drifts. The weekday PICKER still renders in the
/// device's first-weekday order; only the arithmetic is pinned.
struct RecurrenceRule: Equatable, Sendable {
    var frequency: RecurrenceFrequency
    /// Every N units. Always at least 1.
    var interval: Int
    /// Bit 0 = Sunday … bit 6 = Saturday. 0 means "the weekday `startDay` falls on".
    var weekdayMask: Int
    /// 1...31, clamped to the month's length when a date is built.
    var dayOfMonth: Int
    /// 1...12. Yearly only.
    var monthOfYear: Int
    /// Minutes past local midnight.
    var timeOfDayMinutes: Int
    /// Device-local start of the first eligible day.
    var startDay: Date
    /// Device-local start of the last eligible day. Nil = open-ended.
    var endDay: Date?

    var calendar: Calendar

    // MARK: - Construction

    init(
        frequency: RecurrenceFrequency,
        interval: Int,
        weekdayMask: Int,
        dayOfMonth: Int,
        monthOfYear: Int,
        timeOfDayMinutes: Int,
        startDay: Date,
        endDay: Date?,
        calendar: Calendar = .current
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdayMask = weekdayMask
        self.dayOfMonth = min(max(dayOfMonth, 1), 31)
        self.monthOfYear = min(max(monthOfYear, 1), 12)
        self.timeOfDayMinutes = min(max(timeOfDayMinutes, 0), 24 * 60 - 1)
        self.calendar = calendar
        self.startDay = calendar.startOfDay(for: startDay)
        self.endDay = endDay.map { calendar.startOfDay(for: $0) }
    }

    /// Read a stored template. The day anchors are converted to device days here,
    /// which is the single place that conversion happens for the whole feature.
    init(template: RecurringTask, calendar: Calendar = .current) {
        self.init(
            frequency: template.frequencyEnum,
            interval: template.interval,
            weekdayMask: template.weekdayMask,
            dayOfMonth: template.dayOfMonth,
            monthOfYear: template.monthOfYear,
            timeOfDayMinutes: template.timeOfDayMinutes,
            startDay: WallClock.deviceDay(from: template.startDate),
            endDay: template.endDate.map { WallClock.deviceDay(from: $0) },
            calendar: calendar
        )
    }

    // MARK: - The walk

    /// The next day this rule fires on, strictly after `cursorDay`.
    ///
    /// `nil` cursor means "never run", so the walk starts at `startDay`. Returns
    /// `nil` once the rule is exhausted, which is only possible with an end date.
    func nextDay(after cursorDay: Date?) -> Date? {
        let floor: Date
        if let cursorDay, let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursorDay)) {
            floor = max(calendar.startOfDay(for: dayAfter), startDay)
        } else {
            floor = startDay
        }
        guard let day = firstFireDay(onOrAfter: floor) else { return nil }
        if let endDay, day > endDay { return nil }
        return day
    }

    /// The first day this rule fires on at or after `floor`, ignoring the end
    /// date (the caller applies it, so "exhausted" and "not yet" stay separate).
    func firstFireDay(onOrAfter floor: Date) -> Date? {
        let target = max(calendar.startOfDay(for: floor), startDay)
        switch frequency {
        case .daily:   return nextDaily(onOrAfter: target)
        case .weekly:  return nextWeekly(onOrAfter: target)
        case .monthly: return nextMonthly(onOrAfter: target)
        case .yearly:  return nextYearly(onOrAfter: target)
        }
    }

    /// The due moment for a fire day: the day, at the rule's time of day.
    ///
    /// Falls back to seconds-from-midnight if `bySettingHour` cannot build the
    /// time, which happens for the hour a spring-forward skips.
    func dueDate(on day: Date) -> Date {
        let start = calendar.startOfDay(for: day)
        let hour = timeOfDayMinutes / 60
        let minute = timeOfDayMinutes % 60
        if let exact = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) {
            return exact
        }
        return start.addingTimeInterval(TimeInterval(timeOfDayMinutes * 60))
    }

    // MARK: - Per-frequency walks
    //
    // Each one anchors on the first day the rule can fire, then steps by the
    // interval from there. Anchoring on the template's own start (rather than on
    // an epoch or on the current month) is what makes "every 2 weeks" mean every
    // second week FROM THE START, which is the only reading that stays stable as
    // the cursor moves.

    private func nextDaily(onOrAfter target: Date) -> Date? {
        let delta = days(from: startDay, to: target)
        guard delta > 0 else { return startDay }
        let steps = (delta + interval - 1) / interval   // ceil
        return addDays(steps * interval, to: startDay)
    }

    private func nextWeekly(onOrAfter target: Date) -> Date? {
        let selected = selectedWeekdays
        guard !selected.isEmpty else { return nil }

        // Week 0 is the week holding the FIRST day this rule fires on, which is not
        // always the week holding the start day: "every 2 weeks on Monday" created on
        // a Saturday fires on the Monday two days later, and counting from the start
        // day's own week would burn the first cycle on a Monday already behind it and
        // push that first occurrence out by a fortnight.
        guard let firstFire = firstWeeklyFireDay(selected: selected),
              let base = addDays(-weekdayIndex(of: firstFire), to: firstFire),
              let targetWeekStart = addDays(-weekdayIndex(of: target), to: target)
        else { return nil }

        var week = max(0, days(from: base, to: targetWeekStart) / 7)
        if week % interval != 0 {
            week += interval - (week % interval)
        }

        // Bounded: `interval` is capped in the editor, and a rule that fires at
        // most once a week cannot need more than this many weeks to produce one.
        for _ in 0..<(interval * 8 + 8) {
            for weekday in selected {
                guard let candidate = addDays(week * 7 + weekday, to: base) else { continue }
                if candidate >= target { return candidate }
            }
            week += interval
        }
        return nil
    }

    /// The earliest selected weekday falling on or after `startDay`, ignoring the
    /// interval. This is what week 0 is pinned to, so every later week is counted
    /// from a day the rule actually fires on.
    private func firstWeeklyFireDay(selected: [Int]) -> Date? {
        guard let sundayOfStart = addDays(-weekdayIndex(of: startDay), to: startDay) else { return nil }
        // Two weeks is always enough: any weekday appears once in each.
        for week in 0...1 {
            for weekday in selected {
                guard let candidate = addDays(week * 7 + weekday, to: sundayOfStart) else { continue }
                if candidate >= startDay { return candidate }
            }
        }
        return nil
    }

    private func nextMonthly(onOrAfter target: Date) -> Date? {
        // First month whose clamped day is not already behind the start day.
        var base = firstOfMonth(startDay)
        if let firstInStartMonth = clampedDay(inMonthOf: base), firstInStartMonth < startDay {
            guard let next = addMonths(1, to: base) else { return nil }
            base = next
        }

        var step = max(0, months(from: base, to: firstOfMonth(target)))
        if step % interval != 0 {
            step += interval - (step % interval)
        }

        for _ in 0..<(interval + 2) {
            guard let anchor = addMonths(step, to: base),
                  let candidate = clampedDay(inMonthOf: anchor) else { return nil }
            if candidate >= target { return candidate }
            step += interval
        }
        return nil
    }

    private func nextYearly(onOrAfter target: Date) -> Date? {
        let startYear = calendar.component(.year, from: startDay)
        var baseYear = startYear
        if let inStartYear = yearlyDay(in: startYear), inStartYear < startDay {
            baseYear += 1
        }

        let targetYear = calendar.component(.year, from: target)
        var step = max(0, targetYear - baseYear)
        if step % interval != 0 {
            step += interval - (step % interval)
        }

        for _ in 0..<(interval + 2) {
            guard let candidate = yearlyDay(in: baseYear + step) else { return nil }
            if candidate >= target { return candidate }
            step += interval
        }
        return nil
    }

    // MARK: - Weekdays

    /// The weekdays this rule fires on, as 0 = Sunday … 6 = Saturday, ascending.
    ///
    /// An empty mask falls back to the weekday `startDay` lands on, so a weekly
    /// template saved without touching the day picker still has a coherent rule
    /// rather than silently never firing.
    var selectedWeekdays: [Int] {
        let explicit = (0...6).filter { weekdayMask & (1 << $0) != 0 }
        return explicit.isEmpty ? [weekdayIndex(of: startDay)] : explicit
    }

    /// 0 = Sunday … 6 = Saturday. `Calendar.weekday` is 1-based from Sunday in
    /// every locale, so this is locale-independent.
    private func weekdayIndex(of date: Date) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    // MARK: - Date helpers

    private func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    private func months(from: Date, to: Date) -> Int {
        calendar.dateComponents([.month], from: from, to: to).month ?? 0
    }

    private func addDays(_ count: Int, to date: Date) -> Date? {
        calendar.date(byAdding: .day, value: count, to: date).map { calendar.startOfDay(for: $0) }
    }

    private func addMonths(_ count: Int, to date: Date) -> Date? {
        calendar.date(byAdding: .month, value: count, to: date)
    }

    private func firstOfMonth(_ date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    /// `dayOfMonth` inside the month containing `anchor`, clamped to that month's
    /// last day so a rule set to 31 fires on 28/29 February.
    private func clampedDay(inMonthOf anchor: Date) -> Date? {
        let lastDay = calendar.range(of: .day, in: .month, for: anchor)?.count ?? 28
        var parts = calendar.dateComponents([.year, .month], from: anchor)
        parts.day = min(dayOfMonth, lastDay)
        return calendar.date(from: parts).map { calendar.startOfDay(for: $0) }
    }

    /// `monthOfYear` / `dayOfMonth` in a given year, with the same clamping
    /// (so 29 February on a common year fires on the 28th).
    private func yearlyDay(in year: Int) -> Date? {
        var parts = DateComponents()
        parts.year = year
        parts.month = monthOfYear
        parts.day = 1
        guard let anchor = calendar.date(from: parts) else { return nil }
        return clampedDay(inMonthOf: anchor)
    }
}

// MARK: - Words

extension RecurrenceRule {
    /// The rule in words, e.g. "Every 2 weeks on Mon, Fri at 09:00".
    ///
    /// One sentence, because it has to read on a single list row next to the
    /// title without wrapping it.
    var summary: String {
        let cadence: String
        switch frequency {
        case .daily:
            cadence = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            let days = selectedWeekdays.map { Self.shortWeekdayNames[$0] }.joined(separator: ", ")
            let every = interval == 1 ? "Weekly" : "Every \(interval) weeks"
            cadence = "\(every) on \(days)"
        case .monthly:
            let every = interval == 1 ? "Monthly" : "Every \(interval) months"
            cadence = "\(every) on the \(Self.ordinal(dayOfMonth))"
        case .yearly:
            let every = interval == 1 ? "Yearly" : "Every \(interval) years"
            cadence = "\(every) on \(Self.monthNames[monthOfYear - 1]) \(dayOfMonth)"
        }
        return "\(cadence) at \(timeOfDayLabel)"
    }

    /// "09:00" / "9:00 AM", however the device writes a time.
    ///
    /// Formatted through this rule's OWN calendar and timezone, not the process
    /// default: the two are the same in the app, and different under test, where a
    /// summary built for a Singapore rule would otherwise print a Los Angeles hour.
    var timeOfDayLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: dueDate(on: startDay))
    }

    /// Short weekday names indexed 0 = Sunday … 6 = Saturday, from the device's
    /// own calendar so they localise.
    static let shortWeekdayNames: [String] = {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.count == 7 ? symbols : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    }()

    static let monthNames: [String] = {
        let symbols = Calendar.current.monthSymbols
        return symbols.count == 12 ? symbols : [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
    }()

    /// "1st", "2nd", "23rd". Used for a day of the month, so only 1...31 matter.
    static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 10, value % 100) {
        case (_, 11), (_, 12), (_, 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default:     suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}

// MARK: - Day keys

extension RecurrenceRule {
    /// "yyyy-MM-dd" for a device-local day. The cursor and the per-occurrence
    /// dedupe key are both built from this, so they agree by construction.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Inverse of `dayKey`. Nil when the string is not a key this wrote.
    static func day(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps).map { calendar.startOfDay(for: $0) }
    }
}
