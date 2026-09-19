import XCTest
import SwiftData
@testable import PersonalDashboard

/// What a pick promises about the library (#625).
///
/// The feature was reworked because the first version made the saved-item list
/// something the user had to curate: a separate button to search the public
/// database, and a confirm form on every import. The rule now is that the list
/// accumulates by USE. An item is his because he ate it.
///
/// Two properties carry that rule, and both are easy to break by accident:
///
/// 1. Tapping a database hit writes NOTHING. Only committing does. A hit added
///    and then removed has to leave the store exactly as it found it, or the
///    list fills with everything that was ever considered.
/// 2. A hit naming something he already has never appears twice. His row wins,
///    because it may carry his corrections and it carries his use count.
@MainActor
final class MealFoodItemPickTests: XCTestCase {

    private var store: SwiftDataStore!
    private var library: FoodItemService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        library = FoodItemService(store: store)
    }

    override func tearDown() {
        library = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A hit as the Open Food Facts mapping would hand it over: per 100 g, with
    /// a 40 g serving and both outside identities set to the barcode.
    private func waferDraft(code: String = "8901234567890") -> FoodItemDraft {
        FoodItemDraft(
            name: "Protein Wafer",
            brand: "Superyou",
            basePortionQuantity: 100,
            basePortionUnit: .grams,
            calories: 400,
            proteinG: 25,
            carbsG: 40,
            fatG: 16,
            fibreG: 3,
            sugarG: 10,
            sodiumMg: 442.5,
            satFatG: 7,
            defaultPortionQuantity: 40,
            barcode: code,
            externalSource: FoodItemSource.openFoodFacts,
            externalID: code
        )
    }

    private func databasePick(_ draft: FoodItemDraft, quantity: Double? = nil) -> FoodItemPick {
        FoodItemPick(origin: .database(draft), entry: draft.mealItem(quantity: quantity))
    }

    private func savedRows() throws -> [LocalFoodItem] {
        try store.context.fetch(FetchDescriptor<LocalFoodItem>())
    }

    // MARK: - A tap writes nothing

    /// The property the rework is built on. Building the pick is what tapping a
    /// result does, and the store must not move.
    func testTappingADatabaseHitWritesNothing() throws {
        _ = databasePick(waferDraft())
        XCTAssertTrue(try savedRows().isEmpty, "a tapped hit must not reach the store")
    }

    /// The same, stated from the other end: a tray that is never committed
    /// leaves no trace at all.
    func testAnUncommittedTrayLeavesTheLibraryEmpty() throws {
        let picks = [databasePick(waferDraft()), databasePick(waferDraft(code: "5000000000000"))]
        XCTAssertEqual(picks.count, 2)
        XCTAssertTrue(try savedRows().isEmpty)
    }

    // MARK: - Committing is what makes a row his

    /// One commit writes the row, with the draft's numbers verbatim and the use
    /// counted once.
    func testCommittingADatabasePickUpsertsTheRowAndCountsTheUse() throws {
        let draft = waferDraft()

        let rows = FoodItemPick.commit([databasePick(draft)], countingUse: true, using: library)

        XCTAssertEqual(rows.count, 1)
        let saved = try XCTUnwrap(try savedRows().first)
        XCTAssertEqual(try savedRows().count, 1)
        XCTAssertEqual(saved.name, "Protein Wafer")
        XCTAssertEqual(saved.brand, "Superyou")
        XCTAssertEqual(saved.basePortionQuantity, 100, accuracy: 0.0001)
        XCTAssertEqual(saved.defaultPortionQuantity, 40, accuracy: 0.0001)
        XCTAssertEqual(saved.calories, 400, accuracy: 0.0001)
        XCTAssertEqual(saved.sodiumMg, 442.5, accuracy: 0.0001, "milligrams, as the mapping converted them")
        XCTAssertEqual(saved.externalID, "8901234567890")
        XCTAssertEqual(saved.source, FoodItemSource.openFoodFacts)
        XCTAssertFalse(saved.isVerified, "nobody has read this against the packet yet")
        XCTAssertEqual(saved.useCount, 1)
        XCTAssertNotNil(saved.lastUsedAt)
    }

    /// A scan carries its own provenance on the draft, because the numbers of a
    /// scanned hit and a searched hit are identical and `source` is the only
    /// field that can tell them apart.
    func testAScannedDraftIsWrittenAsABarcodeImport() throws {
        var draft = waferDraft()
        draft.source = FoodItemSource.barcode

        FoodItemPick.commit([databasePick(draft)], countingUse: true, using: library)

        XCTAssertEqual(try savedRows().first?.source, FoodItemSource.barcode)
    }

    /// Eating the same packet twice corrects the row rather than laying a
    /// second one beside it. Two rows for one wafer make every later choice in
    /// the picker a coin toss.
    func testCommittingTheSameHitTwiceKeepsOneRowAndCountsTwoUses() throws {
        FoodItemPick.commit([databasePick(waferDraft())], countingUse: true, using: library)
        FoodItemPick.commit([databasePick(waferDraft())], countingUse: true, using: library)

        XCTAssertEqual(try savedRows().count, 1, "matched on externalID, so no duplicate")
        XCTAssertEqual(try savedRows().first?.useCount, 2)
    }

    /// A correction he made by hand SURVIVES eating the item again.
    ///
    /// This is the defect that made the rule "reuse, never re-import" necessary.
    /// Commit ran `upsert` unconditionally, and `upsert` rewrites the name and
    /// all eight nutrients of the row it matches. So a figure he fixed by hand
    /// held only until the next time he logged the packet, and the database's
    /// wrong number came back with nothing on screen to say it had.
    ///
    /// That is worse than never letting him correct it. A library whose whole
    /// promise is that the row becomes HIS cannot quietly restore a stranger's
    /// numbers over his, least of all on the happy path of eating breakfast.
    func testACorrectedFigureSurvivesEatingTheItemAgain() throws {
        FoodItemPick.commit([databasePick(waferDraft())], countingUse: true, using: library)

        // He reads the packet and fixes the calories.
        let row = try XCTUnwrap(try savedRows().first)
        try library.updateItem(row, nutrients: MealNutrients(
            calories: 500, proteinG: 25, carbsG: 50, fatG: 25.9
        ))
        XCTAssertEqual(try savedRows().first?.calories, 500)

        // He eats it again, from a fresh database hit carrying the old figure.
        FoodItemPick.commit([databasePick(waferDraft())], countingUse: true, using: library)

        XCTAssertEqual(try savedRows().count, 1)
        XCTAssertEqual(
            try savedRows().first?.calories, 500,
            "his correction must win over the database's figure"
        )
        XCTAssertEqual(try savedRows().first?.useCount, 2, "still counted as eaten")
    }

    /// A plan is a forecast, not a meal. The row is written so the item is
    /// reusable, and the counters stay where they are so a week of intentions
    /// cannot outrank something eaten forty times.
    func testAPlanWritesTheRowWithoutCountingAUse() throws {
        FoodItemPick.commit([databasePick(waferDraft())], countingUse: false, using: library)

        let saved = try XCTUnwrap(try savedRows().first)
        XCTAssertEqual(saved.useCount, 0)
        XCTAssertNil(saved.lastUsedAt)
    }

    /// A pick of a row he already has creates nothing and counts one use.
    func testCommittingASavedPickCreatesNothingAndCountsTheUse() throws {
        let existing = try library.createItem(
            name: "Greek Yogurt",
            brand: "Farmers Union",
            nutrients: MealNutrients(calories: 97, proteinG: 9.9, carbsG: 6.1, fatG: 3.4),
            defaultPortionQuantity: 150,
            isVerified: true
        )
        let pick = FoodItemPick(
            origin: .saved(itemUUID: existing.clientUUID),
            entry: existing.mealItem()
        )

        FoodItemPick.commit([pick], countingUse: true, using: library)

        XCTAssertEqual(try savedRows().count, 1)
        XCTAssertEqual(existing.useCount, 1)
        XCTAssertTrue(existing.isVerified, "committing must not un-say the user's own check")
    }

    /// A saved pick whose row was deleted between the pick and the write is
    /// skipped. The meal is already the point and holds its own copy of the
    /// numbers; a missing counter is not worth failing over.
    func testASavedPickNamingNoRowIsSkipped() throws {
        let pick = FoodItemPick(
            origin: .saved(itemUUID: UUID().uuidString.lowercased()),
            entry: MealItemEntry(name: "Ghost", portionQuantity: 100, portionUnit: "g")
        )

        let rows = FoodItemPick.commit([pick], countingUse: true, using: library)

        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(try savedRows().isEmpty)
    }

    // MARK: - Scaling with no row behind it

    /// A hit in the tray has to answer "what are 80 g of you" before anything
    /// has been written, which is the whole reason the draft rides on the pick.
    func testADatabasePickRescalesOffItsOwnDraft() throws {
        let pick = databasePick(waferDraft())
        XCTAssertEqual(pick.entry.portionQuantity, 40, accuracy: 0.0001, "the record's own serving")
        XCTAssertEqual(pick.entry.calories, 160, accuracy: 0.0001, "400 kcal per 100 g, at 40 g")

        let rescaled = try XCTUnwrap(pick.entry(at: 80, savedRow: nil))
        XCTAssertEqual(rescaled.portionQuantity, 80, accuracy: 0.0001)
        XCTAssertEqual(rescaled.calories, 320, accuracy: 0.0001)
        XCTAssertEqual(rescaled.proteinG, 20, accuracy: 0.0001)
        XCTAssertEqual(rescaled.name, "Superyou Protein Wafer", "brand and name, as a shelf would label it")
    }

    // MARK: - One list, no product twice

    /// The dedupe the merged result list depends on. A hit whose `externalID`
    /// is already one of his rows is dropped, because his copy may carry
    /// corrections and carries his use count.
    func testADatabaseHitMatchingASavedRowsExternalIDIsDropped() throws {
        let mine = try library.createItem(
            name: "Protein Wafer",
            brand: "Superyou",
            nutrients: MealNutrients(calories: 398, proteinG: 25),
            defaultPortionQuantity: 40,
            barcode: "8901234567890",
            externalSource: FoodItemSource.openFoodFacts,
            externalID: "8901234567890",
            source: FoodItemSource.openFoodFacts,
            isVerified: true
        )

        let merged = FoodItemSearchMerge.databaseHits([waferDraft()], excluding: [mine])

        XCTAssertTrue(merged.isEmpty, "his row already answers for that product")
    }

    /// The barcode is the second identity, for a row saved from a scan that
    /// never carried a database id.
    func testADatabaseHitMatchingASavedRowsBarcodeIsDropped() throws {
        let mine = try library.createItem(
            name: "Protein Wafer",
            nutrients: MealNutrients(calories: 398),
            defaultPortionQuantity: 40,
            barcode: "8901234567890",
            source: FoodItemSource.barcode
        )

        let merged = FoodItemSearchMerge.databaseHits([waferDraft()], excluding: [mine])

        XCTAssertTrue(merged.isEmpty)
    }

    /// Everything else survives, in the order it arrived. A hit is only hidden
    /// by an identity match, never by a name: two flavours of one bar share a
    /// name often, and hiding one over that would make it unreachable.
    func testUnrelatedHitsSurviveAndKeepTheirOrder() throws {
        let mine = try library.createItem(
            name: "Protein Wafer",
            nutrients: MealNutrients(calories: 398),
            defaultPortionQuantity: 40,
            externalSource: FoodItemSource.openFoodFacts,
            externalID: "8901234567890"
        )
        let otherFlavour = waferDraft(code: "5000000000000")
        let third = waferDraft(code: "4000000000000")

        let merged = FoodItemSearchMerge.databaseHits(
            [waferDraft(), otherFlavour, third],
            excluding: [mine]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.externalID, "5000000000000")
        XCTAssertEqual(merged.last?.externalID, "4000000000000")
    }

    /// An empty library hides nothing, and the guard that short-circuits on
    /// "no identities to match" must not drop the list on its way out.
    func testAnEmptyLibraryHidesNothing() {
        let hits = [waferDraft(), waferDraft(code: "5000000000000")]
        XCTAssertEqual(FoodItemSearchMerge.databaseHits(hits, excluding: []).count, 2)
    }
}
