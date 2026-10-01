import XCTest
import SwiftData
@testable import PersonalDashboard

/// The "high protein per calorie" mark on a saved item, and the ratio it is a
/// judgement about (#690).
///
/// Three properties are worth pinning:
///
/// 1. The ratio is worked out in ONE helper and hides itself at zero calories.
/// 2. The mark is the user's: nothing that refreshes the numbers may clear it.
/// 3. It travels. An archive or a peer written before the field existed must
///    still decode, and a narrow peer must not erase a mark it never heard of.
@MainActor
final class HighProteinPerCalorieTests: XCTestCase {

    // MARK: - The ratio

    func testProteinPer100KcalIsGramsForEveryHundredCalories() throws {
        let yogurt = MealNutrients(calories: 148, proteinG: 15)
        let ratio = try XCTUnwrap(yogurt.proteinPer100Kcal)
        XCTAssertEqual(ratio, 10.135, accuracy: 0.001)
        XCTAssertEqual(MealFormat.proteinPer100Kcal(yogurt), "10.1 g / 100 kcal")
    }

    func testRatioIsTheSameAtEveryPortion() {
        let item = LocalFoodItem(name: "Wafer", calories: 400, proteinG: 25, defaultPortionQuantity: 40)
        XCTAssertEqual(item.defaultNutrients.proteinPer100Kcal!, 6.25, accuracy: 0.0001)
        XCTAssertEqual(item.nutrientsAtBasePortion.proteinPer100Kcal!, 6.25, accuracy: 0.0001)
    }

    func testRatioIsHiddenWithNoCalories() {
        XCTAssertNil(MealNutrients(calories: 0, proteinG: 0).proteinPer100Kcal)
        XCTAssertNil(MealNutrients(calories: 0, proteinG: 5).proteinPer100Kcal)
        XCTAssertNil(MealFormat.proteinPer100Kcal(.zero))
    }

    // MARK: - The service keeps the user's mark

    func testMarkIsWrittenAndOnlyChangedWhenAsked() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let library = FoodItemService(store: store)

        let row = try library.createItem(
            name: "Greek Yogurt", nutrients: MealNutrients(calories: 98, proteinG: 10),
            barcode: "9300601000001", isHighProteinPerCalorie: true
        )
        XCTAssertTrue(row.isHighProteinPerCalorie)

        // An edit that says nothing about the mark leaves it.
        try library.updateItem(row, name: "Greek Yogurt Plain")
        XCTAssertTrue(row.isHighProteinPerCalorie)

        // A re-import of the same packet has no opinion on it either.
        try library.upsert(FoodItemWrite(
            name: "Greek Yogurt", nutrients: MealNutrients(calories: 99, proteinG: 10),
            barcode: "9300601000001"
        ))
        XCTAssertTrue(row.isHighProteinPerCalorie, "a refresh of the numbers must not clear the user's mark")
        XCTAssertEqual(row.calories, 99)

        // Only an explicit false clears it.
        try library.updateItem(row, isHighProteinPerCalorie: false)
        XCTAssertFalse(row.isHighProteinPerCalorie)
    }

    func testNewRowDefaultsToUnmarked() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let row = try FoodItemService(store: store).createItem(name: "Boiled egg")
        XCTAssertFalse(row.isHighProteinPerCalorie)
    }

    // MARK: - The archive

    func testArchiveRoundTripCarriesTheMark() throws {
        var dto = DataArchive.FoodItemDTO()
        dto.clientUUID = "abc"
        dto.name = "Whey"
        dto.isHighProteinPerCalorie = true
        let data = try DataArchive.makeEncoder().encode(dto)
        let back = try DataArchive.makeDecoder().decode(DataArchive.FoodItemDTO.self, from: data)
        XCTAssertEqual(back.isHighProteinPerCalorie, true)
    }

    /// An archive or a peer written before #690 has no key at all. The row must
    /// still decode, and read as unmarked.
    func testArchiveWithoutTheKeyStillDecodes() throws {
        let dto = DataArchive.FoodItemDTO(clientUUID: "abc", name: "Whey")
        let encoded = try DataArchive.makeEncoder().encode(dto)
        guard case .object(var fields) = try JSONValue.from(encoded: encoded) else {
            return XCTFail("DTO did not encode as an object")
        }
        fields.removeValue(forKey: "isHighProteinPerCalorie")
        let narrow = try JSONValue.object(fields).encodedData()
        let back = try DataArchive.makeDecoder().decode(DataArchive.FoodItemDTO.self, from: narrow)
        XCTAssertNil(back.isHighProteinPerCalorie)
        XCTAssertFalse(back.isHighProteinPerCalorie ?? false)
    }

    // MARK: - Sync

    /// THE sync regression. A peer on a build before #690 renames the item; its
    /// payload carries no mark key, and the mark must survive the apply.
    func testNarrowPeerUpsertDoesNotEraseTheMark() throws {
        let container = SwiftDataStore.makeInMemory()
        let context = container.mainContext
        let id = UUID().uuidString.lowercased()
        let item = LocalFoodItem(clientUUID: id, name: "Whey", calories: 120, proteinG: 24,
                                 isHighProteinPerCalorie: true)
        context.insert(item)
        try context.save()

        var dto = DataArchive.FoodItemDTO(clientUUID: id, name: "Whey Isolate")
        dto.calories = 120
        dto.proteinG = 24
        let encoded = try DataArchive.makeEncoder().encode(dto)
        guard case .object(var fields) = try JSONValue.from(encoded: encoded) else {
            return XCTFail("DTO did not encode as an object")
        }
        fields.removeValue(forKey: "isHighProteinPerCalorie")
        XCTAssertNil(fields["isHighProteinPerCalorie"], "the fixture is not a narrow peer if it names the mark")
        let payload = JSONValue.object(fields)
        let op = SyncOp(
            opID: UUID(), deviceUUID: UUID(), lamport: 99, wallClock: Date(),
            entity: "LocalFoodItem", recordID: id, kind: .upsert,
            payload: payload, contentHash: SyncHash.hex(try payload.encodedData())
        )

        let outcome = try SyncApplier(modelContext: context).apply([op], localDeviceUUID: UUID())
        XCTAssertEqual(outcome.applied, 1)

        let rows = try context.fetch(FetchDescriptor<LocalFoodItem>(
            predicate: #Predicate { $0.clientUUID == id }
        ))
        let restored = try XCTUnwrap(rows.first)
        XCTAssertEqual(restored.name, "Whey Isolate", "the peer's own field must win")
        XCTAssertTrue(restored.isHighProteinPerCalorie, "a peer that never heard of the mark must not clear it")
    }
}
