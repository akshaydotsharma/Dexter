import XCTest
import SwiftData
@testable import PersonalDashboard

/// Logging a planned meal from the plan (#612).
///
/// The property under test is that a tick costs NO estimate and cannot cost a
/// duplicate. Both failures are silent: a second call would just be money, and
/// a second row would sit in a day's totals looking exactly like a meal the
/// user logged twice on purpose.
@MainActor
final class MealPlanLoggingTests: XCTestCase {

    private var store: SwiftDataStore!
    private var plans: MealPlanService!
    private var meals: MealService!

    /// Thursday 17 September 2026, midday device-local.
    private let today = Date(timeIntervalSince1970: 1_789_560_000)

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        plans = MealPlanService(store: store)
        meals = MealService(store: store)
    }

    override func tearDown() {
        meals = nil
        plans = nil
        store = nil
        super.tearDown()
    }

    @discardableResult
    private func block(
        on day: Date? = nil,
        type: MealType = .dinner,
        title: String = "Chicken rice with cucumber and chilli sauce on the side",
        shortTitle: String? = "Chicken rice",
        nutrients: MealNutrients? = MealNutrients(
            calories: 620, proteinG: 34, carbsG: 78, fatG: 18,
            fibreG: 4, sugarG: 6, sodiumMg: 1_100, satFatG: 5
        )
    ) throws -> LocalMealPlanEntry {
        try plans.addEntry(
            date: day ?? today,
            mealType: type,
            title: title,
            shortTitle: shortTitle,
            nutrients: nutrients,
            items: [MealItemEntry(name: "Chicken rice", portionQuantity: 450, portionUnit: "g", calories: 620)]
        )
    }

    private func loggedMeals() throws -> [LocalMeal] {
        try store.context.fetch(FetchDescriptor<LocalMeal>())
    }

    // MARK: - The copy

    func testTickingABlockWritesOneMealOnItsOwnDayAndType() throws {
        let entry = try block()
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)

        XCTAssertEqual(try loggedMeals().count, 1)
        XCTAssertEqual(meal.mealTypeEnum, .dinner)
        XCTAssertTrue(Calendar.current.isDate(meal.deviceDay, inSameDayAs: today))
        XCTAssertEqual(meal.calories, 620)
        XCTAssertEqual(meal.proteinG, 34)
        XCTAssertEqual(meal.items.count, 1)
        XCTAssertEqual(meal.source, MealSource.plan)
        XCTAssertFalse(meal.needsDetail)
    }

    /// The user's own words stay the description; the block's short name comes
    /// across as the meal's name, so the row reads the same in both places with
    /// no naming pass (#603).
    func testTheMealKeepsBothHalvesOfTheBlocksText() throws {
        let entry = try block()
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)

        XCTAssertEqual(meal.mealDescription, entry.title)
        XCTAssertEqual(meal.title, "Chicken rice")
        XCTAssertEqual(MealDisplayName.short(for: meal), "Chicken rice")
    }

    func testTheBlockRecordsWhatItWroteAndBecomesEaten() throws {
        let entry = try block()
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)

        XCTAssertEqual(entry.loggedMealUUID, meal.clientUUID)
        XCTAssertEqual(entry.statusEnum, .eaten)
        XCTAssertEqual(try plans.loggedMeal(for: entry)?.clientUUID, meal.clientUUID)
    }

    /// The block stays. A plan is what was intended and a meal is what
    /// happened, and a day is read for both.
    func testTheBlockSurvivesBeingLogged() throws {
        let entry = try block()
        try plans.logAsMeal(entry, meals: meals, now: today)
        XCTAssertEqual(try plans.entries(on: today).count, 1)
    }

    // MARK: - Twice is once

    func testASecondTickReturnsTheSameMealRatherThanLoggingTwice() throws {
        let entry = try block()
        let first = try plans.logAsMeal(entry, meals: meals, now: today)
        let second = try plans.logAsMeal(entry, meals: meals, now: today)

        XCTAssertEqual(first.clientUUID, second.clientUUID)
        XCTAssertEqual(try loggedMeals().count, 1)
    }

    // MARK: - Unticking

    func testUntickingDeletesTheMealAndPlansTheBlockAgain() throws {
        let entry = try block()
        try plans.logAsMeal(entry, meals: meals, now: today)
        try plans.unlogAsMeal(entry, meals: meals)

        XCTAssertTrue(try loggedMeals().isEmpty)
        XCTAssertNil(entry.loggedMealUUID)
        XCTAssertEqual(entry.statusEnum, .planned)
    }

    /// A meal the user logged by hand is not this block's to remove. This is
    /// the whole reason the link is stored rather than matched on day and type.
    func testUntickingLeavesAMealTheUserLoggedThemselves() throws {
        let mine = try meals.addMeal(
            date: today, loggedAt: today, mealType: .dinner,
            mealDescription: "Chicken rice", source: MealSource.composer
        )
        let entry = try block()
        try plans.logAsMeal(entry, meals: meals, now: today)
        XCTAssertEqual(try loggedMeals().count, 2)

        try plans.unlogAsMeal(entry, meals: meals)
        let left = try loggedMeals()
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.clientUUID, mine.clientUUID)
    }

    /// A meal deleted from Tracking leaves the id behind on the block. Reading
    /// the id alone would draw a tick for a row that is not there.
    func testAMealDeletedOnTrackingReadsAsNotLogged() throws {
        let entry = try block()
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)
        try meals.deleteMeal(meal)

        XCTAssertNil(try plans.loggedMeal(for: entry))
    }

    /// Deleting the plan does NOT delete the meal: no edit to a plan can make
    /// it untrue that something was eaten.
    func testDeletingTheBlockLeavesTheMealAlone() throws {
        let entry = try block()
        try plans.logAsMeal(entry, meals: meals, now: today)
        try plans.deleteEntry(entry)

        XCTAssertEqual(try loggedMeals().count, 1)
    }

    // MARK: - The awkward blocks

    /// Losing the fact that you ate is worse than losing the number.
    func testABlockWithNoNumbersStillLogsAndAsksForDetail() throws {
        let entry = try block(nutrients: nil)
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)

        XCTAssertTrue(meal.needsDetail)
        XCTAssertEqual(meal.calories, 0)
        XCTAssertEqual(meal.confidence, 0)
    }

    /// A meal is a record of something already eaten.
    func testABlockPlannedForALaterDayCannotBeLogged() throws {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let entry = try block(on: tomorrow)
        XCTAssertFalse(MealPlanService.canLog(entry, now: today))
        XCTAssertTrue(MealPlanService.canLog(try block(), now: today))
    }

    /// An earlier day is stamped at the hour that meal is eaten, not at "now".
    /// The same rule the composer works to for a retrospective log (#592).
    func testAnEarlierDayIsStampedAtItsOwnMealHour() throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let entry = try block(on: yesterday, type: .breakfast)
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)

        let hour = Calendar.current.component(.hour, from: meal.loggedAt)
        XCTAssertEqual(hour, 8)
        XCTAssertTrue(Calendar.current.isDate(meal.deviceDay, inSameDayAs: yesterday))
    }

    func testTodayIsStampedAtTheRealTime() throws {
        let entry = try block()
        let meal = try plans.logAsMeal(entry, meals: meals, now: today)
        XCTAssertEqual(meal.loggedAt.timeIntervalSince1970, today.timeIntervalSince1970, accuracy: 1)
    }
}
