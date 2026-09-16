import XCTest
@testable import PersonalDashboard

/// The Plan tab's grid arithmetic (#599).
///
/// Every failure this pins is SILENT. A week that starts on the wrong day, a
/// February that loses its 29th, a step that lands in the wrong month: nothing
/// on screen looks broken, the dates are simply wrong, and a plan written
/// against a wrong date is invisible until the day arrives.
///
/// The load-bearing one is the stepping group. The Tracking calendar refuses a
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

    private func date(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
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

    func testStepsGoBackwardsToo() {
        let calendar = mondayFirst
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
