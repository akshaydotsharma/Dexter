import XCTest
@testable import PersonalDashboard

/// The Plan tab's grid arithmetic (#599).
///
/// Every failure this pins is SILENT. A week that starts on the wrong day, a
/// February that loses its 29th, a step that lands in the wrong month: nothing
/// on screen looks broken, the dates are simply wrong, and a plan written
/// against a wrong date is invisible until the day arrives.
///
/// The load-bearing one is the last group. The Tracking calendar refuses a
/// future day on purpose; a plan that inherited that rule would be a planner
/// that cannot plan.
final class MealPlanCalendarTests: XCTestCase {

    /// Monday-first, which is what makes the week arithmetic assertable at all:
    /// `Calendar.current.firstWeekday` depends on the device's locale, so a
    /// test that used it would pass or fail by region.
    private var mondayFirst: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private var sundayFirst: Calendar {
        var calendar = mondayFirst
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Weeks

    /// Wednesday 10 September 2025 sits in the week beginning Monday the 8th.
    func testWeekStartHonoursFirstWeekday() {
        let calendar = mondayFirst
        let wednesday = date(2025, 9, 10, calendar)
        XCTAssertEqual(
            MealPlanCalendar.weekStart(of: wednesday, calendar: calendar),
            date(2025, 9, 8, calendar)
        )
    }

    /// The same Wednesday, in a Sunday-first locale, begins its week on the 7th.
    /// Hard-coding Monday would put the whole strip one day out for half the
    /// world.
    func testWeekStartFollowsTheLocalesFirstWeekday() {
        let calendar = sundayFirst
        let wednesday = date(2025, 9, 10, calendar)
        XCTAssertEqual(
            MealPlanCalendar.weekStart(of: wednesday, calendar: calendar),
            date(2025, 9, 7, calendar)
        )
    }

    /// A day that IS the first of its week starts that week, rather than being
    /// pushed back seven days by an off-by-one.
    func testWeekStartOfTheFirstDayIsItself() {
        let calendar = mondayFirst
        let monday = date(2025, 9, 8, calendar)
        XCTAssertEqual(MealPlanCalendar.weekStart(of: monday, calendar: calendar), monday)
    }

    func testWeekDaysAreSevenConsecutiveDays() {
        let calendar = mondayFirst
        let days = MealPlanCalendar.weekDays(of: date(2025, 9, 10, calendar), calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, date(2025, 9, 8, calendar))
        XCTAssertEqual(days.last, date(2025, 9, 14, calendar))
    }

    /// A week that straddles a month boundary stays seven consecutive days.
    func testWeekDaysCrossAMonthBoundary() {
        let calendar = mondayFirst
        let days = MealPlanCalendar.weekDays(of: date(2025, 10, 1, calendar), calendar: calendar)
        XCTAssertEqual(days.first, date(2025, 9, 29, calendar))
        XCTAssertEqual(days.last, date(2025, 10, 5, calendar))
    }

    // MARK: - Stepping

    /// Forward is never clamped. This is the rule that separates a plan from a
    /// log: `MealCalendar.canStepForward` stops at the current month, and this
    /// one must not.
    func testMonthStepsForwardWithoutLimit() {
        let calendar = mondayFirst
        let thisMonth = MealPlanCalendar.monthStart(of: date(2025, 9, 10, calendar), calendar: calendar)
        let ahead = MealPlanCalendar.stepMonth(thisMonth, by: 6, calendar: calendar)
        XCTAssertEqual(ahead, date(2026, 3, 1, calendar), "A plan must reach months that have not happened.")
    }

    func testWeekStepsForwardWithoutLimit() {
        let calendar = mondayFirst
        let week = MealPlanCalendar.weekStart(of: date(2025, 9, 10, calendar), calendar: calendar)
        XCTAssertEqual(
            MealPlanCalendar.stepWeek(week, by: 3, calendar: calendar),
            date(2025, 9, 29, calendar)
        )
    }

    func testStepsGoBackwardsToo() {
        let calendar = mondayFirst
        let week = MealPlanCalendar.weekStart(of: date(2025, 9, 10, calendar), calendar: calendar)
        XCTAssertEqual(
            MealPlanCalendar.stepWeek(week, by: -2, calendar: calendar),
            date(2025, 8, 25, calendar)
        )
        let month = MealPlanCalendar.monthStart(of: date(2025, 1, 15, calendar), calendar: calendar)
        XCTAssertEqual(
            MealPlanCalendar.stepMonth(month, by: -1, calendar: calendar),
            date(2024, 12, 1, calendar)
        )
    }

    /// Stepping from a 31-day month into a 30-day one lands on the first of the
    /// target month, not on a rolled-over date in the month after it.
    func testMonthStepFromALongMonthLandsOnTheFirst() {
        let calendar = mondayFirst
        let january = MealPlanCalendar.monthStart(of: date(2025, 1, 31, calendar), calendar: calendar)
        XCTAssertEqual(
            MealPlanCalendar.stepMonth(january, by: 1, calendar: calendar),
            date(2025, 2, 1, calendar)
        )
    }

    // MARK: - Ranges

    func testWeekRangeIsTheSevenDaysInclusive() {
        let calendar = mondayFirst
        let range = MealPlanCalendar.range(for: .week, containing: date(2025, 9, 10, calendar), calendar: calendar)
        XCTAssertEqual(range.start, date(2025, 9, 8, calendar))
        XCTAssertEqual(range.end, date(2025, 9, 14, calendar))
    }

    /// The end is the LAST day of the month and is inside the range. A month
    /// range that stopped at the first of the next month would either double
    /// count a day or drop one, depending on which way the caller read it.
    func testMonthRangeEndsOnTheLastDayOfTheMonth() {
        let calendar = mondayFirst
        let range = MealPlanCalendar.range(for: .month, containing: date(2025, 9, 10, calendar), calendar: calendar)
        XCTAssertEqual(range.start, date(2025, 9, 1, calendar))
        XCTAssertEqual(range.end, date(2025, 9, 30, calendar))
    }

    /// February in a leap year has 29 days, and the range has to reach the 29th.
    func testMonthRangeHandlesALeapFebruary() {
        let calendar = mondayFirst
        let range = MealPlanCalendar.range(for: .month, containing: date(2024, 2, 5, calendar), calendar: calendar)
        XCTAssertEqual(range.end, date(2024, 2, 29, calendar))
    }

    // MARK: - Month slots

    /// The grid is always a rectangle, so the content below it does not move as
    /// the months are stepped through.
    func testMonthSlotsArePaddedToWholeWeeks() {
        let calendar = mondayFirst
        for month in 1...12 {
            let slots = MealPlanCalendar.monthSlots(
                forMonthOf: date(2025, month, 1, calendar),
                calendar: calendar
            )
            XCTAssertEqual(slots.count % 7, 0, "Month \(month) is not a whole number of weeks.")
            XCTAssertFalse(slots.isEmpty)
        }
    }

    func testMonthSlotsHoldEveryDayOfTheMonth() {
        let calendar = mondayFirst
        let slots = MealPlanCalendar.monthSlots(forMonthOf: date(2024, 2, 1, calendar), calendar: calendar)
        XCTAssertEqual(slots.compactMap(\.day).count, 29, "A leap February has 29 squares.")
    }
}
