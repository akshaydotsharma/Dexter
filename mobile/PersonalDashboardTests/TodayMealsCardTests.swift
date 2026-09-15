import XCTest
import SwiftData
@testable import PersonalDashboard

/// The Today meals card agrees with the Meals section, for the same day (#547).
///
/// ### Why this is pinned rather than assumed
///
/// The card exists to show a number the user has already seen somewhere else.
/// The moment it computes that number itself, the two surfaces can disagree,
/// and the first thing to diverge is the exclusions: a suspect meal has numbers
/// known to be wrong and a needs-detail meal has no numbers at all, and both are
/// held out of a day total by `MealDaySummary`. A card that summed its rows
/// would fold the suspect meal back in, print a larger figure than the Meals
/// section, and nothing on either screen would say which of the two was right.
///
/// So these tests run the card's own selection call, `MealDaySummary.onDay`,
/// against the service's independent day fetch, and assert every field the card
/// renders matches.
@MainActor
final class TodayMealsCardTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!

    /// A fixed instant, so a day is a day and not "whenever the suite ran".
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

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

    @discardableResult
    private func log(
        _ description: String,
        on when: Date? = nil,
        calories: Double = 500,
        protein: Double = 25,
        carbs: Double = 50,
        fat: Double = 20,
        fibre: Double = 4,
        type: MealType = .lunch,
        suspect: Bool = false,
        needsDetail: Bool = false
    ) throws -> LocalMeal {
        let at = when ?? day
        return try meals.addMeal(
            date: at,
            loggedAt: at,
            mealType: type,
            mealDescription: description,
            nutrients: MealNutrients(
                calories: calories, proteinG: protein, carbsG: carbs,
                fatG: fat, fibreG: fibre
            ),
            confidence: 0.6,
            source: MealSource.composer,
            needsDetail: needsDetail,
            isSuspect: suspect,
            suspectReason: suspect ? "The macros do not add up." : nil
        )
    }

    /// Every meal in the store, which is what the card's `@Query` hands it.
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

    // MARK: - The agreement

    /// The card's day and the section's day are the same day, on a day that
    /// holds both kinds of held-back meal.
    func testTheCardTotalsAgreeWithTheMealsSectionOnADayWithASuspectAndANeedsDetailMeal() throws {
        try log("Overnight oats", calories: 420, protein: 18, carbs: 55, fat: 12, fibre: 6, type: .breakfast)
        try log("Chicken rice", calories: 600, protein: 35, carbs: 70, fat: 18, fibre: 3, type: .lunch)
        // Numbers known to be wrong.
        try log("A suspiciously large salad", calories: 4000, protein: 200, carbs: 300, fat: 150, fibre: 40,
                type: .dinner, suspect: true)
        // No numbers at all.
        try log("rice", calories: 0, protein: 0, carbs: 0, fat: 0, fibre: 0,
                type: .snack, needsDetail: true)

        // What the Today card is built from.
        let card = MealDaySummary.onDay(day, in: try everyMeal())
        // What the Meals section shows for the same day, fetched independently.
        let section = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(card.totals, section.totals)
        XCTAssertEqual(card.counted.count, section.counted.count)
        XCTAssertEqual(card.excluded.count, section.excluded.count)
        XCTAssertEqual(card.all.count, section.all.count)
        XCTAssertEqual(card.isUnlogged, section.isUnlogged)

        // And the agreed number is the two good meals and only those. Stated
        // absolutely as well as relatively, so a bug that broke BOTH paths the
        // same way cannot pass this test.
        XCTAssertEqual(card.totals.calories, 1020, accuracy: 0.0001)
        XCTAssertEqual(card.totals.proteinG, 53, accuracy: 0.0001)
        XCTAssertEqual(card.totals.carbsG, 125, accuracy: 0.0001)
        XCTAssertEqual(card.totals.fatG, 30, accuracy: 0.0001)
        XCTAssertEqual(card.totals.fibreG, 9, accuracy: 0.0001)
        XCTAssertEqual(card.counted.count, 2)
        XCTAssertEqual(card.excluded.count, 2)
        XCTAssertEqual(card.all.count, 4)
    }

    /// The count in the card's eyebrow is the counted meals, not every row. A
    /// count that included a held-back meal would make "3 meals, 1,020 kcal"
    /// read as a light day rather than as a day with a question outstanding.
    func testTheCardCountIsTheCountedMealsNotEveryRow() throws {
        try log("Chicken rice", calories: 600)
        try log("Mystery bowl", calories: 4000, suspect: true)
        try log("rice", calories: 0, needsDetail: true)

        let card = MealDaySummary.onDay(day, in: try everyMeal())

        XCTAssertEqual(card.counted.count, 1)
        XCTAssertEqual(card.all.count, 3)
        XCTAssertFalse(card.isUnlogged)
        XCTAssertEqual(card.totals.calories, 600, accuracy: 0.0001)
    }

    /// The card totals ONE day. A meal on the day before is not on the card, and
    /// the day match goes through the stored anchor rather than the instant.
    func testTheCardTotalsOnlyTheDayItWasAskedFor() throws {
        let yesterday = day.addingTimeInterval(-86_400)
        try log("Yesterday's dinner", on: yesterday, calories: 900, type: .dinner)
        try log("Today's lunch", calories: 600)

        let card = MealDaySummary.onDay(day, in: try everyMeal())
        let section = MealDaySummary(meals: try meals.meals(on: day))

        XCTAssertEqual(card.totals, section.totals)
        XCTAssertEqual(card.totals.calories, 600, accuracy: 0.0001)
        XCTAssertEqual(card.all.count, 1)

        // And the day before still adds up on its own.
        let priorCard = MealDaySummary.onDay(yesterday, in: try everyMeal())
        XCTAssertEqual(priorCard.totals.calories, 900, accuracy: 0.0001)
    }

    /// A day nobody logged reads as unlogged on the card, which is what puts the
    /// container into its empty state instead of printing a card of zeros.
    func testADayWithNoMealsReadsAsUnlogged() throws {
        try log("Yesterday's dinner", on: day.addingTimeInterval(-86_400))

        let card = MealDaySummary.onDay(day, in: try everyMeal())

        XCTAssertTrue(card.isUnlogged)
        XCTAssertEqual(card.totals, MealNutrients.zero)
    }

    /// A day whose ONLY meal is held back is not an unlogged day. The card shows
    /// zero against a count of zero, plus the held-back line, rather than the
    /// "nothing logged yet" state — the log was kept, the numbers were not.
    func testADayOfOnlyHeldBackMealsIsNotUnlogged() throws {
        try log("Mystery bowl", calories: 4000, suspect: true)

        let card = MealDaySummary.onDay(day, in: try everyMeal())

        XCTAssertFalse(card.isUnlogged)
        XCTAssertEqual(card.counted.count, 0)
        XCTAssertEqual(card.excluded.count, 1)
        XCTAssertEqual(card.totals.calories, 0, accuracy: 0.0001)
    }

    // MARK: - Targets

    /// The card and the section read the same targets record, so they cannot
    /// paint two different verdicts for one day.
    func testTheCardReadsTheSameTargetsAsTheService() throws {
        try meals.saveTargets(
            targets: MealNutrients(calories: 2200, proteinG: 130, carbsG: 250, fatG: 70, fibreG: 30),
            ageYears: 38, biologicalSex: "male", heightCm: 178, weightKg: 76,
            activityLevel: "moderate", goal: "maintain",
            rationale: "Derived for the test.",
            effectiveFrom: day
        )
        let all = try store.context.fetch(
            FetchDescriptor<MealTargets>(sortBy: [SortDescriptor(\.effectiveFrom, order: .forward)])
        )

        let cardTargets = try XCTUnwrap(MealTargets.inForce(on: day, among: all))
        let serviceTargets = try XCTUnwrap(meals.targets(on: day))

        XCTAssertEqual(cardTargets.clientUUID, serviceTargets.clientUUID)
        XCTAssertEqual(cardTargets.target(for: .calories), 2200, accuracy: 0.0001)
    }

    /// With no record at all there is no target, which is what takes the bar and
    /// the remainder off the card. Logging is never blocked on setup.
    func testWithNoTargetsSetThereIsNoTargetToDrawAgainst() throws {
        try log("Chicken rice", calories: 600)

        let all = try store.context.fetch(
            FetchDescriptor<MealTargets>(sortBy: [SortDescriptor(\.effectiveFrom, order: .forward)])
        )

        XCTAssertNil(MealTargets.inForce(on: day, among: all))
        XCTAssertEqual(MealDaySummary.onDay(day, in: try everyMeal()).totals.calories, 600, accuracy: 0.0001)
    }

    // MARK: - The Activity chip

    /// The Meals chip shows meal rows and only meal rows, and All still shows
    /// everything. A filter case added without its `includes` arm is silent:
    /// the chip appears and the feed under it is empty.
    func testTheMealsChipShowsMealRowsAndNothingElse() {
        XCTAssertTrue(ActivityView.Filter.meals.includes(.meal))
        XCTAssertTrue(ActivityView.Filter.all.includes(.meal))

        for type in ActivityItem.ItemType.allCases where type != .meal {
            XCTAssertFalse(
                ActivityView.Filter.meals.includes(type),
                "the Meals chip must not show \(type.rawValue) rows"
            )
        }
        for filter in ActivityView.Filter.allCases where filter != .meals && filter != .all {
            XCTAssertFalse(
                filter.includes(.meal),
                "the \(filter.label) chip must not show meal rows"
            )
        }
    }
}
