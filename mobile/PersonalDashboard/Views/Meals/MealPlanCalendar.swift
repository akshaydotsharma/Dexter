import Foundation

/// The month arithmetic behind the Plan tab's date control (#599).
///
/// Free functions over an injected `Calendar`, exactly as `MealCalendar` is, and
/// for the same reason: a grid is pure, and every way it can be wrong — a month
/// that starts on the wrong weekday, a February that loses its 29th, a step that
/// lands in the wrong month — is SILENT. Nothing on screen looks broken; the
/// dates are simply wrong, and a plan written against a wrong date stays
/// invisible until the day arrives.
///
/// Every `Date` here is a DEVICE-local midnight. Stored day anchors appear only
/// where the store is read, in `MealPlanDay.readings(in:)`.
///
/// ### Why this is not `MealCalendar` with a flag
///
/// One rule differs and it is the load-bearing one.
/// `MealCalendar.isSelectable` refuses a future day, because a meal you have not
/// eaten is not a log entry, and `canStepForward` clamps the grid at the current
/// month for the same reason. A plan is the opposite: the future is the only
/// part of it that matters.
///
/// Adding an `allowsFuture` parameter to those functions would leave the most
/// important rule in this feature expressed as a boolean somebody has to pass
/// correctly at every call site, and passing it wrong in one place would
/// silently disable planning ahead. The parts that genuinely have no policy in
/// them — the month's slots, the weekday headings, the month's first day — are
/// REUSED from `MealCalendar` below rather than copied.
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

    /// Step the visible month. Unclamped in BOTH directions — see the note on
    /// the type.
    static func stepMonth(_ month: Date, by months: Int, calendar: Calendar = .current) -> Date {
        let start = monthStart(of: month, calendar: calendar)
        guard let moved = calendar.date(byAdding: .month, value: months, to: start) else { return start }
        return monthStart(of: moved, calendar: calendar)
    }
}
