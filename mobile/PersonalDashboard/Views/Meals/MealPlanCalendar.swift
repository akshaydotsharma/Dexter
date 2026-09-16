import Foundation

/// Which stretch of time the Plan tab is showing (#599).
///
/// The user asked for weekly plans and a monthly plan, and these are the two.
/// They are not two views of the same thing: a week is the unit you shop and
/// cook against, and a month is the unit you look at to see whether you have
/// bothered. So the week scope shows enough per day to act on, and the month
/// scope shows only whether a day is filled in.
enum MealPlanScope: String, CaseIterable, Identifiable {
    case week
    case month

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week:  return "Week"
        case .month: return "Month"
        }
    }
}

/// The grid arithmetic behind the Plan tab (#599).
///
/// Free functions over an injected `Calendar`, exactly as `MealCalendar` is,
/// and for the same reason: a grid is pure, and every way it can be wrong — a
/// week that starts on the wrong day, a month that loses 29 February, a step
/// that lands on the wrong month — is SILENT. Nothing on screen would look
/// broken; the dates would simply be wrong.
///
/// Every `Date` here is a DEVICE-local midnight, matching `selectedDay` on the
/// Meals section. Stored day anchors appear only where the store is read, in
/// `MealPlanDay.readings(in:)`.
///
/// ### Why this is not `MealCalendar` with a flag
///
/// One rule differs and it is the load-bearing one. `MealCalendar.isSelectable`
/// refuses a future day, because a meal you have not eaten is not a log entry,
/// and `canStepForward` clamps the grid at the current month for the same
/// reason. A plan is the exact opposite: the future is the ONLY part of it that
/// matters. Adding a `allowsFuture` parameter to those functions would leave the
/// most important rule in the feature expressed as a boolean somebody has to
/// pass correctly at every call site, and passing it wrong in one place would
/// silently disable planning ahead.
///
/// The parts that genuinely are the same — the month's slots, the weekday
/// headings, the month's first day — are REUSED from `MealCalendar` below rather
/// than copied. Those have no policy in them at all.
enum MealPlanCalendar {

    /// Device-local midnight of the first day of the month containing `date`.
    /// Shared with the Tracking calendar: a month starts where it starts.
    static func monthStart(of date: Date, calendar: Calendar = .current) -> Date {
        MealCalendar.monthStart(of: date, calendar: calendar)
    }

    /// The month's squares, in reading order, padded to whole weeks.
    static func monthSlots(forMonthOf date: Date, calendar: Calendar = .current) -> [MealCalendarSlot] {
        MealCalendar.slots(forMonthOf: date, calendar: calendar)
    }

    /// The one-letter-or-two weekday headings, starting at `calendar.firstWeekday`.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        MealCalendar.weekdaySymbols(calendar: calendar)
    }

    /// Device-local midnight of the first day of the week containing `date`,
    /// honouring `calendar.firstWeekday` so the strip matches the device's own
    /// week rather than a hard-coded Monday.
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    /// The seven days of the week containing `date`, in order.
    static func weekDays(of date: Date, calendar: Calendar = .current) -> [Date] {
        let start = weekStart(of: date, calendar: calendar)
        return (0..<7).map { offset in
            calendar.date(byAdding: .day, value: offset, to: start) ?? start
        }
    }

    /// Step the visible week. Unclamped in BOTH directions — see the note on
    /// the type.
    static func stepWeek(_ week: Date, by weeks: Int, calendar: Calendar = .current) -> Date {
        let start = weekStart(of: week, calendar: calendar)
        return calendar.date(byAdding: .day, value: weeks * 7, to: start) ?? start
    }

    /// Step the visible month. Unclamped in both directions.
    static func stepMonth(_ month: Date, by months: Int, calendar: Calendar = .current) -> Date {
        let start = monthStart(of: month, calendar: calendar)
        guard let moved = calendar.date(byAdding: .month, value: months, to: start) else { return start }
        return monthStart(of: moved, calendar: calendar)
    }

    /// The inclusive day range the scope covers, which is what the ingredient
    /// roll-up is built over.
    ///
    /// Both ends are device-local midnights and both are INSIDE the range, so a
    /// caller hands them straight to `MealPlanService.entries(from:to:)`, which
    /// is inclusive for the same reason.
    static func range(
        for scope: MealPlanScope,
        containing day: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        switch scope {
        case .week:
            let days = weekDays(of: day, calendar: calendar)
            return (days.first ?? day, days.last ?? day)
        case .month:
            let start = monthStart(of: day, calendar: calendar)
            let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 28
            let end = calendar.date(byAdding: .day, value: dayCount - 1, to: start) ?? start
            return (start, end)
        }
    }
}
