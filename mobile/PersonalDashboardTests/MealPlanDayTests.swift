import XCTest
import SwiftData
@testable import PersonalDashboard

/// What a day of planned meals adds up to, and what it deliberately leaves out
/// (#599).
///
/// The exclusions are the part worth pinning. Every one of them is a number that
/// would be wrong on screen without looking wrong: a skipped block folded into a
/// total makes a day read heavier than it is; a block with no numbers counted as
/// a zero makes a half-planned day read as a fast; an ingredient roll-up that
/// kept skipped blocks sends the user shopping for food they decided against.
@MainActor
final class MealPlanDayTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: MealPlanService!

    /// A fixed Wednesday, 10 September 2025.
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = MealPlanService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    @discardableResult
    private func plan(
        _ title: String,
        type: MealType = .lunch,
        on date: Date? = nil,
        ingredients: [String] = [],
        calories: Double? = nil,
        protein: Double = 0,
        status: MealPlanStatus = .planned
    ) throws -> LocalMealPlanEntry {
        try service.addEntry(
            date: date ?? day,
            mealType: type,
            title: title,
            ingredients: ingredients,
            status: status,
            nutrients: calories.map { MealNutrients(calories: $0, proteinG: protein) }
        )
    }

    private func today() throws -> MealPlanDay {
        MealPlanDay.onDay(day, in: try store.context.fetch(FetchDescriptor<LocalMealPlanEntry>()))
    }

    // MARK: - Order

    /// Reading order is the order of an actual day: meal type first, then slot
    /// index. Not insertion order, which is whatever the user happened to type.
    func testReadingOrderIsMealTypeThenSlot() throws {
        try plan("Second snack", type: .snack)
        try plan("Chicken rice", type: .lunch)
        try plan("Porridge", type: .breakfast)
        try plan("Laksa", type: .dinner)

        XCTAssertEqual(
            try today().all.map(\.title),
            ["Porridge", "Chicken rice", "Laksa", "Second snack"]
        )
    }

    /// Always four slots, in serving order, whether or not anything is in them.
    /// The panel renders the same skeleton on an empty day as on a full one.
    func testSlotsAreAlwaysFourInServingOrder() throws {
        try plan("Chicken rice", type: .lunch)
        let slots = try today().slots
        XCTAssertEqual(slots.map(\.mealType), [.breakfast, .lunch, .dinner, .snack])
        XCTAssertEqual(slots.filter(\.isEmpty).map(\.mealType), [.breakfast, .dinner, .snack])
    }

    // MARK: - Totals

    /// A skipped block leaves the totals entirely.
    func testSkippedBlocksLeaveTheTotals() throws {
        try plan("Porridge", type: .breakfast, calories: 350, protein: 12)
        try plan("Crisps", type: .snack, calories: 500, protein: 4, status: .skipped)

        let plan = try today()
        XCTAssertEqual(plan.totals.calories, 350)
        XCTAssertEqual(plan.skipped.count, 1)
        XCTAssertEqual(plan.counted.count, 1)
    }

    /// An eaten block still counts. It was the plan and it happened.
    func testEatenBlocksStillCount() throws {
        try plan("Porridge", type: .breakfast, calories: 350, status: .eaten)
        XCTAssertEqual(try today().totals.calories, 350)
    }

    /// A block with no numbers contributes nothing AND is reported, so the
    /// total is never printed as if it described the whole day.
    func testBlocksWithoutNumbersAreCountedSeparately() throws {
        try plan("Porridge", type: .breakfast, calories: 350)
        try plan("Lunch out with Dad", type: .lunch)
        try plan("Leftovers", type: .dinner)

        let plan = try today()
        XCTAssertEqual(plan.totals.calories, 350)
        XCTAssertEqual(plan.blocksWithNutrition, 1)
        XCTAssertEqual(plan.blocksWithoutNutrition, 2)
        XCTAssertFalse(plan.totalsAreComplete, "A total with two blocks missing from it needs its caveat.")
    }

    func testTotalsAreCompleteWhenEveryCountedBlockHasNumbers() throws {
        try plan("Porridge", type: .breakfast, calories: 350)
        try plan("Chicken rice", type: .lunch, calories: 620)
        // A skipped block with no numbers must not spoil the reading: it is not
        // counted at all, so there is nothing missing from the total.
        try plan("Crisps", type: .snack, status: .skipped)

        let plan = try today()
        XCTAssertTrue(plan.totalsAreComplete)
        XCTAssertEqual(plan.totals.calories, 970)
    }

    // MARK: - Empty

    /// A day of nothing but skipped blocks is NOT empty. It was planned and
    /// then abandoned, which is a different thing to look at from a blank day.
    func testDayOfSkippedBlocksIsNotEmpty() throws {
        try plan("Crisps", type: .snack, status: .skipped)
        let plan = try today()
        XCTAssertFalse(plan.isEmpty)
        XCTAssertFalse(plan.reading.isEmpty)
        XCTAssertEqual(plan.reading.counted, 0)
        XCTAssertEqual(plan.reading.skipped, 1)
    }

    // MARK: - Calendar readings

    /// The whole table is read in ONE pass, keyed by stored anchor, rather than
    /// re-scanned per square (#442).
    func testReadingsAreBuiltPerDay() throws {
        let calendar = Calendar.current
        try plan("Porridge", type: .breakfast)
        try plan("Chicken rice", type: .lunch)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        try plan("Toast", type: .breakfast, on: tomorrow, status: .skipped)

        let readings = MealPlanDay.readings(in: try store.context.fetch(FetchDescriptor<LocalMealPlanEntry>()))

        let todayReading = MealPlanDay.reading(for: day, in: readings)
        XCTAssertEqual(todayReading.counted, 2)
        XCTAssertEqual(todayReading.coveredTypes, [.breakfast, .lunch])
        XCTAssertFalse(todayReading.isComplete)

        let tomorrowReading = MealPlanDay.reading(for: tomorrow, in: readings)
        XCTAssertEqual(tomorrowReading.counted, 0)
        XCTAssertEqual(tomorrowReading.skipped, 1)

        let empty = MealPlanDay.reading(
            for: calendar.date(byAdding: .day, value: 5, to: day)!,
            in: readings
        )
        XCTAssertEqual(empty, .none)
        XCTAssertTrue(empty.isEmpty)
    }

    func testCompleteDayCoversAllFourTypes() throws {
        for type in MealType.allCases {
            try plan(type.displayName, type: type)
        }
        XCTAssertTrue(try today().reading.isComplete)
    }

    /// The spoken summary names what is MISSING, which is the actionable half.
    func testSpokenSummaryNamesTheGap() throws {
        try plan("Porridge", type: .breakfast)
        try plan("Chicken rice", type: .lunch)
        let spoken = MealPlanDayPips.spokenSummary(try today().reading)
        XCTAssertTrue(spoken.contains("no dinner or snack"), spoken)
    }

    // MARK: - Ingredients

    /// The count is a number of MEALS, and a block naming the same ingredient
    /// twice still wants it once.
    func testIngredientRollUpCountsBlocksNotMentions() throws {
        try plan("Rice bowl", type: .lunch, ingredients: ["chicken thigh", "rice", "Chicken thigh"])
        try plan("Stir fry", type: .dinner, ingredients: ["Chicken thigh", "cucumber"])

        let rolled = MealPlanDay.ingredients(in: try today().all)
        XCTAssertEqual(rolled.first?.name, "chicken thigh")
        XCTAssertEqual(rolled.first?.blocks, 2, "Two blocks want it, not three mentions.")
    }

    /// Most-wanted first, then the order they were first seen. Never
    /// dictionary order, which would reshuffle between launches.
    func testIngredientRollUpIsOrderedAndStable() throws {
        try plan("A", type: .breakfast, ingredients: ["eggs", "bread"])
        try plan("B", type: .lunch, ingredients: ["bread", "cheese"])
        try plan("C", type: .dinner, ingredients: ["bread"])

        let rolled = MealPlanDay.ingredients(in: try today().all)
        XCTAssertEqual(rolled.map(\.name), ["bread", "eggs", "cheese"])
        XCTAssertEqual(rolled.map(\.blocks), [3, 1, 1])
    }

    /// A meal that is not happening needs no shopping.
    func testSkippedBlocksLeaveTheIngredientRollUp() throws {
        try plan("Rice bowl", type: .lunch, ingredients: ["rice"])
        try plan("Crisps", type: .snack, ingredients: ["potatoes"], status: .skipped)

        let rolled = MealPlanDay.ingredients(in: try today().all)
        XCTAssertEqual(rolled.map(\.name), ["rice"])
    }

    /// The printed spelling is whichever form occurs most often, so the list
    /// reads back in the user's own words.
    func testIngredientRollUpPrintsTheCommonestSpelling() throws {
        try plan("A", type: .breakfast, ingredients: ["Eggs"])
        try plan("B", type: .lunch, ingredients: ["eggs"])
        try plan("C", type: .dinner, ingredients: ["eggs"])

        let rolled = MealPlanDay.ingredients(in: try today().all)
        XCTAssertEqual(rolled.map(\.name), ["eggs"])
    }

    // MARK: - Next slot

    /// One past the MAXIMUM, not the count, so a day whose middle block was
    /// deleted before renumbering still appends rather than colliding.
    func testNextSlotIndexIsOnePastTheMaximum() throws {
        try plan("Apple", type: .snack)
        try plan("Yoghurt", type: .snack)
        let plan = try today()
        XCTAssertEqual(plan.nextSlotIndex(for: .snack), 2)
        XCTAssertEqual(plan.nextSlotIndex(for: .breakfast), 0)
    }
}
