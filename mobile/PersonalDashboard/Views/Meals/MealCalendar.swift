import Foundation

/// What one calendar cell has to say about its day (#559).
///
/// Two cases and not one optional number, because the distinction they draw is
/// the whole point of the grid. A day nobody logged is not a day of zero
/// calories; it is a day with no record. `MealDayCard` already says this in
/// words through `MealDaySummary.isUnlogged`, and a grid that printed "0" on
/// every untouched square would contradict the card the moment you tapped one.
enum MealDayReading: Equatable, Sendable {
    /// Nothing at all was recorded on this day.
    case unlogged
    /// Meals were recorded. `calories` is the counted total, so it can legitimately
    /// be zero: a day whose only meals were suspect or needed detail is a LOGGED
    /// day whose numbers are all held back.
    case logged(calories: Double)

    var isLogged: Bool {
        if case .logged = self { return true }
        return false
    }

    /// Counted calories, or nil when nothing was logged. Nil rather than zero,
    /// so a caller cannot accidentally average an absence into a total.
    var calories: Double? {
        if case .logged(let value) = self { return value }
        return nil
    }
}

/// One square in the month grid. A slot with no `day` is the padding before the
/// first of the month or after the last.
///
/// Identified by its POSITION rather than by its date, so the two or three blank
/// squares at either end stay distinct to `ForEach` without inventing dates for
/// them.
struct MealCalendarSlot: Identifiable, Equatable {
    let index: Int
    /// Device-local midnight of the day, or nil for padding.
    let day: Date?

    var id: Int { index }
}

/// The month-grid arithmetic behind History (#559).
///
/// Kept as free functions over an injected `Calendar` rather than as state on
/// the view, for two reasons. A grid is pure: a month and a calendar decide it
/// completely, so it is the kind of thing that should be pinned by tests rather
/// than eyeballed on a screenshot. And the failures it can have — a month that
/// starts on the wrong weekday, a February that is 28 days in a leap year, a
/// forward step that walks past today — are all silent. Nothing on screen would
/// look broken; the dates would simply be wrong.
///
/// Every `Date` here is a DEVICE-local midnight, matching `selectedDay` in the
/// Meals section. Stored day anchors appear only in ``readings(in:)``, which is
/// where the store is read.
enum MealCalendar {

    /// Device-local midnight of the first day of the month containing `date`.
    static func monthStart(of date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    /// The month's squares, in reading order, padded to whole weeks.
    ///
    /// Leading padding aligns the first of the month under its weekday column,
    /// honouring `calendar.firstWeekday` so the grid matches the device's own
    /// week rather than a hard-coded Monday. Trailing padding completes the last
    /// week, so the grid is always a rectangle and the rows below it do not move
    /// as the months are stepped through.
    static func slots(forMonthOf date: Date, calendar: Calendar = .current) -> [MealCalendarSlot] {
        let start = monthStart(of: date, calendar: calendar)
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let dayCount = range.count

        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var slots: [MealCalendarSlot] = []
        for index in 0..<leading {
            slots.append(MealCalendarSlot(index: index, day: nil))
        }
        for offset in 0..<dayCount {
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            slots.append(MealCalendarSlot(index: leading + offset, day: calendar.startOfDay(for: day)))
        }
        let remainder = slots.count % 7
        if remainder != 0 {
            for index in slots.count..<(slots.count + 7 - remainder) {
                slots.append(MealCalendarSlot(index: index, day: nil))
            }
        }
        return slots
    }

    /// The one-letter-or-two weekday headings, starting at `calendar.firstWeekday`.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// A day can be picked if it has already happened. Today counts; tomorrow
    /// does not.
    ///
    /// The rule is a day comparison and never an instant one: "today" at 23:30
    /// must still be selectable, and a `Date() <= Date()` test would depend on
    /// which of the two was built first.
    static func isSelectable(_ day: Date, today: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) <= calendar.startOfDay(for: today)
    }

    /// Whether the grid can step forward from `month`. False once `month` is the
    /// month holding `today`, because the months after it hold no days anyone
    /// could have logged.
    ///
    /// Backwards has no equivalent limit on purpose. A month with nothing in it
    /// is still reachable, so the grid can never trap the user behind a gap in
    /// the log.
    static func canStepForward(from month: Date, today: Date = Date(), calendar: Calendar = .current) -> Bool {
        monthStart(of: month, calendar: calendar) < monthStart(of: today, calendar: calendar)
    }

    /// Step the visible month, clamped so it never passes the current month.
    /// Returns the month unchanged when the step is not allowed.
    static func step(
        _ month: Date,
        byMonths delta: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let start = monthStart(of: month, calendar: calendar)
        guard let moved = calendar.date(byAdding: .month, value: delta, to: start) else { return start }
        let limit = monthStart(of: today, calendar: calendar)
        return min(monthStart(of: moved, calendar: calendar), limit)
    }

    /// Every logged day in the store, read once, keyed by its stored day anchor.
    ///
    /// Built in one pass rather than by asking `MealDaySummary.onDay` per square,
    /// which would re-scan the whole table forty-two times a month. The totals
    /// still come from `MealDaySummary`, so the exclusions the card draws — a
    /// suspect meal, a meal that needs detail — are held out of the cell's figure
    /// exactly as they are held out of the day card's. A cell that summed its own
    /// rows would print a larger number than the card it opens.
    ///
    /// A day absent from the result is `.unlogged`; see ``reading(for:in:)``.
    static func readings(in meals: [LocalMeal]) -> [Date: MealDayReading] {
        var byDay: [Date: [LocalMeal]] = [:]
        for meal in meals {
            byDay[WallClock.startOfStoredDay(meal.date), default: []].append(meal)
        }
        return byDay.mapValues { .logged(calories: MealDaySummary(meals: $0).totals.calories) }
    }

    /// The reading for one device-local day out of a table built by ``readings(in:)``.
    static func reading(for day: Date, in readings: [Date: MealDayReading]) -> MealDayReading {
        readings[WallClock.dayAnchor(from: day)] ?? .unlogged
    }

    /// The heaviest counted day among the squares on screen.
    ///
    /// The cell bars are normalised against this rather than against the calorie
    /// target, because the grid has to work before targets are ever set and
    /// because "heavier than the rest of this month" is the comparison the month
    /// view is for. A verdict against a target is what the day card below gives,
    /// and giving it twice in two different visual languages would make the two
    /// look like different facts.
    ///
    /// Returns nil when nothing in view was logged, which the cells read as "draw
    /// no bars at all".
    static func heaviest(among slots: [MealCalendarSlot], readings: [Date: MealDayReading]) -> Double? {
        let values = slots.compactMap { slot -> Double? in
            guard let day = slot.day else { return nil }
            return reading(for: day, in: readings).calories
        }
        guard let top = values.max(), top > 0 else { return nil }
        return top
    }
}
