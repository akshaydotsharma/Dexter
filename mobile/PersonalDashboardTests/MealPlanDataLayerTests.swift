import XCTest
import SwiftData
@testable import PersonalDashboard

/// The properties the meal plan's data layer has to hold from its first row
/// (#599).
///
/// Each of these is a failure that would be invisible on screen. A day written
/// as a device-local instant re-buckets the moment the device moves west, and
/// every block on it moves with it. Two snacks sharing a slot index reshuffle
/// between renders, so an edit lands on whichever row the fetch happened to
/// return first. A skipped block that still counted would inflate a planned day
/// and pad the shopping list with food nobody is buying.
@MainActor
final class MealPlanDataLayerTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: MealPlanService!
    private var originalZone: TimeZone!

    /// A fixed Wednesday, 10 September 2025, as a UTC instant.
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    override func setUp() {
        super.setUp()
        originalZone = NSTimeZone.default
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = MealPlanService(store: store)
    }

    override func tearDown() {
        NSTimeZone.default = originalZone
        service = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func rows() throws -> [LocalMealPlanEntry] {
        try store.context.fetch(FetchDescriptor<LocalMealPlanEntry>())
    }

    @discardableResult
    private func plan(
        _ title: String = "Chicken rice",
        type: MealType = .lunch,
        on date: Date? = nil,
        ingredients: [String] = [],
        nutrients: MealNutrients? = nil,
        id: String? = nil
    ) throws -> LocalMealPlanEntry {
        try service.addEntry(
            date: date ?? day,
            mealType: type,
            title: title,
            ingredients: ingredients,
            nutrients: nutrients,
            clientUUID: id
        )
    }

    private func inZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = originalZone }
        try body()
    }

    // MARK: - The day is a day

    /// A block written in Singapore and read in Rome is planned for the same
    /// calendar day.
    ///
    /// This is #506 restated for the plan. A device-local `startOfDay` would
    /// make the stored value an INSTANT, so the same row would answer a
    /// different day once the device moved, and a week of plans would slide by
    /// one.
    func testDayIsAnchoredNotLocal() throws {
        var written: LocalMealPlanEntry?
        try inZone("Asia/Singapore") {
            written = try plan("Laksa", type: .dinner)
        }
        let entry = try XCTUnwrap(written)
        let anchor = entry.date

        try inZone("Europe/Rome") {
            XCTAssertEqual(
                WallClock.startOfStoredDay(anchor),
                anchor,
                "The stored day must already be a UTC anchor, whichever zone wrote it."
            )
            let found = try service.entries(on: WallClock.deviceDay(from: anchor))
            XCTAssertEqual(found.count, 1, "The block must still be found on its own day from another zone.")
        }
    }

    /// The whole point of reading a day back through `deviceDay`: a raw anchor
    /// formatted locally prints the day before, anywhere west of UTC.
    func testDeviceDayRoundTripsTheCalendarDay() throws {
        try inZone("America/Los_Angeles") {
            let entry = try plan("Burrito")
            let calendar = Calendar.current
            XCTAssertEqual(
                calendar.dateComponents([.year, .month, .day], from: entry.deviceDay),
                calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: day)),
                "deviceDay must name the calendar day the block was planned for."
            )
        }
    }

    // MARK: - Several snacks on one day

    /// Three snacks keep three distinct, ascending indices, so the list has a
    /// defined order.
    func testSnacksTakeAscendingSlotIndices() throws {
        let first = try plan("Apple", type: .snack)
        let second = try plan("Yoghurt", type: .snack)
        let third = try plan("Almonds", type: .snack)

        XCTAssertEqual([first.slotIndex, second.slotIndex, third.slotIndex], [0, 1, 2])
        XCTAssertEqual(
            try service.entries(on: day).map(\.title),
            ["Apple", "Yoghurt", "Almonds"],
            "Reading order follows the slot index."
        )
    }

    /// Indices are per meal type, so a lunch does not push a snack down the
    /// list.
    func testSlotIndicesAreScopedToMealType() throws {
        let lunch = try plan("Salad", type: .lunch)
        let snack = try plan("Apple", type: .snack)
        XCTAssertEqual(lunch.slotIndex, 0)
        XCTAssertEqual(snack.slotIndex, 0)
    }

    /// Deleting the middle of three closes the gap rather than leaving a hole
    /// the next add would collide with.
    func testDeleteRenumbersTheSlot() throws {
        try plan("Apple", type: .snack)
        let middle = try plan("Yoghurt", type: .snack)
        try plan("Almonds", type: .snack)

        try service.deleteEntry(middle)

        let remaining = try service.entries(on: day)
        XCTAssertEqual(remaining.map(\.title), ["Apple", "Almonds"])
        XCTAssertEqual(remaining.map(\.slotIndex), [0, 1], "The gap must close.")

        let added = try plan("Banana", type: .snack)
        XCTAssertEqual(added.slotIndex, 2, "A new snack must not reuse an occupied index.")
    }

    /// Moving a block to another day takes it out of the old slot's numbering
    /// AND gives it a place in the new one.
    ///
    /// Renumbering only the destination is the tempting half-fix: it leaves a
    /// hole behind, and the next add on the old day reuses an index that is
    /// still in use further down.
    func testMovingToAnotherDayRenumbersBothSlots() throws {
        try plan("Apple", type: .snack)
        let moved = try plan("Yoghurt", type: .snack)
        try plan("Almonds", type: .snack)

        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        try service.updateEntry(moved, date: nextDay)

        let source = try service.entries(on: day)
        XCTAssertEqual(source.map(\.title), ["Apple", "Almonds"])
        XCTAssertEqual(source.map(\.slotIndex), [0, 1], "The source day must close its gap.")

        let destination = try service.entries(on: nextDay)
        XCTAssertEqual(destination.map(\.title), ["Yoghurt"])
        XCTAssertEqual(destination.first?.slotIndex, 0, "The block joins the end of its new, empty slot.")
    }

    /// A reorder writes the new order down rather than leaving it to a sort.
    func testMoveWithinSlotReordersAndClamps() throws {
        try plan("Apple", type: .snack)
        try plan("Yoghurt", type: .snack)
        let last = try plan("Almonds", type: .snack)

        try service.move(last, toIndex: 0)
        XCTAssertEqual(try service.entries(on: day).map(\.title), ["Almonds", "Apple", "Yoghurt"])

        // Overshooting the end means "put it last", which is what the gesture
        // did. It is not an error.
        try service.move(last, toIndex: 99)
        XCTAssertEqual(try service.entries(on: day).map(\.title), ["Apple", "Yoghurt", "Almonds"])
    }

    // MARK: - Identity

    /// A repeated add carrying the SAME id is a retry of one block, not a
    /// second block (#514).
    func testSuppliedIDMakesTheAddAnUpsert() throws {
        try plan("Chicken rice", id: "abc")
        try plan("Chicken rice with extra chilli", id: "abc")

        let all = try rows()
        XCTAssertEqual(all.count, 1, "A retry with the same id must rewrite the row, not add one.")
        XCTAssertEqual(all.first?.title, "Chicken rice with extra chilli")
    }

    /// No id means insert-only, so two genuinely separate snacks of the same
    /// thing stay two blocks.
    func testNoIDStaysInsertOnly() throws {
        try plan("Apple", type: .snack)
        try plan("Apple", type: .snack)
        XCTAssertEqual(try rows().count, 2)
    }

    // MARK: - Titles and ingredients

    func testEmptyTitleIsRefused() throws {
        XCTAssertThrowsError(try plan("   ")) { error in
            guard case MealPlanServiceError.emptyTitle = error else {
                return XCTFail("Expected emptyTitle, got \(error)")
            }
        }
        XCTAssertEqual(try rows().count, 0)
    }

    /// Ingredients are trimmed, emptied entries dropped, and a case-insensitive
    /// repeat collapsed to the first spelling the user typed.
    func testIngredientsAreCleanedOnWrite() throws {
        let entry = try plan(
            "Rice bowl",
            ingredients: ["  Chicken thigh ", "rice", "", "CHICKEN THIGH", "   ", "cucumber"]
        )
        XCTAssertEqual(entry.ingredients, ["Chicken thigh", "rice", "cucumber"])
    }

    /// An empty array is a real value: it CLEARS the list. Collapsing it to
    /// "leave it alone" is how #444 and #488 made a deletion inexpressible.
    func testEmptyIngredientArrayClearsTheList() throws {
        let entry = try plan("Rice bowl", ingredients: ["rice", "chicken"])
        try service.updateEntry(entry, ingredients: [])
        XCTAssertEqual(entry.ingredients, [])
        XCTAssertNil(entry.ingredientsData, "An empty list stores nothing at all.")
    }

    // MARK: - Numbers

    /// `nil` means "this block has no numbers" and is NOT eight zeros. A fast,
    /// a black coffee and a block nobody typed numbers into are three different
    /// states and only two of them are the same.
    func testNutrientsAreOptionalAndClearable() throws {
        let entry = try plan("Rice bowl", nutrients: MealNutrients(calories: 600, proteinG: 30))
        XCTAssertTrue(entry.hasNutrition)
        XCTAssertEqual(entry.plannedNutrients?.calories, 600)

        try service.updateEntry(entry, nutrients: .some(nil))
        XCTAssertFalse(entry.hasNutrition)
        XCTAssertNil(entry.plannedNutrients)
        XCTAssertEqual(entry.calories, 0, "Clearing must zero the columns too, not leave a stale figure behind.")

        // Passing nothing at all leaves the field alone, which is the other half
        // of the double optional.
        try service.updateEntry(entry, title: "Rice bowl, bigger")
        XCTAssertFalse(entry.hasNutrition)
    }

    func testNegativeNutrientsAreRefused() throws {
        XCTAssertThrowsError(try plan("Rice bowl", nutrients: MealNutrients(calories: -1))) { error in
            guard case MealPlanServiceError.invalidNutrients = error else {
                return XCTFail("Expected invalidNutrients, got \(error)")
            }
        }
    }

    // MARK: - Status

    func testStatusRoundTripsAndSkippedLeavesThePlan() throws {
        let entry = try plan("Rice bowl")
        XCTAssertEqual(entry.statusEnum, .planned)
        XCTAssertTrue(entry.countsTowardsPlan)

        try service.setStatus(.skipped, on: entry)
        XCTAssertEqual(entry.statusEnum, .skipped)
        XCTAssertFalse(entry.countsTowardsPlan, "A skipped block must leave the day's totals.")

        try service.setStatus(.eaten, on: entry)
        XCTAssertTrue(entry.countsTowardsPlan, "An eaten block was the plan and it happened.")
    }

    /// An unknown raw value reads as `.planned` rather than trapping: a block
    /// from a newer build is still a block somebody wrote down, and `.planned`
    /// claims the least about it.
    func testUnknownStatusReadsAsPlanned() throws {
        let entry = try plan("Rice bowl")
        entry.status = "abandoned-in-a-later-build"
        XCTAssertEqual(entry.statusEnum, .planned)
    }

    // MARK: - Copying

    /// A copy is additive, carries the numbers across, and resets the state.
    func testCopyDayIsAdditiveAndResetsState() throws {
        let eaten = try plan("Porridge", type: .breakfast, nutrients: MealNutrients(calories: 350))
        try service.setStatus(.eaten, on: eaten)
        let skipped = try plan("Crisps", type: .snack)
        try service.setStatus(.skipped, on: skipped)
        try plan("Chicken rice", type: .lunch)

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        try plan("Toast", type: .breakfast, on: tomorrow)

        let made = try service.copyDay(from: day, to: tomorrow)

        XCTAssertEqual(made.count, 2, "The skipped block must not be copied.")
        XCTAssertTrue(made.allSatisfy { $0.statusEnum == .planned }, "A copy is something still to do.")
        XCTAssertEqual(made.first?.plannedNutrients?.calories, 350, "The numbers travel with the copy.")

        let destination = try service.entries(on: tomorrow)
        XCTAssertEqual(
            destination.map(\.title),
            ["Toast", "Porridge", "Chicken rice"],
            "The destination keeps what it already had, and the copies join the end of their slots."
        )
        XCTAssertEqual(
            destination.filter { $0.mealTypeEnum == .breakfast }.map(\.slotIndex),
            [0, 1]
        )
        XCTAssertTrue(made.allSatisfy { $0.source == MealPlanSource.copy })
    }

    /// A logged meal becomes a block with its estimate attached, and its items
    /// become the ingredient list.
    func testPlanningALoggedMealCopiesItsNumbers() throws {
        let meals = MealService(store: store)
        let logged = try meals.addMeal(
            date: day,
            mealType: .dinner,
            mealDescription: "Chicken rice",
            nutrients: MealNutrients(calories: 620, proteinG: 34),
            items: [
                MealItemEntry(name: "Poached chicken", portionQuantity: 150, portionUnit: "g"),
                MealItemEntry(name: "Jasmine rice", portionQuantity: 200, portionUnit: "g")
            ],
            source: MealSource.composer
        )

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let block = try service.planLoggedMeal(logged, on: tomorrow)

        XCTAssertEqual(block.title, "Chicken rice")
        XCTAssertEqual(block.mealTypeEnum, .dinner)
        XCTAssertEqual(block.ingredients, ["Poached chicken", "Jasmine rice"])
        XCTAssertEqual(block.plannedNutrients?.calories, 620)
        XCTAssertEqual(block.source, MealPlanSource.copy)
    }

    /// A meal with no numbers at all makes a block with no numbers, never a row
    /// of zeros claiming a fast.
    func testPlanningANeedsDetailMealCarriesNoNumbers() throws {
        let meals = MealService(store: store)
        let logged = try meals.addMeal(
            date: day,
            mealType: .lunch,
            mealDescription: "Something from the canteen",
            source: MealSource.capture,
            needsDetail: true
        )
        let block = try service.planLoggedMeal(logged, on: day)
        XCTAssertNil(block.plannedNutrients)
    }

    func testClearDayRemovesOnlyThatDay() throws {
        try plan("Porridge", type: .breakfast)
        try plan("Chicken rice", type: .lunch)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        try plan("Toast", type: .breakfast, on: tomorrow)

        try service.clearDay(day)

        XCTAssertEqual(try service.entries(on: day).count, 0)
        XCTAssertEqual(try service.entries(on: tomorrow).count, 1)
    }

    // MARK: - Ranges

    /// Both ends are inside the range. A caller asking for a week means seven
    /// days, and a half-open range silently drops the seventh.
    func testRangeFetchIsInclusiveAtBothEnds() throws {
        let calendar = Calendar.current
        for offset in 0..<9 {
            let date = calendar.date(byAdding: .day, value: offset, to: day)!
            try plan("Day \(offset)", on: date)
        }
        let start = day
        let end = calendar.date(byAdding: .day, value: 6, to: day)!
        let found = try service.entries(from: start, to: end)
        XCTAssertEqual(found.count, 7)
        XCTAssertEqual(found.map(\.title).sorted(), (0...6).map { "Day \($0)" }.sorted())
    }
}
