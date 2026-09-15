import XCTest
import SwiftData
@testable import PersonalDashboard

/// The three properties the meal data layer has to hold from the first row it
/// stores (#542).
///
/// All three are the kind that cannot be fixed later. A double-logged lunch is
/// two rows a user has to find and delete by hand; a day written as a local
/// instant re-buckets when the device moves and every total from that day is
/// silently wrong; and a goal kind decided in a view means one screen paints a
/// protein bar red for being over while another paints it green.
@MainActor
final class MealDataLayerTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: MealService!
    private var originalZone: TimeZone!

    override func setUp() {
        super.setUp()
        originalZone = NSTimeZone.default
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = MealService(store: store)
    }

    override func tearDown() {
        NSTimeZone.default = originalZone
        service = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func rows() throws -> [LocalMeal] {
        try store.context.fetch(FetchDescriptor<LocalMeal>())
    }

    @discardableResult
    private func log(
        id: String?,
        description: String = "Chicken rice",
        type: MealType = .lunch,
        calories: Double = 600,
        date: Date = Date(timeIntervalSince1970: 1_757_462_400)
    ) throws -> LocalMeal {
        try service.addMeal(
            date: date,
            loggedAt: date,
            mealType: type,
            mealDescription: description,
            nutrients: MealNutrients(calories: calories, proteinG: 30, carbsG: 70, fatG: 20),
            source: "chat",
            clientUUID: id
        )
    }

    private func inZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        NSTimeZone.default = TimeZone(identifier: identifier)!
        try body()
    }

    /// `yyyy-MM-dd` as the DEVICE would print it, which is what a user reads.
    private func deviceDayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// A device-local instant, built in whatever zone is currently set.
    private func deviceDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = min
        return Calendar.current.date(from: comps)!
    }

    // MARK: - Upsert on clientUUID

    /// The Shortcut case: a capture that times out and is re-run must correct
    /// the meal it already logged, not log lunch twice. Mirrors
    /// `ExpenseCreateIdempotencyTests` because `addMeal` mirrors `addExpense`.
    func testTwoAddsWithOneIDLeaveOneRow() throws {
        let id = UUID().uuidString.lowercased()
        try log(id: id)
        try log(id: id)
        XCTAssertEqual(try rows().count, 1, "a repeated add of one meal is a retry, not a second meal")
    }

    /// The surviving row is the one the caller last submitted: a retry usually
    /// exists because something about the first estimate needed changing.
    func testTheSecondAddWins() throws {
        let id = UUID().uuidString.lowercased()
        try log(id: id, description: "Chicken rice", calories: 600)
        try log(id: id, description: "Chicken rice, extra rice", type: .dinner, calories: 900)

        let all = try rows()
        XCTAssertEqual(all.count, 1)
        let row = try XCTUnwrap(all.first)
        XCTAssertEqual(row.mealDescription, "Chicken rice, extra rice")
        XCTAssertEqual(row.calories, 900)
        XCTAssertEqual(row.mealTypeEnum, .dinner)
    }

    /// `createdAt` belongs to the moment the row was made, so a retry keeps the
    /// first attempt's stamp.
    func testARetryKeepsTheFirstCreatedAt() throws {
        let id = UUID().uuidString.lowercased()
        let stamp = try log(id: id).createdAt
        try log(id: id, calories: 750)
        XCTAssertEqual(try rows().first?.createdAt, stamp)
    }

    /// The row keeps its identity, so a sync record or an open editor pointing
    /// at it still resolves.
    func testTheRowKeepsItsIdentity() throws {
        let id = UUID().uuidString.lowercased()
        try log(id: id)
        try log(id: id, calories: 750)
        XCTAssertEqual(try rows().first?.clientUUID, id)
    }

    /// Insert-only for a caller that passes no id. Two genuinely separate
    /// snacks of the same thing are two meals.
    func testAddsWithoutAnIDEachInsert() throws {
        try log(id: nil)
        try log(id: nil)
        XCTAssertEqual(try rows().count, 2)
    }

    /// The nutrient guard rejects BEFORE touching the row an id names, so a
    /// retry carrying a bad estimate cannot corrupt the good row.
    func testANegativeRetryLeavesTheStoredRowAlone() throws {
        let id = UUID().uuidString.lowercased()
        try log(id: id, calories: 600)
        XCTAssertThrowsError(try log(id: id, calories: -1))
        let all = try rows()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.calories, 600)
    }

    // MARK: - The day is a day, not a moment

    /// The defect this pins: a meal logged on Tuesday evening in Singapore must
    /// still report Tuesday after the device moves to Rome or New York. Written
    /// as a device-local `startOfDay` (the pre-#506 `LocalExpense` convention)
    /// it reports Monday west of UTC, and a whole day's calories re-bucket.
    func testAMealsDayDoesNotMoveWithTheDeviceTimezone() throws {
        var meal: LocalMeal!
        try inZone("Asia/Singapore") {
            meal = try log(id: nil, date: deviceDate(2026, 9, 9, 20, 30))
        }

        XCTAssertTrue(
            WallClock.isDayAnchored(meal.date),
            "a meal's day must be stored as a UTC anchor, not a device-local startOfDay"
        )

        for zone in ["Asia/Singapore", "Europe/Rome", "America/New_York", "Pacific/Honolulu"] {
            inZone(zone) {
                XCTAssertEqual(
                    deviceDayString(meal.deviceDay), "2026-09-09",
                    "the meal reports a different day in \(zone)"
                )
            }
        }
    }

    /// The read path agrees with the write path from another zone: asking for
    /// "9 September" in Rome finds the meal logged on 9 September in Singapore.
    func testFetchingADayFindsAMealLoggedInAnotherZone() throws {
        try inZone("Asia/Singapore") {
            try log(id: nil, date: deviceDate(2026, 9, 9, 20, 30))
        }
        try inZone("America/New_York") {
            XCTAssertEqual(try service.meals(on: deviceDate(2026, 9, 9, 9, 0)).count, 1)
            XCTAssertEqual(try service.meals(on: deviceDate(2026, 9, 8, 9, 0)).count, 0)
            XCTAssertEqual(try service.meals(on: deviceDate(2026, 9, 10, 9, 0)).count, 0)
        }
    }

    /// A range reads as calendar days at both ends, inclusive: asking for the
    /// 8th to the 10th returns all three days, not two and a bit.
    func testARangeIsInclusiveAtBothEnds() throws {
        try inZone("Asia/Singapore") {
            for day in 8...11 {
                try log(id: nil, date: deviceDate(2026, 9, day, 12, 0))
            }
            XCTAssertEqual(
                try service.meals(from: deviceDate(2026, 9, 8, 23, 0), to: deviceDate(2026, 9, 10, 1, 0)).count,
                3
            )
        }
    }

    /// The targets record anchors its day too. `effectiveFrom` is unread on this
    /// build, which is exactly why it is worth pinning: a field nothing reads is
    /// a field nothing would catch writing wrong.
    func testTargetsAnchorTheirEffectiveFromDay() throws {
        var targets: MealTargets!
        try inZone("Asia/Singapore") {
            targets = try service.saveTargets(
                targets: MealNutrients(calories: 2200, proteinG: 140),
                ageYears: 36, biologicalSex: "male", heightCm: 178, weightKg: 78,
                activityLevel: "moderate", goal: "maintain",
                rationale: "Mifflin-St Jeor at a moderate multiplier.",
                effectiveFrom: deviceDate(2026, 9, 9, 20, 30)
            )
        }
        XCTAssertTrue(WallClock.isDayAnchored(targets.effectiveFrom))
        inZone("America/New_York") {
            XCTAssertEqual(deviceDayString(targets.deviceEffectiveFrom), "2026-09-09")
        }
    }

    /// Saving targets twice leaves one record, so no reader has to decide which
    /// of two sets of targets a day is judged against.
    func testSavingTargetsTwiceLeavesOneRecord() throws {
        for calories in [2200.0, 2400.0] {
            try service.saveTargets(
                targets: MealNutrients(calories: calories, proteinG: 140),
                ageYears: 36, biologicalSex: "male", heightCm: 178, weightKg: 78,
                activityLevel: "moderate", goal: "maintain", rationale: "derived"
            )
        }
        let all = try store.context.fetch(FetchDescriptor<MealTargets>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.calories, 2400)
        XCTAssertEqual(try service.targets()?.calories, 2400)
    }

    // MARK: - Goal kinds

    /// Every bar colour, verdict and callout in the feature reads this one
    /// property, so a wrong answer here is wrong everywhere at once.
    func testGoalKindForAllEightNutrients() {
        XCTAssertEqual(Nutrient.allCases.count, 8)

        for nutrient in [Nutrient.protein, .fibre] {
            XCTAssertEqual(nutrient.goalKind, .floor, "\(nutrient.rawValue) is a minimum to reach")
        }
        for nutrient in [Nutrient.sugar, .sodium, .saturatedFat] {
            XCTAssertEqual(nutrient.goalKind, .ceiling, "\(nutrient.rawValue) is a limit to stay under")
        }
        for nutrient in [Nutrient.calories, .carbs, .fat] {
            XCTAssertEqual(nutrient.goalKind, .range, "\(nutrient.rawValue) is wrong far under as well as far over")
        }
    }

    /// The goal kinds partition the eight: no nutrient is missing a kind and
    /// none has two. A `switch` cannot get this wrong today, but the assertion
    /// is what keeps a ninth nutrient from being added without a decision.
    func testEveryNutrientHasExactlyOneGoalKind() {
        let byKind = Dictionary(grouping: Nutrient.allCases, by: \.goalKind)
        XCTAssertEqual(byKind[.floor]?.count, 2)
        XCTAssertEqual(byKind[.ceiling]?.count, 3)
        XCTAssertEqual(byKind[.range]?.count, 3)
    }

    /// Four meal types, not five. Drinks fold into snack.
    func testThereAreFourMealTypes() {
        XCTAssertEqual(MealType.allCases, [.breakfast, .lunch, .dinner, .snack])
    }

    // MARK: - The registration chain

    /// The #449 lesson, applied to the two models this ticket adds: a model in
    /// `schemaModels` and not in `exportedModels` is in the store, in no backup,
    /// and invisible to sync. `SchemaCoverageTests` proves the rule; this names
    /// the two rows that rule has to cover.
    func testBothMealModelsAreCarriedByTheArchiveAndSync() {
        for name in ["LocalMeal", "MealTargets"] {
            XCTAssertTrue(DataArchive.exportedModels.contains(name), "\(name) is in no backup")
            XCTAssertTrue(SyncRecordMapper.syncedEntities.contains(name), "\(name) does not sync")
        }
    }

    /// A meal survives the wire format, including the part easiest to lose: the
    /// per-dish blob, byte for byte.
    func testAMealRoundTripsThroughTheArchive() throws {
        let items = [
            MealItemEntry(name: "Chicken rice", portionQuantity: 1, portionUnit: "bowl", calories: 600, proteinG: 30),
            MealItemEntry(name: "Teh tarik", portionQuantity: 1, portionUnit: "cup", calories: 120, sugarG: 18)
        ]
        let itemsData = try JSONEncoder().encode(items)
        let dto = DataArchive.MealDTO(
            clientUUID: "abc", date: Date(timeIntervalSince1970: 1_757_462_400),
            loggedAt: Date(timeIntervalSince1970: 1_757_507_400),
            mealType: "lunch", mealDescription: "chicken rice and a teh tarik",
            calories: 720, proteinG: 30, carbsG: 95, fatG: 22,
            fibreG: 3, sugarG: 18, sodiumMg: 1200, satFatG: 6,
            itemsData: itemsData, confidence: 0.7, source: "chat",
            needsDetail: true, isSuspect: false, suspectReason: nil,
            assumptionsNote: "assumed one bowl", containsAlcohol: true,
            groundingSourcesData: nil,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)
        )
        var payload = DataArchive.Payload.empty
        payload.meals = [dto]

        let encoded = try DataArchive.makeEncoder().encode(payload)
        let decoded = try DataArchive.makeDecoder().decode(DataArchive.Payload.self, from: encoded)
        let back = try XCTUnwrap(decoded.meals?.first)

        XCTAssertEqual(back.clientUUID, "abc")
        XCTAssertEqual(back.date, dto.date)
        XCTAssertEqual(back.loggedAt, dto.loggedAt)
        XCTAssertEqual(back.mealType, "lunch")
        XCTAssertEqual(back.calories, 720)
        XCTAssertEqual(back.sodiumMg, 1200)
        XCTAssertEqual(back.itemsData, itemsData, "the per-dish breakdown must survive verbatim")
        XCTAssertTrue(back.needsDetail)
        XCTAssertEqual(back.assumptionsNote, "assumed one bowl")
        XCTAssertEqual(back.containsAlcohol, true, "the alcohol flag must survive the wire format (#555)")

        let restored = try JSONDecoder().decode([MealItemEntry].self, from: try XCTUnwrap(back.itemsData))
        XCTAssertEqual(restored.map(\.name), ["Chicken rice", "Teh tarik"])
        XCTAssertEqual(restored.first?.portionDescription, "1 bowl")
    }

    /// The whole chain, end to end: seed a store, write a real archive, then
    /// restore it into an EMPTY store and check both models came back.
    ///
    /// This is the test the registration work exists for. Every cheaper
    /// assertion above passes with the `commit` insert loops missing entirely:
    /// the model would be exported, claimed in the manifest, counted, and then
    /// restored as nothing at all. Only a round trip through a fresh store
    /// notices.
    func testAnArchiveRoundTripRestoresMealsAndTargetsIntoAnEmptyStore() async throws {
        let meal = try log(id: "meal-round-trip", description: "Laksa", calories: 640)
        meal.items = [MealItemEntry(name: "Laksa", portionQuantity: 1, portionUnit: "bowl", calories: 640)]
        try store.context.save()
        try service.saveTargets(
            targets: MealNutrients(calories: 2200, proteinG: 140, sodiumMg: 2300),
            ageYears: 36, biologicalSex: "male", heightCm: 178, weightKg: 78,
            activityLevel: "moderate", goal: "maintain",
            rationale: "Mifflin-St Jeor at a moderate multiplier.",
            handEdited: [.protein],
            clientUUID: "targets-round-trip"
        )

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        let preview = try importer.preview(url: archiveURL)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.meals]?.new, 1)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.mealTargets]?.new, 1)
        try importer.commit(preview: preview)

        let restoredMeals = try empty.context.fetch(FetchDescriptor<LocalMeal>())
        XCTAssertEqual(restoredMeals.count, 1)
        let restoredMeal = try XCTUnwrap(restoredMeals.first)
        XCTAssertEqual(restoredMeal.clientUUID, "meal-round-trip")
        XCTAssertEqual(restoredMeal.mealDescription, "Laksa")
        XCTAssertEqual(restoredMeal.calories, 640)
        XCTAssertEqual(restoredMeal.date, meal.date, "the day must come back as the same UTC anchor")
        XCTAssertEqual(restoredMeal.loggedAt, meal.loggedAt)
        XCTAssertEqual(restoredMeal.items.map(\.name), ["Laksa"])

        let restoredTargets = try empty.context.fetch(FetchDescriptor<MealTargets>())
        XCTAssertEqual(restoredTargets.count, 1)
        let back = try XCTUnwrap(restoredTargets.first)
        XCTAssertEqual(back.calories, 2200)
        XCTAssertEqual(back.sodiumMg, 2300)
        XCTAssertEqual(back.weightKg, 78, "the derivation inputs restore, or the targets cannot be re-derived")
        XCTAssertEqual(back.goal, "maintain")
        XCTAssertEqual(back.handEdited, [.protein], "a hand-edited override must survive a restore")
    }

    /// Sync emits one record per meal and one per targets row, keyed on the
    /// String `clientUUID` each model actually declares unique. Keying either on
    /// the wrong field would collapse every meal onto one record.
    func testSyncEmitsARecordPerMealAndPerTargetsRow() throws {
        var payload = DataArchive.Payload.empty
        payload.meals = [
            DataArchive.MealDTO(
                clientUUID: "meal-1", date: Date(timeIntervalSince1970: 0), loggedAt: Date(timeIntervalSince1970: 0),
                mealType: "lunch", mealDescription: "a", calories: 1, proteinG: 0, carbsG: 0, fatG: 0,
                fibreG: 0, sugarG: 0, sodiumMg: 0, satFatG: 0, itemsData: nil, confidence: 0.5,
                source: "chat", needsDetail: false, isSuspect: false, suspectReason: nil,
                assumptionsNote: nil, containsAlcohol: false, groundingSourcesData: nil,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
            ),
            DataArchive.MealDTO(
                clientUUID: "meal-2", date: Date(timeIntervalSince1970: 0), loggedAt: Date(timeIntervalSince1970: 0),
                mealType: "dinner", mealDescription: "b", calories: 2, proteinG: 0, carbsG: 0, fatG: 0,
                fibreG: 0, sugarG: 0, sodiumMg: 0, satFatG: 0, itemsData: nil, confidence: 0.5,
                source: "chat", needsDetail: false, isSuspect: false, suspectReason: nil,
                assumptionsNote: nil, containsAlcohol: false, groundingSourcesData: nil,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
            )
        ]
        payload.mealTargets = [
            DataArchive.MealTargetsDTO(
                clientUUID: "targets-1", calories: 2200, proteinG: 140, carbsG: 250, fatG: 70,
                fibreG: 30, sugarG: 50, sodiumMg: 2300, satFatG: 20,
                ageYears: 36, biologicalSex: "male", heightCm: 178, weightKg: 78,
                activityLevel: "moderate", goal: "maintain", rationale: "derived",
                effectiveFrom: Date(timeIntervalSince1970: 0), handEditedData: nil,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
            )
        ]

        let records = try SyncRecordMapper.records(from: payload)
        XCTAssertEqual(records.filter { $0.entity == "LocalMeal" }.map(\.recordID), ["meal-1", "meal-2"])
        XCTAssertEqual(records.filter { $0.entity == "MealTargets" }.map(\.recordID), ["targets-1"])
    }
}
