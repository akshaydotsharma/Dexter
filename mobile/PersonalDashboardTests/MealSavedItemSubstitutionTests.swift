import XCTest
import SwiftData
@testable import PersonalDashboard

/// What `saved_item_id` has to guarantee on `log_meal` / `update_meal` (#625).
///
/// The point of the field is exactness: a packet whose numbers the user has
/// already read and accepted must log as those numbers, not as a fresh guess
/// that lands a few percent away every time. Two logs of one pot that disagree
/// are invisible on the day and wrong for the week.
///
/// So the properties pinned here are all about WHOSE numbers reach the row. The
/// model chooses the row and states the portion; the device supplies the
/// arithmetic. And when the id names nothing, the meal still logs — a
/// hallucinated id costs accuracy on one dish and never the record that the
/// user ate.
@MainActor
final class MealSavedItemSubstitutionTests: XCTestCase {

    private var store: SwiftDataStore!
    private var library: FoodItemService!
    private var executor: ExecuteDraftAction!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        library = FoodItemService(store: store)
        executor = ExecuteDraftAction(store: store, mealSource: MealSource.chat)
    }

    override func tearDown() {
        executor = nil
        library = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One library row, per 100 g, whose macros add up to its calories well
    /// inside the guards' 20% tolerance.
    ///
    /// That last part is not decoration: an item whose numbers fail
    /// `MealEstimateGuards` flags the meal suspect and holds it out of every
    /// total, so a careless fixture would test the exclusion path under the
    /// name of the substitution one.
    @discardableResult
    private func saveYogurt() throws -> LocalFoodItem {
        try library.createItem(
            name: "Greek Yogurt",
            brand: "Farmers Union",
            basePortionQuantity: 100,
            basePortionUnit: FoodPortionUnit.grams.rawValue,
            nutrients: MealNutrients(
                calories: 97,
                proteinG: 9.9,
                carbsG: 6.1,
                fatG: 3.4,
                fibreG: 0,
                sugarG: 6.1,
                sodiumMg: 45,
                satFatG: 2.2
            ),
            defaultPortionQuantity: 150,
            source: FoodItemSource.manual,
            isVerified: true
        )
    }

    /// An item in the exact shape the tool schema advertises. The eight values
    /// are deliberately NOT the yogurt's, so a test that reads them back can
    /// only be reading the stored row.
    private func item(
        name: String = "Some yogurt",
        savedItemID: String? = nil,
        grams: Double? = 150,
        calories: Double = 300,
        protein: Double = 20,
        carbs: Double = 30,
        fat: Double = 7
    ) -> AnthropicJSONValue {
        var fields: [String: AnthropicJSONValue] = [
            "name": .string(name),
            "portion_unit": .string("g"),
            "calories": .double(calories),
            "protein_g": .double(protein),
            "carbs_g": .double(carbs),
            "fat_g": .double(fat),
            "fibre_g": .double(0),
            "sugar_g": .double(12),
            "sodium_mg": .double(90),
            "saturated_fat_g": .double(4)
        ]
        if let grams { fields["portion_quantity"] = .double(grams) }
        if let savedItemID { fields["saved_item_id"] = .string(savedItemID) }
        return .object(fields)
    }

    /// An ordinary estimated dish, with no saved row behind it.
    private func egg() -> AnthropicJSONValue {
        .object([
            "name": .string("Poached egg"),
            "portion_quantity": .double(100),
            "portion_unit": .string("g"),
            "calories": .double(143),
            "protein_g": .double(12.6),
            "carbs_g": .double(0.7),
            "fat_g": .double(9.5),
            "fibre_g": .double(0),
            "sugar_g": .double(0.4),
            "sodium_mg": .double(142),
            "saturated_fat_g": .double(3.1)
        ])
    }

    private func logInput(items: [AnthropicJSONValue]) -> [String: AnthropicJSONValue] {
        [
            "id": .string(UUID().uuidString.lowercased()),
            "meal_type": .string(MealType.breakfast.rawValue),
            "description": .string("the usual pot of yogurt"),
            "title": .string("Greek yogurt"),
            "items": .array(items),
            "contains_alcohol": .bool(false),
            "confidence": .string("medium"),
            "assumptions": .string("The 150 g pot."),
            "no_food_identified": .bool(false)
        ]
    }

    private func rows() throws -> [LocalMeal] {
        try store.context.fetch(FetchDescriptor<LocalMeal>())
    }

    // MARK: - The stored numbers win

    /// The whole feature in one assertion: the model names the row and states
    /// 150 g, and the meal carries the row's own figures scaled by 1.5 rather
    /// than the 300 kcal the model typed.
    func testASavedItemIDSubstitutesTheStoredNutrientsScaledToTheQuantity() async throws {
        let saved = try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: saved.clientUUID, grams: 150)])
        )

        let meal = try XCTUnwrap(try rows().first)
        let entry = try XCTUnwrap(meal.items.first)
        XCTAssertEqual(meal.items.count, 1)
        XCTAssertEqual(entry.portionQuantity, 150, accuracy: 0.0001)
        XCTAssertEqual(entry.portionUnit, "g")
        XCTAssertEqual(entry.calories, 145.5, accuracy: 0.0001, "97 kcal per 100 g, at 150 g")
        XCTAssertEqual(entry.proteinG, 14.85, accuracy: 0.0001)
        XCTAssertEqual(entry.carbsG, 9.15, accuracy: 0.0001)
        XCTAssertEqual(entry.fatG, 5.1, accuracy: 0.0001)
        XCTAssertEqual(entry.fibreG, 0, accuracy: 0.0001)
        XCTAssertEqual(entry.sugarG, 9.15, accuracy: 0.0001)
        XCTAssertEqual(entry.sodiumMg, 67.5, accuracy: 0.0001)
        XCTAssertEqual(entry.satFatG, 3.3, accuracy: 0.0001)
    }

    /// The row's name reaches the log, so the meal reads as the packet the user
    /// keeps rather than as whatever the model called it that turn.
    func testTheSubstitutedItemTakesTheLibraryRowsName() async throws {
        let saved = try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(name: "some yoghurt thing", savedItemID: saved.clientUUID)])
        )

        let meal = try XCTUnwrap(try rows().first)
        XCTAssertEqual(meal.items.first?.name, "Farmers Union Greek Yogurt")
    }

    /// "I had my usual yogurt" states no amount. The item's own default portion
    /// is the answer, which is the number the picker opens on.
    func testAnAbsentQuantityUsesTheItemsDefaultPortion() async throws {
        let saved = try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: saved.clientUUID, grams: nil)])
        )

        let entry = try XCTUnwrap(try rows().first?.items.first)
        XCTAssertEqual(entry.portionQuantity, 150, accuracy: 0.0001, "the row's defaultPortionQuantity")
        XCTAssertEqual(entry.calories, 145.5, accuracy: 0.0001)
    }

    // MARK: - A bad id costs accuracy, never the log

    /// An id naming no row leaves the model's own numbers in place and the meal
    /// logs anyway. The alternative — failing the tool — loses the fact that
    /// the user ate over a string the model made up.
    func testAnUnresolvableIDFallsBackToTheModelsOwnNumbers() async throws {
        try saveYogurt()
        let ghost = UUID().uuidString.lowercased()

        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: ghost, grams: 150)])
        )

        XCTAssertEqual(outcome.type, "meal")
        let meal = try XCTUnwrap(try rows().first)
        let entry = try XCTUnwrap(meal.items.first)
        XCTAssertEqual(entry.name, "Some yogurt", "the model's own name survives")
        XCTAssertEqual(entry.calories, 300, accuracy: 0.0001, "the model's own estimate survives")
        XCTAssertEqual(entry.proteinG, 20, accuracy: 0.0001)
        XCTAssertFalse(meal.needsDetail, "a bad id must not turn a described meal into an empty one")
    }

    /// An empty string is not an id. It reads as "this dish is not in the
    /// library", which is what the schema says to send.
    func testAnEmptySavedItemIDIsIgnored() async throws {
        try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: "", grams: 150)])
        )

        XCTAssertEqual(try rows().first?.items.first?.calories ?? 0, 300, accuracy: 0.0001)
    }

    // MARK: - Totals cannot disagree with their own items

    /// A meal of one substituted item and one estimated dish. The stored eight
    /// are the sum of the FINAL list, so the substitution cannot leave a total
    /// describing numbers that are no longer on the row.
    func testTheMealTotalsEqualTheSumOfTheFinalItems() async throws {
        let saved = try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: saved.clientUUID, grams: 150), egg()])
        )

        let meal = try XCTUnwrap(try rows().first)
        XCTAssertEqual(meal.items.count, 2)

        let summed = MealNutrients.sum(of: meal.items)
        for nutrient in Nutrient.allCases {
            XCTAssertEqual(
                meal.nutrients[nutrient],
                summed[nutrient],
                accuracy: 0.0001,
                "\(nutrient.displayName) totals must be the sum of the items actually stored"
            )
        }
        XCTAssertEqual(meal.nutrients.calories, 145.5 + 143, accuracy: 0.0001)
        XCTAssertFalse(meal.isSuspect, "a coherent mixed meal must still count")
    }

    // MARK: - What the two surfaces report

    /// The Shortcut speaks from `MealLogSummary`, which is built off the row.
    /// A substituted meal therefore reports the stored figures, not the ones
    /// the model typed into the call.
    func testTheLogSummaryReportsTheStoredNumbers() async throws {
        let saved = try saveYogurt()

        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: saved.clientUUID, grams: 150)])
        )

        let summary = try XCTUnwrap(outcome.meal)
        XCTAssertEqual(summary.nutrients.calories, 145.5, accuracy: 0.0001)
        XCTAssertEqual(summary.nutrients.proteinG, 14.85, accuracy: 0.0001)
        XCTAssertTrue(
            summary.portionsLine.contains("150 g farmers union greek yogurt"),
            "the portions line names the library row, got \"\(summary.portionsLine)\""
        )
    }

    /// A correction takes the same path, so "that was the 200 g pot" rescales
    /// the stored row instead of re-estimating the packet.
    func testUpdateMealSubstitutesTheStoredNumbersToo() async throws {
        let saved = try saveYogurt()
        let id = UUID().uuidString.lowercased()

        var first = logInput(items: [item(savedItemID: saved.clientUUID, grams: 150)])
        first["id"] = .string(id)
        _ = try await executor.run(actionType: .logMeal, input: first)

        var correction = logInput(items: [item(savedItemID: saved.clientUUID, grams: 200)])
        correction["id"] = .string(id)
        _ = try await executor.run(actionType: .updateMeal, input: correction)

        XCTAssertEqual(try rows().count, 1, "a correction rewrites the row it names")
        let entry = try XCTUnwrap(try rows().first?.items.first)
        XCTAssertEqual(entry.portionQuantity, 200, accuracy: 0.0001)
        XCTAssertEqual(entry.calories, 194, accuracy: 0.0001, "97 kcal per 100 g, at 200 g")
    }

    // MARK: - The picker learns from what was logged

    /// Logging an item through the assistant counts as using it, so the list
    /// orders itself around what the user actually eats however they logged it.
    func testASubstitutionRecordsTheUse() async throws {
        let saved = try saveYogurt()
        XCTAssertEqual(saved.useCount, 0)

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: saved.clientUUID, grams: 150)])
        )

        XCTAssertEqual(saved.useCount, 1)
        XCTAssertNotNil(saved.lastUsedAt)
    }

    /// An id that resolved to nothing counted nothing.
    func testAnUnresolvableIDRecordsNoUse() async throws {
        let saved = try saveYogurt()

        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(items: [item(savedItemID: UUID().uuidString.lowercased())])
        )

        XCTAssertEqual(saved.useCount, 0)
    }

    // MARK: - The context block the model chooses from

    /// The model can only name a row it was shown, so the block has to carry
    /// the id and the numbers.
    func testTheContextBlockNamesTheRowAndItsID() async throws {
        let saved = try saveYogurt()

        let block = await AssistantContextBuilder(store: store).build()

        XCTAssertTrue(block.contains("SAVED FOOD ITEMS"))
        XCTAssertTrue(block.contains("ID:\(saved.clientUUID)"))
        XCTAssertTrue(block.contains("Farmers Union Greek Yogurt"))
        XCTAssertTrue(block.contains("97/9.9/6.1/3.4/0/6.1/45/2.2"), "the eight at the base portion")
        XCTAssertTrue(block.contains("usual 150 g"))
    }

    /// Two builds of an unchanged library must be the same bytes. Anything
    /// order-unstable in a prompt defeats the cache silently, and a Swift sort
    /// is not stable, so the ranking's last tiebreak is what holds this (#580).
    func testTheContextBlockIsByteStableAcrossTurns() async throws {
        // Same name and same use count, so only the id can separate them.
        for _ in 0..<12 {
            try library.createItem(
                name: "Protein Wafer",
                basePortionQuantity: 100,
                nutrients: MealNutrients(calories: 400, proteinG: 20, carbsG: 45, fatG: 15),
                defaultPortionQuantity: 40
            )
        }

        let first = await AssistantContextBuilder(store: store).build()
        let second = await AssistantContextBuilder(store: store).build()
        XCTAssertEqual(first, second)
    }

    /// A library longer than the cap is cut, and the block says so. A model
    /// that believed it had seen everything would tell the user an item is not
    /// saved when it is.
    func testTheBlockStatesWhenItWasCapped() async throws {
        for index in 0..<(AssistantContextBuilder.savedFoodItemsLimit + 3) {
            try library.createItem(
                name: String(format: "Item %03d", index),
                basePortionQuantity: 100,
                nutrients: MealNutrients(calories: 100, proteinG: 5, carbsG: 15, fatG: 2)
            )
        }

        let block = await AssistantContextBuilder(store: store).build()
        let lines = block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("- ID:") }
        XCTAssertEqual(lines.count, AssistantContextBuilder.savedFoodItemsLimit)
        // Derived from the constant, never written out. A literal here pins
        // the test to today's cap, so tuning the cap for prompt cost (#580)
        // fails a test that is not about the cap's value.
        let cap = AssistantContextBuilder.savedFoodItemsLimit
        XCTAssertTrue(block.contains("Showing the \(cap) most used of \(cap + 3)"))
    }
}
