import XCTest
import SwiftData
@testable import PersonalDashboard

/// The day's arithmetic, and the three correction paths that cost no API call
/// (#543).
///
/// Everything here runs against a real in-memory store and a real
/// `MealService`, the same way `MealDataLayerTests` does, so a change to the
/// service's own rules shows up here rather than being mocked away.
@MainActor
final class MealDayTotalsTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!
    private var service: MealEstimationService!

    /// A fixed instant so a day is a day and not "whenever the suite ran".
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        meals = MealService(store: store)
        service = MealEstimationService(meals: meals)
    }

    override func tearDown() {
        service = nil
        meals = nil
        store = nil
        super.tearDown()
    }

    @discardableResult
    private func log(
        _ description: String,
        calories: Double = 500,
        protein: Double = 25,
        type: MealType = .lunch,
        suspect: Bool = false,
        needsDetail: Bool = false,
        source: String = MealSource.composer,
        items: [MealItemEntry] = []
    ) throws -> LocalMeal {
        try meals.addMeal(
            date: day,
            loggedAt: day,
            mealType: type,
            mealDescription: description,
            nutrients: MealNutrients(calories: calories, proteinG: protein, carbsG: 50, fatG: 20),
            items: items,
            confidence: 0.6,
            source: source,
            needsDetail: needsDetail,
            isSuspect: suspect,
            suspectReason: suspect ? "The macros do not add up." : nil
        )
    }

    // MARK: - What counts

    func testASuspectMealIsExcludedFromTheDayTotals() throws {
        try log("Chicken rice", calories: 600)
        try log("A suspiciously large salad", calories: 4000, suspect: true)

        let summary = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(summary.totals.calories, 600, accuracy: 0.0001)
        XCTAssertEqual(summary.counted.count, 1)
        XCTAssertEqual(summary.excluded.count, 1)
        // Still stored, still visible. Losing the fact that you ate is worse
        // than losing the number.
        XCTAssertEqual(summary.all.count, 2)
    }

    func testANeedsDetailMealIsExcludedFromTheDayTotals() throws {
        try log("Lunch", calories: 700)
        try log("something", calories: 0, protein: 0, needsDetail: true)

        let summary = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(summary.totals.calories, 700, accuracy: 0.0001)
        XCTAssertEqual(summary.counted.count, 1)
        XCTAssertEqual(summary.excluded.count, 1)
    }

    /// A day nobody logged is not a day of nothing, and the card has to be able
    /// to tell the two apart.
    func testAnUnloggedDayIsDistinctFromALowCalorieDay() throws {
        let empty = MealDaySummary(meals: [])
        XCTAssertTrue(empty.isUnlogged)

        try log("An apple", calories: 80, protein: 0)
        let light = MealDaySummary(meals: try meals.meals(on: day))
        XCTAssertFalse(light.isUnlogged)
        XCTAssertEqual(light.totals.calories, 80, accuracy: 0.0001)
    }

    /// Everything needing attention reads first, because those rows are the only
    /// ones with an action attached.
    func testFlaggedRowsArePinnedAboveTheRest() throws {
        let ok = try log("Chicken rice", type: .lunch)
        let bad = try log("Mystery bowl", type: .dinner, suspect: true)

        let summary = MealDaySummary(meals: try meals.meals(on: day))
        let rows = summary.orderedRows(flaggedAsDuplicate: [])

        XCTAssertEqual(rows.first?.clientUUID, bad.clientUUID)
        XCTAssertEqual(rows.last?.clientUUID, ok.clientUUID)
    }

    func testADuplicateFlaggedRowIsAlsoPinned() throws {
        let ok = try log("Chicken rice", type: .lunch)
        let flagged = try log("Flat white", type: .breakfast)

        let summary = MealDaySummary(meals: try meals.meals(on: day))
        let rows = summary.orderedRows(flaggedAsDuplicate: [flagged.clientUUID])

        XCTAssertEqual(rows.first?.clientUUID, flagged.clientUUID)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.clientUUID, ok.clientUUID)
    }

    /// A meal whose ONLY failure is a clamp still contributes to the day.
    ///
    /// This is the assertion that pins the repair/invalidation split end to end,
    /// through the guards, through the write, and into the day's arithmetic. A
    /// clamp leaves the numbers coherent; treating it as a flag would take a real
    /// 600 kcal lunch out of the total over a gram of sugar, and a day card that
    /// under-counts without saying so is worse than the slip it was guarding
    /// against.
    func testAClampedMealStillCountsTowardTheDayTotal() throws {
        // Sugar 40 g against carbs 15 g: one repair and nothing else. The
        // calories agree with 4P + 4C + 9F, so the consistency check stays out.
        let estimate = EstimatedMeal(
            mealType: "lunch",
            items: [
                EstimatedMealItem(
                    name: "Yoghurt pot",
                    portionQuantity: 400, portionUnit: "g",
                    calories: 600, proteinG: 40, carbsG: 50, fatG: 26.7,
                    fibreG: 2, sugarG: 80, sodiumMg: 300, satFatG: 6
                )
            ],
            containsAlcohol: false,
            confidence: "medium",
            assumptions: "Assumed a large pot."
        )
        let result = MealEstimateGuards.check(estimate, fallbackMealType: .lunch)

        // Precondition: a repair, and nothing that invalidates.
        XCTAssertEqual(result.repairs.count, 1)
        XCTAssertTrue(result.invalidatingFailures.isEmpty, "got \(result.invalidatingFailures)")
        XCTAssertFalse(result.isSuspect)

        try service.save(result, description: "A big yoghurt pot", day: day, loggedAt: day)
        try log("Chicken rice", calories: 500)

        let summary = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(summary.counted.count, 2)
        XCTAssertTrue(summary.excluded.isEmpty)
        XCTAssertEqual(summary.totals.calories, 1100, accuracy: 0.0001)
        // The clamped value is what was stored, and it is what counted: the
        // yoghurt's sugar came back as 80 g and went in as its own 50 g of
        // carbs. The other meal carries no sugar, so the day is that 50.
        XCTAssertEqual(summary.totals.sugarG, 50, accuracy: 0.0001)

        // And the repair is still on the row, at the front of the note, so it is
        // the half that survives a one-line truncation.
        let stored = try XCTUnwrap(summary.counted.first { $0.mealDescription == "A big yoghurt pot" })
        XCTAssertNil(stored.suspectReason)
        XCTAssertTrue(
            stored.assumptionsNote?.hasPrefix("Sugar (80 g) exceeded total carbs") == true,
            "got \(stored.assumptionsNote ?? "nil")"
        )
    }

    /// The other half of the same rule: an INVALIDATING failure still leaves the
    /// meal out.
    func testAnInvalidatedMealStillLeavesTheDayTotal() throws {
        let estimate = EstimatedMeal(
            mealType: "lunch",
            items: [
                EstimatedMealItem(
                    name: "Mystery bowl",
                    portionQuantity: 300, portionUnit: "g",
                    calories: 900, proteinG: 10, carbsG: 15, fatG: 10,
                    fibreG: 1, sugarG: 3, sodiumMg: 200, satFatG: 2
                )
            ],
            containsAlcohol: false,
            confidence: "low"
        )
        let result = MealEstimateGuards.check(estimate, fallbackMealType: .lunch)
        XCTAssertTrue(result.isSuspect)

        try service.save(result, description: "Mystery bowl", day: day, loggedAt: day)
        try log("Chicken rice", calories: 500)

        let summary = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(summary.totals.calories, 500, accuracy: 0.0001)
        XCTAssertEqual(summary.excluded.count, 1)
    }

    // MARK: - Rounding

    /// Calories round to the nearest 10 and macros to the gram. Printing 343
    /// kcal from "two eggs on toast" claims a precision the estimate does not
    /// have, and false precision is the fastest way to stop trusting a tool that
    /// is approximate by construction.
    func testCaloriesRoundToTheNearestTen() {
        XCTAssertEqual(MealFormat.calories(343), "340")
        XCTAssertEqual(MealFormat.calories(347), "350")
        XCTAssertEqual(MealFormat.calories(0), "0")
        XCTAssertEqual(MealFormat.grams(12.4), "12")
        XCTAssertEqual(MealFormat.value(1899.6, for: .sodium), "1900 mg")
    }

    // MARK: - Repeat

    func testRepeatInsertsACopyDatedTodayWithNoCall() throws {
        let original = try log("Overnight oats", calories: 420, type: .breakfast)

        let copy = try service.repeatMeal(original)

        XCTAssertNotEqual(copy.clientUUID, original.clientUUID)
        XCTAssertEqual(copy.mealDescription, original.mealDescription)
        XCTAssertEqual(copy.calories, original.calories, accuracy: 0.0001)
        XCTAssertEqual(copy.mealTypeEnum, .breakfast)
        XCTAssertTrue(WallClock.isSameStoredDay(copy.date, WallClock.dayAnchor(from: Date())))
        // The numbers were copied, not estimated, and the row says so.
        XCTAssertEqual(copy.source, MealSource.repeated)
        XCTAssertEqual(try meals.meals(on: day).count, 1)
    }

    /// A repeat of a meal whose numbers were wrong is a meal whose numbers are
    /// still wrong, so the flag rides along.
    func testRepeatCarriesTheSuspectFlag() throws {
        let original = try log("Mystery bowl", suspect: true)

        let copy = try service.repeatMeal(original)

        XCTAssertTrue(copy.isSuspect)
        XCTAssertEqual(copy.suspectReason, original.suspectReason)
    }

    // MARK: - Editing one item

    func testChangingOneItemRecomputesTheMealTotalWithNoCall() throws {
        let rice = MealItemEntry(
            name: "Rice", portionQuantity: 200, portionUnit: "g",
            calories: 260, proteinG: 5, carbsG: 56, fatG: 1
        )
        let chicken = MealItemEntry(
            name: "Chicken", portionQuantity: 120, portionUnit: "g",
            calories: 200, proteinG: 30, carbsG: 0, fatG: 9
        )
        let meal = try log("Chicken rice", calories: 460, protein: 35, items: [rice, chicken])

        // The rice was actually double: one multiplication, not a second
        // estimate.
        var doubled = rice
        doubled.portionQuantity = 400
        doubled.calories = 520
        doubled.proteinG = 10
        doubled.carbsG = 112
        doubled.fatG = 2
        try service.replaceItem(doubled, in: meal)

        XCTAssertEqual(meal.calories, 720, accuracy: 0.0001)
        XCTAssertEqual(meal.proteinG, 40, accuracy: 0.0001)
        XCTAssertEqual(meal.items.count, 2)
        XCTAssertEqual(meal.items.first(where: { $0.id == rice.id })?.portionQuantity, 400)
    }

    /// A hand edit can push a meal past a hard bound just as an estimate can, so
    /// the bounds run again over the result.
    func testAHandEditPastAHardBoundMarksTheMealSuspect() throws {
        let item = MealItemEntry(
            name: "Rice", portionQuantity: 200, portionUnit: "g",
            calories: 260, proteinG: 5, carbsG: 56, fatG: 1
        )
        let meal = try log("Rice", calories: 260, protein: 5, items: [item])

        var slip = item
        slip.calories = 3400
        try service.replaceItem(slip, in: meal)

        XCTAssertTrue(meal.isSuspect)
        XCTAssertEqual(meal.suspectReason, "3400 kcal is beyond what one meal plausibly holds.")
        XCTAssertEqual(meal.calories, 3400, accuracy: 0.0001)
    }

    /// And an edit that brings the meal back inside the bounds has to clear the
    /// flag, or a corrected meal would stay out of the totals forever.
    func testAHandEditBackInsideTheBoundsClearsTheFlag() throws {
        let item = MealItemEntry(
            name: "Rice", portionQuantity: 2000, portionUnit: "g",
            calories: 3400, proteinG: 5, carbsG: 56, fatG: 1
        )
        let meal = try log("Rice", calories: 3400, protein: 5, suspect: true, items: [item])

        var fixed = item
        fixed.calories = 253
        try service.replaceItem(fixed, in: meal)

        XCTAssertFalse(meal.isSuspect)
        XCTAssertNil(meal.suspectReason)
        XCTAssertEqual(meal.calories, 253, accuracy: 0.0001)
    }

    /// The subset clamps still apply to a hand edit: saturated fat is a PART of
    /// fat whoever typed it.
    ///
    /// The clamp repairs the value and does NOT flag the meal, exactly as on the
    /// estimate path. The user sees the correction because the field redraws
    /// holding the clamped number.
    func testAHandEditIsStillSubjectToTheSubsetClamps() throws {
        let item = MealItemEntry(
            name: "Butter", portionQuantity: 20, portionUnit: "g",
            calories: 150, proteinG: 0, carbsG: 0, fatG: 17, satFatG: 11
        )
        let meal = try log("Butter", calories: 150, protein: 0, items: [item])

        var slip = item
        slip.satFatG = 40
        try service.replaceItem(slip, in: meal)

        XCTAssertEqual(meal.satFatG, 17, accuracy: 0.0001)
        XCTAssertFalse(meal.isSuspect)
        XCTAssertNil(meal.suspectReason)
    }

    /// The macro consistency check is deliberately NOT re-run on a hand edit.
    ///
    /// It asks whether an estimate agrees with itself, and its answer only means
    /// anything alongside the alcohol flag, which belongs to the estimate and is
    /// not stored. A number the user typed is not an estimate.
    func testAHandEditIsNotJudgedByTheConsistencyCheck() throws {
        let item = MealItemEntry(
            name: "Wine", portionQuantity: 175, portionUnit: "ml",
            calories: 160, proteinG: 0, carbsG: 4, fatG: 0
        )
        let meal = try log("A glass of wine", calories: 160, protein: 0, items: [item])

        var corrected = item
        corrected.calories = 190
        try service.replaceItem(corrected, in: meal)

        // 4(0) + 4(4) + 9(0) = 16 against 190 stated. An estimate saying that
        // would be flagged; a user saying it is taken at their word.
        XCTAssertFalse(meal.isSuspect)
        XCTAssertNil(meal.suspectReason)
        XCTAssertEqual(meal.calories, 190, accuracy: 0.0001)
    }

    // MARK: - Overriding the totals

    func testOverridingTheTotalsMakesTheMealExactAndUserSourced() throws {
        let meal = try log("Protein shake", calories: 1, protein: 1, suspect: true)

        try service.overrideTotals(
            of: meal,
            with: MealNutrients(calories: 240, proteinG: 30, carbsG: 12, fatG: 6)
        )

        XCTAssertEqual(meal.calories, 240, accuracy: 0.0001)
        XCTAssertEqual(meal.confidence, 1, accuracy: 0.0001)
        XCTAssertEqual(meal.source, MealSource.user)
        // Known beats estimated: an overridden meal carries no warning.
        XCTAssertFalse(meal.isSuspect)
        XCTAssertNil(meal.suspectReason)
        XCTAssertFalse(meal.needsDetail)
        // And this is the flag the detail sheet reads before letting a
        // re-estimate replace those numbers.
        XCTAssertTrue(meal.totalsWereOverridden)
    }

    func testAnEstimatedMealIsNotMarkedAsOverridden() throws {
        let meal = try log("Chicken rice")

        XCTAssertFalse(meal.totalsWereOverridden)
    }

    /// A repeat of an overridden meal keeps the user source, because its numbers
    /// are still the ones the user typed.
    func testRepeatingAnOverriddenMealKeepsItExact() throws {
        let meal = try log("Protein shake", source: MealSource.user)

        let copy = try service.repeatMeal(meal)

        XCTAssertEqual(copy.source, MealSource.user)
        XCTAssertTrue(copy.totalsWereOverridden)
    }

    // MARK: - Inferred meal type

    func testTheMealTypeInferredFromTheClock() {
        func type(atHour hour: Int) -> MealType {
            let base = Calendar.current.startOfDay(for: Date())
            let at = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
            return MealEstimationService.inferredType(at: at)
        }

        XCTAssertEqual(type(atHour: 8), .breakfast)
        XCTAssertEqual(type(atHour: 13), .lunch)
        XCTAssertEqual(type(atHour: 19), .dinner)
        // Snack is the default rather than the nearest meal: it is the one
        // bucket that is true at any hour.
        XCTAssertEqual(type(atHour: 16), .snack)
        XCTAssertEqual(type(atHour: 2), .snack)
    }
}
