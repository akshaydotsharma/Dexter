import XCTest
import SwiftData
@testable import PersonalDashboard

/// The month grid, and where a deep link lands (#559, host moved in #565).
///
/// The grid moved from a History tab into a popover on Today, and these tests
/// came with it unchanged. That is the point of them: the arithmetic never
/// depended on which tab drew it, so a change of host should not cost a single
/// assertion. Only the deep-link tests moved with the rule they describe, from
/// two landing places to one.
///
/// ### Why this is pinned rather than eyeballed
///
/// Every way a calendar can be wrong is silent. A month that starts under the
/// wrong weekday column, a February that is 28 days long in a leap year, a
/// forward step that walks into a month nobody could have logged: none of them
/// look broken on a screenshot. The dates are simply wrong, and the user reads
/// the wrong day's meals without anything on screen saying so.
///
/// The cell reading is pinned for a different reason. A day with no meals and a
/// day whose meals all came to nothing are two different facts, and the grid is
/// the one surface that has to draw them apart in a square with no room for a
/// sentence. `MealDayCard` already says it in words; `MealDayReading` is that
/// same distinction made small enough to fit forty-two times.
@MainActor
final class MealsCalendarTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!

    /// A fixed calendar, so a grid is a grid and not "whatever the machine that
    /// ran the suite was set to". Monday-first and UTC, both stated rather than
    /// inherited.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        meals = MealService(store: store)
    }

    override func tearDown() {
        meals = nil
        store = nil
        super.tearDown()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)!
    }

    // MARK: - The grid

    /// A month that starts mid-week is padded to its column, and the grid is a
    /// whole number of weeks.
    ///
    /// September 2026 starts on a Tuesday, so with a Monday-first week there is
    /// exactly one blank square before the 1st.
    func testAMonthIsPaddedToItsStartingWeekdayAndToWholeWeeks() {
        let slots = MealCalendar.slots(forMonthOf: date(2026, 9, 15), calendar: calendar)

        XCTAssertEqual(slots.count % 7, 0, "The grid must be a rectangle of whole weeks.")

        let leading = slots.prefix { $0.day == nil }
        XCTAssertEqual(leading.count, 1, "September 2026 starts on a Tuesday, one column in.")

        let days = slots.compactMap(\.day)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first, date(2026, 9, 1))
        XCTAssertEqual(days.last, date(2026, 9, 30))
    }

    /// A month whose first day IS the first column takes no leading padding.
    ///
    /// June 2026 starts on a Monday. The off-by-one this catches is a modulo
    /// that returns 7 instead of 0 and pushes the whole month down a row.
    func testAMonthStartingOnTheFirstColumnTakesNoLeadingPadding() {
        let slots = MealCalendar.slots(forMonthOf: date(2026, 6, 10), calendar: calendar)
        XCTAssertNotNil(slots.first?.day, "June 2026 starts on a Monday; nothing precedes it.")
        XCTAssertEqual(slots.first?.day, date(2026, 6, 1))
        XCTAssertEqual(slots.count, 35, "30 days from column one fill five weeks exactly.")
    }

    /// A leap February is 29 days, and a common February is 28.
    ///
    /// 2024 is a leap year, 2026 is not, and 2100 is the century that is not,
    /// which is the case a naive divide-by-four gets wrong.
    func testFebruaryIsTwentyNineDaysOnlyInALeapYear() {
        XCTAssertEqual(
            MealCalendar.slots(forMonthOf: date(2024, 2, 5), calendar: calendar).compactMap(\.day).count,
            29
        )
        XCTAssertEqual(
            MealCalendar.slots(forMonthOf: date(2026, 2, 5), calendar: calendar).compactMap(\.day).count,
            28
        )
        XCTAssertEqual(
            MealCalendar.slots(forMonthOf: date(2100, 2, 5), calendar: calendar).compactMap(\.day).count,
            28,
            "2100 is divisible by four and is not a leap year."
        )
    }

    /// Every day of the month appears exactly once, in order, with no gaps.
    func testEveryDayOfTheMonthAppearsOnceInOrder() {
        let days = MealCalendar.slots(forMonthOf: date(2026, 1, 20), calendar: calendar).compactMap(\.day)
        XCTAssertEqual(days.count, 31)
        XCTAssertEqual(Set(days).count, 31, "No day is repeated.")
        XCTAssertEqual(days, days.sorted(), "The grid reads in date order.")
        for (offset, day) in days.enumerated() {
            XCTAssertEqual(day, date(2026, 1, offset + 1))
        }
    }

    /// A December grid does not spill into the next year, and a January grid
    /// does not borrow from the last one.
    func testTheGridDoesNotCrossAYearBoundary() {
        let december = MealCalendar.slots(forMonthOf: date(2026, 12, 3), calendar: calendar).compactMap(\.day)
        XCTAssertEqual(december.last, date(2026, 12, 31))

        let january = MealCalendar.slots(forMonthOf: date(2027, 1, 3), calendar: calendar).compactMap(\.day)
        XCTAssertEqual(january.first, date(2027, 1, 1))
    }

    // MARK: - What can be reached

    /// Today is selectable and tomorrow is not.
    ///
    /// The comparison is a DAY comparison: "today" late in the evening must stay
    /// selectable, which an instant comparison against `Date()` would refuse.
    func testAFutureDayCannotBeSelected() {
        let today = date(2026, 9, 15)
        let lateToday = calendar.date(byAdding: .hour, value: 23, to: today)!

        XCTAssertTrue(MealCalendar.isSelectable(today, today: today, calendar: calendar))
        XCTAssertTrue(
            MealCalendar.isSelectable(lateToday, today: today, calendar: calendar),
            "23:00 today is still today."
        )
        XCTAssertTrue(MealCalendar.isSelectable(date(2026, 9, 14), today: today, calendar: calendar))
        XCTAssertTrue(MealCalendar.isSelectable(date(2019, 3, 2), today: today, calendar: calendar))

        XCTAssertFalse(MealCalendar.isSelectable(date(2026, 9, 16), today: today, calendar: calendar))
        XCTAssertFalse(MealCalendar.isSelectable(date(2026, 10, 1), today: today, calendar: calendar))
    }

    /// Forward stops at the current month. Backward has no limit at all, so a
    /// gap in the log can never trap the user.
    func testMonthStepsGoBackForeverAndStopAtTheCurrentMonth() {
        let today = date(2026, 9, 15)
        let september = MealCalendar.monthStart(of: today, calendar: calendar)

        XCTAssertFalse(MealCalendar.canStepForward(from: september, today: today, calendar: calendar))
        XCTAssertEqual(
            MealCalendar.step(september, byMonths: 1, today: today, calendar: calendar),
            september,
            "A forward step from the current month is a no-op, not a jump into October."
        )

        let august = MealCalendar.step(september, byMonths: -1, today: today, calendar: calendar)
        XCTAssertEqual(august, date(2026, 8, 1))
        XCTAssertTrue(MealCalendar.canStepForward(from: august, today: today, calendar: calendar))

        // Backwards across a year boundary, and a long way back.
        let january = MealCalendar.step(date(2026, 2, 1), byMonths: -1, today: today, calendar: calendar)
        XCTAssertEqual(january, date(2026, 1, 1))
        XCTAssertEqual(
            MealCalendar.step(september, byMonths: -120, today: today, calendar: calendar),
            date(2016, 9, 1)
        )
    }

    /// A step that would overshoot the current month is clamped to it rather
    /// than refused, so a caller cannot land the grid in the future.
    func testAForwardStepIsClampedToTheCurrentMonth() {
        let today = date(2026, 9, 15)
        XCTAssertEqual(
            MealCalendar.step(date(2026, 7, 1), byMonths: 6, today: today, calendar: calendar),
            date(2026, 9, 1)
        )
    }

    // MARK: - What a cell says

    /// The three states a square can be in, and the two that must never look
    /// alike: a day nobody logged, and a logged day that came to nothing.
    func testACellTellsUnloggedApartFromZeroCalories() throws {
        let logged = Date(timeIntervalSince1970: 1_757_462_400)
        let allSuspect = Calendar.current.date(byAdding: .day, value: -1, to: logged)!
        let untouched = Calendar.current.date(byAdding: .day, value: -2, to: logged)!

        try log("Chicken rice", on: logged, calories: 600)
        // A day whose only meal is held out of the totals. It IS logged, and its
        // counted total is zero.
        try log("A suspiciously large salad", on: allSuspect, calories: 4000, suspect: true)

        let readings = MealCalendar.readings(in: try everyMeal())

        XCTAssertEqual(MealCalendar.reading(for: logged, in: readings), .logged(calories: 600))

        let held = MealCalendar.reading(for: allSuspect, in: readings)
        XCTAssertEqual(held, .logged(calories: 0))
        XCTAssertTrue(held.isLogged, "A day whose meals are all held back is still a logged day.")
        XCTAssertEqual(held.calories, 0)

        let blank = MealCalendar.reading(for: untouched, in: readings)
        XCTAssertEqual(blank, .unlogged)
        XCTAssertFalse(blank.isLogged)
        XCTAssertNil(blank.calories, "An absence is nil, never zero: it must not average into anything.")

        XCTAssertNotEqual(held, blank, "Zero and not-logged are two different readings.")
    }

    /// The cell figure is the same figure the day card draws, exclusions and all.
    ///
    /// A cell that summed its own rows would fold a suspect meal back in, print a
    /// larger number than the card it opens, and nothing on either surface would
    /// say which of the two was right.
    func testTheCellFigureMatchesTheDayCardForTheSameDay() throws {
        let day = Date(timeIntervalSince1970: 1_757_462_400)
        try log("Overnight oats", on: day, calories: 420, type: .breakfast)
        try log("Chicken rice", on: day, calories: 600, type: .lunch)
        try log("A suspiciously large salad", on: day, calories: 4000, type: .dinner, suspect: true)
        try log("rice", on: day, calories: 0, type: .snack, needsDetail: true)

        let all = try everyMeal()
        let card = MealDaySummary.onDay(day, in: all)
        let cell = MealCalendar.reading(for: day, in: MealCalendar.readings(in: all))

        XCTAssertEqual(cell.calories, card.totals.calories)
        XCTAssertEqual(cell.calories, 1020, "The two good meals and only those.")
    }

    /// The bar scale is the heaviest day among the squares on screen, and it is
    /// nil when nothing in view was logged, which the cells read as "draw no bars".
    func testTheBarScaleIsTheHeaviestDayInView() throws {
        let day = Date(timeIntervalSince1970: 1_757_462_400)
        let lighter = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        try log("Chicken rice", on: day, calories: 1800)
        try log("Toast", on: lighter, calories: 300)

        let readings = MealCalendar.readings(in: try everyMeal())
        let slots = MealCalendar.slots(forMonthOf: day, calendar: Calendar.current)

        XCTAssertEqual(MealCalendar.heaviest(among: slots, readings: readings), 1800)

        // A month with nothing in it has no scale at all.
        let empty = MealCalendar.slots(
            forMonthOf: Calendar.current.date(byAdding: .year, value: -3, to: day)!,
            calendar: Calendar.current
        )
        XCTAssertNil(MealCalendar.heaviest(among: empty, readings: readings))
    }

    // MARK: - Where a deep link lands

    /// Every meal lands on Tracking, whatever day it was logged on (#565).
    ///
    /// This was the two-armed routing test #559 needed, back when the first tab
    /// could only show today and anything older had to go to a second one. It
    /// reaches any day again, so the branch is gone, and what is worth pinning is
    /// that it STAYS gone: a meal from an earlier year must not acquire a second
    /// landing place.
    func testEveryDeepLinkLandsOnTrackingWhicheverDayTheMealIsOn() {
        XCTAssertEqual(MealsView.landing(forMealOn: date(2026, 9, 15), calendar: calendar).tab, .tracking)
        XCTAssertEqual(MealsView.landing(forMealOn: date(2026, 9, 14), calendar: calendar).tab, .tracking)
        XCTAssertEqual(
            MealsView.landing(forMealOn: date(2025, 12, 31), calendar: calendar).tab,
            .tracking,
            "A meal in an earlier year lands on the same tab as one from this morning."
        )
    }

    /// The landing normalises to the day, so an evening meal selects its own day
    /// rather than an instant that formats as the next one.
    func testTheLandingSelectsTheMealsOwnDay() {
        let day = date(2026, 3, 7)
        let evening = calendar.date(byAdding: .hour, value: 21, to: day)!

        let landing = MealsView.landing(forMealOn: evening, calendar: calendar)
        XCTAssertEqual(landing.day, day, "An evening meal belongs to the day it was eaten on.")
        XCTAssertEqual(landing.month, date(2026, 3, 1))
    }

    /// The popover opens on the month holding the day the link selected, which is
    /// how a link to an earlier month becomes reachable at all.
    func testADeepLinkToAnEarlierMonthOpensTheGridOnThatMonth() {
        let landing = MealsView.landing(forMealOn: date(2026, 3, 7), calendar: calendar)
        XCTAssertEqual(landing.month, date(2026, 3, 1))
        XCTAssertTrue(
            MealCalendar.slots(forMonthOf: landing.month, calendar: calendar)
                .compactMap(\.day)
                .contains(landing.day)
        )
    }

    /// The four tabs, in the order the strip prints them (#567, renamed #569,
    /// Trends added #545).
    ///
    /// Trends is a PLACE the content can be: a window, a table and a chart you
    /// settle in front of. That is what earns a tab. History was not, which is
    /// why #567 moved it into the section chrome and #569 removed it; a
    /// navigation control reappearing here would undo both.
    ///
    /// Trends sits second, directly after Tracking, because the two are the same
    /// subject at two lengths: one day, then many. Targets stays last, because it
    /// is setup rather than reading.
    ///
    /// The first tab is Tracking, not Today. It shows whichever day the date
    /// control selected, so a name meaning one particular day was a label
    /// contradicting its own content. Asserting the display string and not only
    /// the case is the point: the case could be renamed and the strip could still
    /// print the old word.
    func testTheTabOrderIsTrackingTrendsPlanTargets() {
        XCTAssertEqual(MealsTab.allCases, [.tracking, .trends, .plan, .targets])
        XCTAssertEqual(
            MealsTab.allCases.map(\.displayName),
            ["Tracking", "Trends", "Plan", "Targets"]
        )
    }

    // MARK: - Fixtures

    @discardableResult
    private func log(
        _ description: String,
        on when: Date,
        calories: Double = 500,
        type: MealType = .lunch,
        suspect: Bool = false,
        needsDetail: Bool = false
    ) throws -> LocalMeal {
        try meals.addMeal(
            date: when,
            loggedAt: when,
            mealType: type,
            mealDescription: description,
            nutrients: MealNutrients(
                calories: calories, proteinG: 25, carbsG: 50, fatG: 20, fibreG: 4
            ),
            confidence: 0.6,
            source: MealSource.composer,
            needsDetail: needsDetail,
            isSuspect: suspect,
            suspectReason: suspect ? "The macros do not add up." : nil
        )
    }

    /// Every meal in the store, which is what the section's `@Query` hands the grid.
    private func everyMeal() throws -> [LocalMeal] {
        try store.context.fetch(
            FetchDescriptor<LocalMeal>(
                sortBy: [
                    SortDescriptor(\.date, order: .forward),
                    SortDescriptor(\.loggedAt, order: .forward)
                ]
            )
        )
    }
}
