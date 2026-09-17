import XCTest
import SwiftData
@testable import PersonalDashboard

/// The plan-side estimate: what is asked for, and what is done with the answer
/// (#599).
///
/// No network. The hard part of this path is not "did the call succeed", it is
/// whether the plan reuses the logging path's estimator rather than growing a
/// second one, and whether the answer lands on the block intact. Both are
/// checkable against the shipped schema and the shipped save.
///
/// A second estimator that drifts from the first is a defect this repo has paid
/// for three times (#475, #500, #522), and it is invisible until one path gets a
/// fix the other never hears about. So the first group of tests here is about
/// SHARING, not about behaviour.
@MainActor
final class MealPlanEstimateTests: XCTestCase {

    private var store: SwiftDataStore!
    private var plans: MealPlanService!
    private var estimator: MealPlanEstimationService!

    /// A fixed Wednesday, 10 September 2025.
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        plans = MealPlanService(store: store)
        estimator = MealPlanEstimationService(plans: plans)
    }

    override func tearDown() {
        estimator = nil
        plans = nil
        store = nil
        super.tearDown()
    }

    // MARK: - One estimator, not two

    /// The dish schema is `MealToolSchema.itemSchema` ITSELF, not a copy.
    ///
    /// Identity, not equality by eye: a copied schema compiles, passes a
    /// hand-written field check, and then stops matching the day someone adds a
    /// field to the original.
    func testItemSchemaIsTheSharedOne() {
        let properties = AnthropicClient.planMealTool.input_schema.objectValue?["properties"]?.objectValue
        let items = properties?["items"]?.objectValue?["items"]
        XCTAssertEqual(items, MealToolSchema.itemSchema)
    }

    /// The nutrition rules are the shared string, so a rule changed for logging
    /// changes for planning in the same edit.
    func testEstimateRulesAreTheSharedOnes() {
        XCTAssertTrue(
            AnthropicClient.planMealTool.description.contains(MealToolSchema.estimateRules),
            "The plan tool must inline the shared rules rather than paraphrase them."
        )
    }

    /// The name and the items are required and nothing else is (#603).
    ///
    /// Ingredients and a recipe are answers the model may honestly not have: a
    /// bought meal has nothing to shop for, and an obvious method needs no
    /// steps. A NAME is different — every block has one, because every block is
    /// drawn in a list — so it is required rather than hoped for. A rule the
    /// model keeps dropping belongs in the schema, not in prose.
    func testTheNameAndTheItemsAreRequired() {
        let required = AnthropicClient.planMealTool.input_schema
            .objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(required, ["title", "items"])
    }

    /// And the name is a real property of the schema, not just a word in the
    /// tool's description.
    func testTheSchemaCarriesTheNameAsAProperty() {
        let properties = AnthropicClient.planMealTool.input_schema
            .objectValue?["properties"]?.objectValue
        XCTAssertNotNil(properties?["title"])
    }

    /// No web search is declared. A plan's figures are a forecast that gets
    /// re-estimated when the meal is actually eaten, so grounding them in a
    /// brand's published panel would double the cost of the cheapest interaction
    /// in the feature to raise the precision of a number about to be replaced.
    func testNoServerToolIsDeclared() {
        XCTAssertNil(AnthropicClient.planMealTool.serverToolType)
    }

    // MARK: - Landing the answer

    /// A save carries all three parts of the answer onto the block.
    func testSaveCarriesNumbersIngredientsAndRecipe() throws {
        let planned = PlannedMealEstimate(
            estimate: MealEstimateGuards.check(
                EstimatedMeal(
                    mealType: "dinner",
                    items: [
                        EstimatedMealItem(
                            name: "Poached chicken", portionQuantity: 150, portionUnit: "g",
                            calories: 250, proteinG: 46, carbsG: 0, fatG: 6,
                            fibreG: 0, sugarG: 0, sodiumMg: 300, satFatG: 2
                        ),
                        EstimatedMealItem(
                            name: "Jasmine rice", portionQuantity: 200, portionUnit: "g",
                            calories: 370, proteinG: 7, carbsG: 80, fatG: 1,
                            fibreG: 1, sugarG: 0, sodiumMg: 5, satFatG: 0
                        )
                    ],
                    containsAlcohol: false,
                    confidence: "medium",
                    assumptions: "Assumed a standard hawker portion.",
                    noFoodIdentified: false
                ),
                fallbackMealType: .dinner
            ),
            ingredients: ["chicken thigh", "jasmine rice", "ginger"],
            recipe: "Poach the chicken\nSteam the rice in the stock"
        )

        let entry = try estimator.save(planned, title: "Chicken rice", day: day)

        XCTAssertEqual(entry.title, "Chicken rice")
        XCTAssertEqual(entry.mealTypeEnum, .dinner)
        XCTAssertEqual(entry.ingredients, ["chicken thigh", "jasmine rice", "ginger"])
        XCTAssertEqual(entry.recipe, "Poach the chicken\nSteam the rice in the stock")
        XCTAssertEqual(entry.items.map(\.name), ["Poached chicken", "Jasmine rice"])
        XCTAssertEqual(entry.plannedNutrients?.calories, 620, "Totals are the sum of the items.")
        XCTAssertEqual(entry.plannedNutrients?.proteinG, 53)
    }

    /// An estimate that named no food saves with NO numbers rather than with
    /// eight zeros.
    ///
    /// Zeros would claim the model had identified a fast. The block still saves,
    /// because losing the fact that the user wrote something down is worse than
    /// losing the number, and inventing the number is worse than both — the same
    /// call the logging path makes.
    func testNeedsDetailSavesWithoutNumbers() throws {
        let planned = PlannedMealEstimate(
            estimate: MealEstimateGuards.check(
                EstimatedMeal(
                    mealType: nil, items: [], containsAlcohol: nil,
                    confidence: nil, assumptions: nil, noFoodIdentified: true
                ),
                fallbackMealType: .lunch
            ),
            ingredients: [],
            recipe: nil
        )
        XCTAssertTrue(planned.estimate.needsDetail)

        let entry = try estimator.save(planned, title: "something", day: day)
        XCTAssertNil(entry.plannedNutrients, "A block with no identified food carries no numbers.")
        XCTAssertFalse(entry.hasNutrition)
    }

    /// Re-estimating corrects the block it names rather than adding a second one
    /// — the identity contract `MealPlanService` holds (#514).
    func testSaveWithAnIDIsACorrection() throws {
        let planned = PlannedMealEstimate(
            estimate: MealEstimateGuards.check(
                EstimatedMeal(
                    mealType: "lunch",
                    items: [
                        EstimatedMealItem(
                            name: "Dal", portionQuantity: 300, portionUnit: "g",
                            calories: 400, proteinG: 20, carbsG: 50, fatG: 10,
                            fibreG: 8, sugarG: 3, sodiumMg: 400, satFatG: 2
                        )
                    ],
                    containsAlcohol: false, confidence: "high",
                    assumptions: nil, noFoodIdentified: false
                ),
                fallbackMealType: .lunch
            ),
            ingredients: ["toor dal"],
            recipe: nil
        )

        try estimator.save(planned, title: "Dal", day: day, clientUUID: "abc")
        try estimator.save(planned, title: "Dal tadka", day: day, clientUUID: "abc")

        let rows = try store.context.fetch(FetchDescriptor<LocalMealPlanEntry>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Dal tadka")
    }

    /// Re-totalling from corrected items is arithmetic, not a second call.
    func testRecomputeTotalsMakesNoCall() throws {
        let entry = try plans.addEntry(
            date: day,
            mealType: .lunch,
            title: "Chicken rice",
            nutrients: MealNutrients(calories: 620),
            items: [
                MealItemEntry(name: "Poached chicken", portionQuantity: 150, portionUnit: "g", calories: 250),
                MealItemEntry(name: "Jasmine rice", portionQuantity: 200, portionUnit: "g", calories: 370)
            ]
        )

        var items = entry.items
        items[1].calories = 185   // half the rice
        try estimator.recomputeTotals(of: entry, from: items)

        XCTAssertEqual(entry.plannedNutrients?.calories, 435)
    }
}
