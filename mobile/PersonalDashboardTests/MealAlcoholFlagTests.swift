import XCTest
import SwiftData
@testable import PersonalDashboard

/// `LocalMeal.containsAlcohol` (#555).
///
/// The field exists for one reason: the macro consistency check is the only
/// guard that can prove an estimate wrong without knowing anything about the
/// food, and before this ticket a hand edit switched it off for every meal.
/// It could not be left on, because ethanol carries about 7 kcal per gram and
/// appears in none of the three macros, so an honest beer fails the check.
///
/// Three properties are asserted here, and all three are the kind that fail
/// silently:
///
/// 1. The flag TRAVELS. A field on the model and not in the DTO is invisible to
///    the backup and to sync, and editing it does not even change the record's
///    content hash, so no peer ever hears about it (#449).
/// 2. The flag SURVIVES a hand edit, which is the whole point of storing it.
/// 3. The flag DECIDES the guard, in both directions.
@MainActor
final class MealAlcoholFlagTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!
    private var estimation: MealEstimationService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        meals = MealService(store: store)
        estimation = MealEstimationService(meals: meals)
    }

    override func tearDown() {
        estimation = nil
        meals = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// One item whose macros account for far less than its calories.
    ///
    /// `4P + 4C + 9F` = 165 kcal against a stated 700, a 76% miss. That is well
    /// past the 20% tolerance, so this item is a macro mismatch unless the meal
    /// is exempt. It is the shape a pint of lager makes: the calories are real
    /// and they sit in no macro.
    private func drinkHeavyItem() -> MealItemEntry {
        MealItemEntry(
            name: "Chicken rice and a pint of lager",
            portionQuantity: 550,
            portionUnit: "g",
            calories: 700,
            proteinG: 10,
            carbsG: 20,
            fatG: 5
        )
    }

    /// An item whose macros agree with its calories: 4(30) + 4(70) + 9(20) =
    /// 580 against 600, a 3% miss.
    private func coherentItem() -> MealItemEntry {
        MealItemEntry(
            name: "Chicken rice",
            portionQuantity: 400,
            portionUnit: "g",
            calories: 600,
            proteinG: 30,
            carbsG: 70,
            fatG: 20
        )
    }

    @discardableResult
    private func logMeal(
        id: String,
        containsAlcohol: Bool,
        item: MealItemEntry
    ) throws -> LocalMeal {
        try meals.addMeal(
            date: Date(timeIntervalSince1970: 1_757_462_400),
            loggedAt: Date(timeIntervalSince1970: 1_757_507_400),
            mealType: .lunch,
            mealDescription: item.name,
            nutrients: MealNutrients.sum(of: [item]),
            items: [item],
            confidence: 0.6,
            source: MealSource.chat,
            containsAlcohol: containsAlcohol,
            clientUUID: id
        )
    }

    // MARK: - The default

    /// Every row written before #555 reads false. An additive field with a
    /// default is the safe kind of SwiftData migration, and this is what "safe"
    /// has to mean in practice: the old rows are still there and they say
    /// something sensible.
    func testAMealWrittenWithoutTheFlagIsNotAlcohol() throws {
        let row = try meals.addMeal(
            mealType: .lunch,
            mealDescription: "Chicken rice",
            source: MealSource.composer
        )
        XCTAssertFalse(row.containsAlcohol)
    }

    // MARK: - The flag travels

    /// The registration chain, end to end. A field in the model and not in the
    /// DTO is exported as nothing, restored as nothing, and lost the first time
    /// a device is replaced.
    func testTheFlagRoundTripsThroughAnArchiveIntoAnEmptyStore() async throws {
        try logMeal(id: "alcohol-meal", containsAlcohol: true, item: drinkHeavyItem())
        try logMeal(id: "plain-meal", containsAlcohol: false, item: coherentItem())

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        let preview = try importer.preview(url: archiveURL)
        try importer.commit(preview: preview)

        let restored = try empty.context.fetch(FetchDescriptor<LocalMeal>())
        XCTAssertEqual(restored.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: restored.map { ($0.clientUUID, $0) })
        XCTAssertEqual(byID["alcohol-meal"]?.containsAlcohol, true, "an alcohol meal must restore as one")
        XCTAssertEqual(byID["plain-meal"]?.containsAlcohol, false, "a plain meal must not become one")
    }

    /// An archive written before the field existed carries no key at all. It
    /// must still decode, and the meal must read as not alcohol rather than
    /// failing the whole restore.
    func testAnArchiveThatPredatesTheFieldStillDecodes() throws {
        let json = """
        {
          "clientUUID": "old-meal",
          "date": "2026-09-10T00:00:00Z",
          "loggedAt": "2026-09-10T12:30:00Z",
          "mealType": "lunch",
          "mealDescription": "Chicken rice",
          "calories": 600, "proteinG": 30, "carbsG": 70, "fatG": 20,
          "fibreG": 0, "sugarG": 0, "sodiumMg": 0, "satFatG": 0,
          "confidence": 0.5, "source": "chat",
          "needsDetail": false, "isSuspect": false,
          "createdAt": "2026-09-10T12:30:00Z", "updatedAt": "2026-09-10T12:30:00Z"
        }
        """
        let dto = try DataArchive.makeDecoder()
            .decode(DataArchive.MealDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.containsAlcohol, "an absent key is absent, not false")

        var payload = DataArchive.Payload.empty
        payload.meals = [dto]
        XCTAssertNoThrow(try SyncRecordMapper.records(from: payload))
    }

    /// The #449 failure mode, stated as a hash: a field the DTO does not carry
    /// leaves the content hash unchanged when it is edited, so the diff sees no
    /// change and no peer ever hears about the edit.
    ///
    /// `updatedAt` is pinned to one instant across every reading here. Without
    /// that this test passes on the UNFIXED code, because `updateMeal` moves
    /// the timestamp and the timestamp is in the DTO: the hash would differ for
    /// a reason that has nothing to do with the flag.
    ///
    /// Both directions, because a one-way assertion passes on a mapper that
    /// hashes "true" and nothing else.
    func testTogglingTheFlagChangesTheSyncContentHash() throws {
        let pinned = Date(timeIntervalSince1970: 1_757_600_000)
        let meal = try logMeal(id: "hash-meal", containsAlcohol: false, item: coherentItem())

        let exporter = DataExportService(modelContext: store.context)
        func hash() throws -> String {
            meal.updatedAt = pinned
            try store.context.save()
            let records = try SyncRecordMapper.records(from: try exporter.buildPayload())
            return try XCTUnwrap(
                records.first { $0.entity == "LocalMeal" && $0.recordID == "hash-meal" }
            ).contentHash
        }

        let asPlain = try hash()

        try meals.updateMeal(meal, containsAlcohol: true)
        let asAlcohol = try hash()
        XCTAssertNotEqual(asPlain, asAlcohol, "setting the flag must change the record's content hash")

        // Back off again. This is the half that catches a "nil means leave it
        // alone" update path: if false could not be written, this hash would
        // still read as the alcohol one.
        try meals.updateMeal(meal, containsAlcohol: false)
        XCTAssertFalse(meal.containsAlcohol, "the flag must be clearable back to false")
        XCTAssertEqual(try hash(), asPlain, "clearing the flag must return the record to its original hash")
    }

    /// The same property one level down, with nothing but the flag differing.
    ///
    /// Worth having beside the store-level test above: this one cannot be
    /// satisfied by any timestamp, so it isolates the DTO as the thing the hash
    /// is taken over.
    func testTwoDTOsThatDifferOnlyInTheFlagHashDifferently() throws {
        func record(alcohol: Bool) throws -> SyncRecord {
            var payload = DataArchive.Payload.empty
            payload.meals = [
                DataArchive.MealDTO(
                    clientUUID: "dto-meal",
                    date: Date(timeIntervalSince1970: 0),
                    loggedAt: Date(timeIntervalSince1970: 0),
                    mealType: "lunch", mealDescription: "a",
                    calories: 600, proteinG: 30, carbsG: 70, fatG: 20,
                    fibreG: 0, sugarG: 0, sodiumMg: 0, satFatG: 0,
                    itemsData: nil, confidence: 0.5, source: "chat",
                    needsDetail: false, isSuspect: false, suspectReason: nil,
                    assumptionsNote: nil, containsAlcohol: alcohol,
                    groundingSourcesData: nil,
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
            ]
            return try XCTUnwrap(try SyncRecordMapper.records(from: payload).first)
        }

        XCTAssertNotEqual(try record(alcohol: false).contentHash, try record(alcohol: true).contentHash)
    }

    // MARK: - The flag survives a hand edit

    /// The defect this ticket names. A user correcting a portion must not
    /// silently un-declare their drink.
    func testAHandEditKeepsTheFlag() throws {
        let meal = try logMeal(id: "edited-meal", containsAlcohol: true, item: drinkHeavyItem())

        var edited = meal.items[0]
        edited.portionQuantity = 500
        try estimation.replaceItem(edited, in: meal)

        XCTAssertTrue(meal.containsAlcohol, "a hand edit must not clear the alcohol flag")
    }

    // MARK: - The flag decides the guard

    /// A hand-edited alcohol meal is exempt, so it stays in the day's totals.
    func testAHandEditedAlcoholMealIsExemptFromTheConsistencyCheck() throws {
        let meal = try logMeal(id: "exempt-meal", containsAlcohol: true, item: drinkHeavyItem())

        try estimation.recomputeTotals(of: meal, from: meal.items)

        XCTAssertFalse(meal.isSuspect, "an alcohol meal must not be flagged for a miss alcohol explains")
        XCTAssertNil(meal.suspectReason)
        XCTAssertEqual(meal.calories, 700)
    }

    /// The other direction, which is the guard actually doing its job. Without
    /// this the exemption could be unconditional and every test above would
    /// still pass.
    func testAHandEditedNonAlcoholMealWithIncoherentMacrosIsSuspect() throws {
        let meal = try logMeal(id: "suspect-meal", containsAlcohol: false, item: drinkHeavyItem())

        try estimation.recomputeTotals(of: meal, from: meal.items)

        XCTAssertTrue(meal.isSuspect, "a hand-edited meal whose macros do not add up must be flagged")
        let reason = try XCTUnwrap(meal.suspectReason)
        XCTAssertTrue(reason.contains("165"), "the reason must state the implied calories, got: \(reason)")
        XCTAssertTrue(reason.contains("700"), "the reason must state the stated calories, got: \(reason)")
    }

    /// The guard runs on hand-edited numbers rather than only on estimates, and
    /// a coherent edit passes it.
    func testAHandEditedCoherentMealIsNotSuspect() throws {
        let meal = try logMeal(id: "coherent-meal", containsAlcohol: false, item: coherentItem())

        try estimation.recomputeTotals(of: meal, from: meal.items)

        XCTAssertFalse(meal.isSuspect)
        XCTAssertNil(meal.suspectReason)
    }

    // MARK: - The user can correct it

    /// The detail sheet's path. Turning the flag on clears a macro mismatch the
    /// drink explains; turning it back off restores it.
    ///
    /// Asserted through `MealEstimationService` rather than through the sheet,
    /// because a decision made inside a SwiftUI View is a decision no test can
    /// reach (#488). The sheet's toggle calls exactly this.
    func testTheUserCanTurnTheFlagOnAndOffAndTheVerdictFollows() throws {
        let meal = try logMeal(id: "corrected-meal", containsAlcohol: false, item: drinkHeavyItem())
        try estimation.recomputeTotals(of: meal, from: meal.items)
        XCTAssertTrue(meal.isSuspect, "precondition: the meal starts flagged")

        try estimation.setContainsAlcohol(true, on: meal)
        XCTAssertTrue(meal.containsAlcohol)
        XCTAssertFalse(meal.isSuspect, "declaring the drink must withdraw the flag it explains")
        XCTAssertNil(meal.suspectReason)

        try estimation.setContainsAlcohol(false, on: meal)
        XCTAssertFalse(meal.containsAlcohol, "the correction must be reversible")
        XCTAssertTrue(meal.isSuspect, "withdrawing the drink must bring the mismatch back")
    }

    /// Setting the flag must never re-total a meal whose numbers the user typed.
    /// Known beats estimated, and its items are not the source of its totals.
    func testSettingTheFlagLeavesOverriddenTotalsAlone() throws {
        let meal = try logMeal(id: "override-meal", containsAlcohol: false, item: coherentItem())
        try estimation.overrideTotals(of: meal, with: MealNutrients(calories: 850, proteinG: 12))

        try estimation.setContainsAlcohol(true, on: meal)

        XCTAssertTrue(meal.containsAlcohol)
        XCTAssertEqual(meal.calories, 850, "a typed total must survive the toggle")
        XCTAssertEqual(meal.proteinG, 12)
        XCTAssertFalse(meal.isSuspect, "an overridden meal is exact and is not graded")
    }

    /// A meal with no items at all still takes the flag, and its totals are not
    /// zeroed by a re-total over an empty array.
    func testSettingTheFlagOnAMealWithNoItemsKeepsItsTotals() throws {
        let meal = try meals.addMeal(
            mealType: .snack,
            mealDescription: "A pint on the way home",
            nutrients: MealNutrients(calories: 210),
            source: MealSource.capture,
            clientUUID: "no-items-meal"
        )

        try estimation.setContainsAlcohol(true, on: meal)

        XCTAssertTrue(meal.containsAlcohol)
        XCTAssertEqual(meal.calories, 210, "a meal with no items must not be zeroed")
    }

    // MARK: - Every write path populates the flag

    /// The composer's path: the model answers, the guards grade the answer, and
    /// `save` writes the row. The flag has to survive that hop or it never
    /// reaches the store at all.
    func testSavingACheckedEstimateStoresTheModelsAnswer() throws {
        let estimate = EstimatedMeal(
            mealType: "dinner",
            items: [
                EstimatedMealItem(
                    name: "Pint of lager",
                    portionQuantity: 568,
                    portionUnit: "ml",
                    calories: 210,
                    proteinG: 2,
                    carbsG: 17,
                    fatG: 0
                )
            ],
            containsAlcohol: true,
            confidence: "medium"
        )
        let checked = MealEstimateGuards.check(estimate, fallbackMealType: .dinner)
        XCTAssertTrue(checked.containsAlcohol, "precondition: the guards carry the model's answer")

        let row = try estimation.save(
            checked,
            description: "a pint of lager",
            day: Date(),
            loggedAt: Date()
        )

        XCTAssertTrue(row.containsAlcohol)
        XCTAssertFalse(row.isSuspect, "the exemption must apply on the estimate path too")
    }

    /// The chat and Shortcut paths. Both go through `log_meal`, and the tool
    /// input carries `contains_alcohol` as its own key.
    func testTheChatAndCaptureToolsStoreTheFlag() async throws {
        let chat = ExecuteDraftAction(store: store, mealSource: MealSource.chat)
        let capture = ExecuteDraftAction(store: store, mealSource: MealSource.capture)

        _ = try await chat.run(actionType: .logMeal, input: logMealInput(id: chatID, alcohol: true))
        _ = try await capture.run(actionType: .logMeal, input: logMealInput(id: captureID, alcohol: true))

        let rows = try store.context.fetch(FetchDescriptor<LocalMeal>())
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.clientUUID, $0) })
        XCTAssertEqual(byID[chatID]?.containsAlcohol, true, "the chat tool must store the flag")
        XCTAssertEqual(byID[captureID]?.containsAlcohol, true, "the Shortcut must store the flag")
    }

    /// `update_meal` rewrites the same row, so a correction that says the meal
    /// held no alcohol has to be able to clear the flag.
    func testTheUpdateToolCanClearTheFlag() async throws {
        let chat = ExecuteDraftAction(store: store, mealSource: MealSource.chat)
        _ = try await chat.run(actionType: .logMeal, input: logMealInput(id: chatID, alcohol: true))

        _ = try await chat.run(actionType: .updateMeal, input: logMealInput(id: chatID, alcohol: false))

        let rows = try store.context.fetch(FetchDescriptor<LocalMeal>())
        XCTAssertEqual(rows.count, 1, "an update rewrites the row rather than adding one")
        XCTAssertEqual(rows.first?.containsAlcohol, false, "a correction must be able to clear the flag")
    }

    private var chatID: String { "11111111-1111-1111-1111-111111111111" }
    private var captureID: String { "22222222-2222-2222-2222-222222222222" }

    private func logMealInput(id: String, alcohol: Bool) -> [String: AnthropicJSONValue] {
        [
            "id": .string(id),
            "meal_type": .string(MealType.dinner.rawValue),
            "description": .string("a pint of lager"),
            "items": .array([
                .object([
                    "name": .string("Pint of lager"),
                    "portion_quantity": .double(568),
                    "portion_unit": .string("ml"),
                    "calories": .double(210),
                    "protein_g": .double(2),
                    "carbs_g": .double(17),
                    "fat_g": .double(0),
                    "fibre_g": .double(0),
                    "sugar_g": .double(0),
                    "sodium_mg": .double(14),
                    "saturated_fat_g": .double(0)
                ])
            ]),
            "contains_alcohol": .bool(alcohol),
            "confidence": .string("medium"),
            "no_food_identified": .bool(false)
        ]
    }

    // MARK: - Repeat

    /// Repeat copies the meal's stored numbers and makes no call. A repeat of a
    /// meal that held a drink still holds a drink, so its exemption has to come
    /// with it or the copy is flagged the moment it is edited.
    func testARepeatedMealKeepsTheFlag() throws {
        let meal = try logMeal(id: "repeat-source", containsAlcohol: true, item: drinkHeavyItem())

        let copy = try estimation.repeatMeal(meal)

        XCTAssertTrue(copy.containsAlcohol)
        XCTAssertNotEqual(copy.clientUUID, meal.clientUUID)
    }
}
