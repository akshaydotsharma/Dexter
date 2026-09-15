import XCTest
import SwiftData
@testable import PersonalDashboard

/// The properties `log_meal` / `update_meal` / `delete_meal` have to hold from
/// the first call either surface makes (#546).
///
/// Every one of them is a failure the user cannot see happening. A retried
/// Shortcut that logs lunch twice, a meal that lands on the wrong day, a
/// duplicate silently swallowed, a context block that grows without bound: none
/// of them throws, none of them looks wrong on screen, and all of them are
/// found weeks later when a day's total is inexplicable.
@MainActor
final class MealChatToolTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!
    /// The chat wiring. Identical to the capture one except for the provenance
    /// it stamps, which is the point of `captureExecutor` below.
    private var executor: ExecuteDraftAction!
    private var captureExecutor: ExecuteDraftAction!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        meals = MealService(store: store)
        executor = ExecuteDraftAction(store: store, mealSource: MealSource.chat)
        captureExecutor = ExecuteDraftAction(store: store, mealSource: MealSource.capture)
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        MealToolRequestProbe.reset()
        captureExecutor = nil
        executor = nil
        meals = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// One well-formed item, in the exact shape the tool schema advertises.
    ///
    /// The macros have to ADD UP to the calories within the guards' 20%
    /// tolerance, or `MealEstimateGuards` flags the meal as suspect and holds
    /// it out of every total — which would make a fixture silently test the
    /// exclusion path instead of the one it names.
    private func item(
        name: String = "Poached egg",
        grams: Double = 100,
        calories: Double = 143,
        protein: Double = 12.6,
        carbs: Double = 0.7,
        fat: Double = 9.5
    ) -> AnthropicJSONValue {
        .object([
            "name": .string(name),
            "portion_quantity": .double(grams),
            "portion_unit": .string("g"),
            "calories": .double(calories),
            "protein_g": .double(protein),
            "carbs_g": .double(carbs),
            "fat_g": .double(fat),
            "fibre_g": .double(0),
            "sugar_g": .double(0.4),
            "sodium_mg": .double(142),
            "saturated_fat_g": .double(3.1)
        ])
    }

    private func logInput(
        id: String,
        description: String = "two poached eggs",
        type: MealType = .breakfast,
        day: Date = Date(),
        items: [AnthropicJSONValue]? = nil,
        noFood: Bool = false,
        confidence: String = "medium"
    ) -> [String: AnthropicJSONValue] {
        [
            "id": .string(id),
            "meal_type": .string(type.rawValue),
            "description": .string(description),
            "date": .string(Self.isoDay.string(from: WallClock.dayAnchor(from: day))),
            "items": .array(items ?? [item()]),
            "contains_alcohol": .bool(false),
            "confidence": .string(confidence),
            "assumptions": .string("Two medium eggs."),
            "no_food_identified": .bool(noFood)
        ]
    }

    private func rows() throws -> [LocalMeal] {
        try store.context.fetch(FetchDescriptor<LocalMeal>())
    }

    // MARK: - The upsert is what makes a retry safe

    /// A Shortcut that times out and is re-run sends the SAME tool call again,
    /// id included. That has to leave one row.
    ///
    /// This is the single property the whole capture path rests on: the
    /// alternative is a user who cannot tell a double-logged lunch from a
    /// genuinely large one, because both read as one number.
    func testRetryingTheSameIDLeavesOneRow() async throws {
        let id = UUID().uuidString.lowercased()

        let first = try await captureExecutor.run(actionType: .logMeal, input: logInput(id: id))
        let second = try await captureExecutor.run(actionType: .logMeal, input: logInput(id: id))

        XCTAssertEqual(try rows().count, 1, "A retried log with the same id must not make a second meal")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, id)
        // A retry is a repeat of one create, so it reports the same thing it
        // reported the first time. A second dialog reading "updated" would tell
        // the user something changed when nothing did.
        XCTAssertEqual(second.action, ActionString.created)
        XCTAssertEqual(second.title, first.title)
    }

    /// The retry must not report ITSELF as a near-duplicate.
    ///
    /// The duplicate check runs against the day's stored rows, so reading them
    /// after the write would find the row the retry had just rewritten and flag
    /// the log as a duplicate of itself — a warning about a problem that does
    /// not exist, on the one path that cannot answer back.
    func testRetryDoesNotFlagItselfAsADuplicate() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try await captureExecutor.run(actionType: .logMeal, input: logInput(id: id))
        let second = try await captureExecutor.run(actionType: .logMeal, input: logInput(id: id))

        XCTAssertNil(second.meal?.duplicateMinutesAgo)
    }

    /// Two genuinely separate calls with different ids stay two rows, and the
    /// second one says so.
    func testNearDuplicateKeepsBothRowsAndSaysSo() async throws {
        let outcome1 = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), description: "flat white", type: .snack)
        )
        let outcome2 = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), description: "a flat white", type: .snack)
        )

        XCTAssertEqual(try rows().count, 2, "A possible duplicate is flagged, never blocked")
        XCTAssertNil(outcome1.meal?.duplicateMinutesAgo)
        XCTAssertNotNil(
            outcome2.meal?.duplicateMinutesAgo,
            "The second log of the same drink minutes later must be flagged"
        )
        XCTAssertTrue(
            (outcome2.title ?? "").contains("Similar to a meal"),
            "The Shortcut dialog must mention the near-duplicate: \(outcome2.title ?? "")"
        )
    }

    /// The same branch on the capture path, which is the one that matters: chat
    /// shows a card the user can read, the Shortcut has one spoken sentence.
    func testNearDuplicateOnTheCapturePathAlsoKeepsBothAndSaysSo() async throws {
        _ = try await captureExecutor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), description: "teh tarik", type: .snack)
        )
        let second = try await captureExecutor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), description: "a teh tarik", type: .snack)
        )

        XCTAssertEqual(try rows().count, 2)
        XCTAssertNotNil(second.meal?.duplicateMinutesAgo)
        XCTAssertTrue((second.title ?? "").contains("Similar to a meal logged"))
        // Both paths stamp their own provenance. A meal logged hands-free is
        // the one most worth being able to find later.
        let sources = Set(try rows().map(\.source))
        XCTAssertEqual(sources, [MealSource.capture])
    }

    // MARK: - Dates

    /// "I had pasta last night" sent in the morning lands on yesterday, and the
    /// summary names the date. A silently misdated meal corrupts two days at
    /// once and neither one looks wrong.
    func testAnExplicitYesterdayLandsOnYesterdayAndTheCardSaysSo() async throws {
        let yesterday = WallClock.deviceDay(
            from: WallClock.storedDay(WallClock.todayAnchor(), byAdding: -1)
        )
        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), description: "pasta", type: .dinner, day: yesterday)
        )

        let row = try XCTUnwrap(try rows().first)
        XCTAssertTrue(
            WallClock.isSameStoredDay(row.date, WallClock.dayAnchor(from: yesterday)),
            "A meal dated yesterday must be stored on yesterday"
        )
        let summary = try XCTUnwrap(outcome.meal)
        XCTAssertFalse(summary.isToday)
        XCTAssertEqual(summary.dayLabel(), "yesterday")
        XCTAssertTrue(
            summary.dialogSentence().contains("for yesterday"),
            "The dialog must name a day that is not today: \(summary.dialogSentence())"
        )
    }

    /// A model-emitted future date clamps to today, and the clamp is stated.
    ///
    /// A meal is a record of something already eaten, so a future date is
    /// always a model error. Storing it hides the meal in a day nobody looks at
    /// and takes it out of today's totals without any sign that it happened.
    func testAFutureDateClampsToTodayAndIsReported() async throws {
        let future = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), day: future)
        )

        let row = try XCTUnwrap(try rows().first)
        XCTAssertTrue(WallClock.isSameStoredDay(row.date, WallClock.todayAnchor()))
        let summary = try XCTUnwrap(outcome.meal)
        XCTAssertTrue(summary.isToday)
        XCTAssertTrue(summary.wasDateClampedFromFuture)
        XCTAssertTrue(
            summary.dialogSentence().contains("future"),
            "A clamp must be spoken, not silent: \(summary.dialogSentence())"
        )
    }

    /// The clamp rule itself, at the boundary. Today is never "the future",
    /// however late in the day it is read.
    func testResolveDayClampsOnlyStrictlyFutureDays() {
        let now = Date()
        let today = Self.isoDay.string(from: WallClock.dayAnchor(from: now))
        let tomorrow = Self.isoDay.string(
            from: WallClock.storedDay(WallClock.dayAnchor(from: now), byAdding: 1)
        )

        let sameDay = MealToolSchema.resolveDay(isoDate: today, now: now)
        XCTAssertFalse(sameDay.wasClampedFromFuture)
        XCTAssertTrue(WallClock.isSameStoredDay(WallClock.dayAnchor(from: sameDay.day), WallClock.dayAnchor(from: now)))

        let ahead = MealToolSchema.resolveDay(isoDate: tomorrow, now: now)
        XCTAssertTrue(ahead.wasClampedFromFuture)
        XCTAssertTrue(WallClock.isSameStoredDay(WallClock.dayAnchor(from: ahead.day), WallClock.dayAnchor(from: now)))
    }

    /// An absent or unparseable date falls back rather than failing. A meal
    /// with no day cannot be counted at all.
    func testAnUnparseableDateFallsBackToTheCallersDay() {
        let now = Date()
        XCTAssertFalse(MealToolSchema.resolveDay(isoDate: nil, now: now).wasClampedFromFuture)
        XCTAssertTrue(WallClock.isSameStoredDay(
            WallClock.dayAnchor(from: MealToolSchema.resolveDay(isoDate: "not a date", now: now).day),
            WallClock.dayAnchor(from: now)
        ))

        let fallback = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let resolved = MealToolSchema.resolveDay(isoDate: "", now: now, fallback: fallback)
        XCTAssertTrue(WallClock.isSameStoredDay(
            WallClock.dayAnchor(from: resolved.day),
            WallClock.dayAnchor(from: fallback)
        ))
    }

    // MARK: - The 1am snack

    /// A snack logged at 01:30 is OFFERED to yesterday and never moved.
    ///
    /// The asymmetry is the whole rule. An offer declined costs one tap; a
    /// wrong automatic move is invisible on both days and the user has no
    /// reason to go looking for it.
    func testSmallHoursSnackIsOfferedToYesterdayAndNotMoved() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let oneThirty = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 30))!
        let today = WallClock.dayAnchor(from: oneThirty)

        XCTAssertTrue(MealToolSchema.offersYesterdayMove(
            mealType: .snack, day: today, now: oneThirty, calendar: calendar
        ))
        XCTAssertTrue(MealToolSchema.offersYesterdayMove(
            mealType: .dinner, day: today, now: oneThirty, calendar: calendar
        ))

        // The row itself stays on today. Offering is not moving.
        let row = try meals.addMeal(
            date: oneThirty,
            loggedAt: oneThirty,
            mealType: .snack,
            mealDescription: "crisps",
            source: MealSource.chat
        )
        XCTAssertTrue(WallClock.isSameStoredDay(row.date, today))
    }

    /// Breakfast in the small hours is a stated intention, not an ambiguity,
    /// and 09:00 is not the small hours at all.
    func testTheYesterdayOfferIsNarrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let oneThirty = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 1, minute: 30))!
        let nine = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 9))!
        let today = WallClock.dayAnchor(from: oneThirty)

        XCTAssertFalse(MealToolSchema.offersYesterdayMove(
            mealType: .breakfast, day: today, now: oneThirty, calendar: calendar
        ))
        XCTAssertFalse(MealToolSchema.offersYesterdayMove(
            mealType: .snack, day: today, now: nine, calendar: calendar
        ))
        // A meal already dated yesterday has nothing to offer.
        let yesterday = WallClock.storedDay(today, byAdding: -1)
        XCTAssertFalse(MealToolSchema.offersYesterdayMove(
            mealType: .snack, day: yesterday, now: oneThirty, calendar: calendar
        ))
    }

    // MARK: - Correction

    /// "That latte was oat milk" replaces the meal's values without leaving a
    /// second row behind.
    func testUpdateReplacesInPlace() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: id, description: "flat white", type: .snack)
        )

        var update = logInput(
            id: id,
            description: "oat milk latte",
            type: .snack,
            items: [item(name: "Oat milk latte", grams: 240, calories: 190, protein: 6, carbs: 27, fat: 6)]
        )
        update.removeValue(forKey: "date")
        let outcome = try await executor.run(actionType: .updateMeal, input: update)

        XCTAssertEqual(try rows().count, 1, "A correction must not create a second meal")
        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.mealDescription, "oat milk latte")
        XCTAssertEqual(row.calories, 190, accuracy: 0.01)
        XCTAssertEqual(outcome.action, ActionString.updated)
    }

    /// A correction that carries no items at all is refused rather than
    /// honoured. The guards read an empty array as "no food identified", so
    /// letting it through would zero a perfectly good meal and call it a
    /// correction.
    func testUpdateWithoutItemsIsRefused() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try await executor.run(actionType: .logMeal, input: logInput(id: id))

        do {
            _ = try await executor.run(actionType: .updateMeal, input: [
                "id": .string(id),
                "description": .string("something else")
            ])
            XCTFail("An itemless correction must not be applied")
        } catch let error as DraftExecutionError {
            guard case .invalidArgument(let field, _) = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
            XCTAssertEqual(field, "items")
        }
        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.calories, 143, accuracy: 0.01, "The original estimate must survive a refused correction")
    }

    func testDeleteRemovesTheRow() async throws {
        let id = UUID().uuidString.lowercased()
        _ = try await executor.run(actionType: .logMeal, input: logInput(id: id))
        let outcome = try await executor.run(actionType: .deleteMeal, input: ["id": .string(id)])

        XCTAssertTrue(try rows().isEmpty)
        XCTAssertEqual(outcome.action, ActionString.deleted)
    }

    /// Chat holds a delete back for a tap; add and update run straight through.
    ///
    /// The gate is a property of the ACTION and is read by the chat layer only.
    /// `ExecuteDraftAction` must stay unaware of it, or the Shortcut would stop
    /// being able to delete — which is a standing decision, not an oversight.
    func testOnlyDeleteMealIsHeldBackInChat() {
        XCTAssertTrue(DraftActionType.deleteMeal.requiresChatConfirmation)
        XCTAssertFalse(DraftActionType.logMeal.requiresChatConfirmation)
        XCTAssertFalse(DraftActionType.updateMeal.requiresChatConfirmation)
        XCTAssertFalse(DraftActionType.addExpense.requiresChatConfirmation)
    }

    // MARK: - No numbers is still a meal

    /// A description nothing can be estimated from still saves, with zero
    /// nutrients and a needs-detail flag, and the dialog says why there is no
    /// number. Losing the fact that you ate is worse than losing the number.
    func testAVagueDescriptionThroughCaptureSavesWithNoNumbers() async throws {
        let outcome = try await captureExecutor.run(
            actionType: .logMeal,
            input: logInput(
                id: UUID().uuidString.lowercased(),
                description: "food",
                type: .lunch,
                items: [],
                noFood: true
            )
        )

        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.mealDescription, "food")
        XCTAssertTrue(row.needsDetail)
        XCTAssertEqual(row.calories, 0)
        XCTAssertEqual(row.nutrients, .zero)

        let sentence = try XCTUnwrap(outcome.meal).dialogSentence()
        XCTAssertTrue(sentence.contains("Logged lunch"))
        XCTAssertTrue(
            sentence.contains("more detail"),
            "A meal with no number must say why: \(sentence)"
        )
    }

    /// An empty description writes nothing at all. A meal row whose text is
    /// blank cannot be corrected later, because there is nothing to correct.
    func testAnEmptyDescriptionWritesNoRow() async throws {
        do {
            _ = try await executor.run(actionType: .logMeal, input: [
                "id": .string(UUID().uuidString.lowercased()),
                "meal_type": .string("lunch"),
                "description": .string("   "),
                "items": .array([item()])
            ])
            XCTFail("A meal with no description must not be written")
        } catch is DraftExecutionError {
            // expected
        }
        XCTAssertTrue(try rows().isEmpty, "A failed log must leave no half meal behind")
    }

    // MARK: - The spoken sentence

    /// "Logged lunch, about 640 calories and 34 grams of protein." — a number
    /// and a macro, short enough to be spoken.
    func testTheDialogNamesCaloriesAndAMacroInUnderTwentyWords() async throws {
        let outcome = try await captureExecutor.run(
            actionType: .logMeal,
            input: logInput(
                id: UUID().uuidString.lowercased(),
                description: "chicken rice",
                type: .lunch,
                items: [item(name: "Chicken rice", grams: 400, calories: 640, protein: 34, carbs: 78, fat: 21)],
                confidence: "high"
            )
        )

        let summary = try XCTUnwrap(outcome.meal)
        let base = summary.baseSentence()
        XCTAssertTrue(base.contains("640"), base)
        XCTAssertTrue(base.contains("34"), base)
        XCTAssertTrue(base.contains("protein"), base)
        let words = base.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        XCTAssertLessThan(words, 20, "The spoken sentence must stay short: \(base)")
    }

    /// A low-confidence estimate says so. The number is still given, because a
    /// rough number the user can correct beats no number at all.
    func testALowConfidenceEstimateIsCalledRough() async throws {
        let outcome = try await captureExecutor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased(), confidence: "low")
        )
        XCTAssertTrue(
            try XCTUnwrap(outcome.meal).baseSentence().contains("Rough estimate"),
            "A low-confidence log must not be reported as if it were measured"
        )
    }

    // MARK: - What is left today

    /// The remaining-today line counts the meal that was just logged. A line
    /// that ignored the log which produced it would answer the wrong question.
    func testRemainingTodayIncludesTheMealJustLogged() async throws {
        try meals.saveTargets(
            targets: MealNutrients(calories: 2000, proteinG: 140),
            ageYears: 36,
            biologicalSex: "male",
            heightCm: 178,
            weightKg: 76,
            activityLevel: "moderate",
            goal: "maintain",
            rationale: "test fixture"
        )

        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(
                id: UUID().uuidString.lowercased(),
                items: [item(name: "Chicken rice", grams: 400, calories: 640, protein: 40, carbs: 70, fat: 22)]
            )
        )

        let summary = try XCTUnwrap(outcome.meal)
        XCTAssertEqual(try XCTUnwrap(summary.caloriesRemaining), 1360, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.proteinRemaining), 100, accuracy: 0.01)
    }

    /// No targets means no line, not a line reading zero. An unset target is
    /// not a target of zero, and "0 left" reads as a day already blown.
    func testNoTargetsMeansNoRemainingLine() async throws {
        let outcome = try await executor.run(
            actionType: .logMeal,
            input: logInput(id: UUID().uuidString.lowercased())
        )
        XCTAssertNil(try XCTUnwrap(outcome.meal).caloriesRemaining)
        XCTAssertNil(try XCTUnwrap(outcome.meal).proteinRemaining)
    }

    // MARK: - The context block

    /// The block carries today's rows WITH their UUIDs, the eight targets on
    /// one line, and a single seven-day rollup — and no historical rows at all.
    ///
    /// This block is added to every prompt in every section of the app,
    /// permanently. Injecting a week of individual rows to answer "am I short
    /// on protein this week" would inflate every chat turn everywhere to answer
    /// what the rollup already answers.
    func testContextBlockCarriesTodayTargetsAndOneRollupLine() async throws {
        let today = try meals.addMeal(
            mealType: .breakfast,
            mealDescription: "two poached eggs on toast",
            nutrients: MealNutrients(calories: 420, proteinG: 18, carbsG: 34, fatG: 22),
            source: MealSource.chat,
            clientUUID: UUID().uuidString.lowercased()
        )
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let historical = try meals.addMeal(
            date: threeDaysAgo,
            loggedAt: threeDaysAgo,
            mealType: .dinner,
            mealDescription: "laksa with extra cockles",
            nutrients: MealNutrients(calories: 700, proteinG: 25),
            source: MealSource.chat,
            clientUUID: UUID().uuidString.lowercased()
        )
        try meals.saveTargets(
            targets: MealNutrients(
                calories: 2000, proteinG: 140, carbsG: 220, fatG: 65,
                fibreG: 30, sugarG: 50, sodiumMg: 2300, satFatG: 20
            ),
            ageYears: 36,
            biologicalSex: "male",
            heightCm: 178,
            weightKg: 76,
            activityLevel: "moderate",
            goal: "maintain",
            rationale: "test fixture"
        )

        let block = await AssistantContextBuilder(store: store).build()

        XCTAssertTrue(block.contains("MEALS TODAY"))
        XCTAssertTrue(
            block.contains(today.clientUUID),
            "update_meal cannot address a meal whose UUID is not in the prompt"
        )
        XCTAssertTrue(block.contains("two poached eggs on toast"))
        XCTAssertTrue(block.contains("Daily targets:"))
        XCTAssertTrue(block.contains("Last 7 days:"))

        // The historical row is counted in the rollup and never printed.
        XCTAssertFalse(
            block.contains(historical.clientUUID),
            "A historical meal's UUID has no caller and is pure prompt weight"
        )
        XCTAssertFalse(
            block.contains("laksa with extra cockles"),
            "Individual historical rows must not reach the prompt"
        )
    }

    /// The whole block stays small, and there is exactly ONE rollup line
    /// however many days the week holds.
    ///
    /// The budget is deliberately generous (a day can hold several meals) and
    /// deliberately present: this is the one block in the builder with no cap
    /// of its own, so a regression here shows up as a slow, permanent cost on
    /// every turn in every section rather than as a failure anywhere.
    func testContextBlockStaysSmallAcrossAFullWeek() async throws {
        for dayOffset in 0..<7 {
            let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!
            for type in MealType.allCases {
                try meals.addMeal(
                    date: day,
                    loggedAt: day,
                    mealType: type,
                    mealDescription: "\(type.rawValue) on day \(dayOffset)",
                    nutrients: MealNutrients(calories: 500, proteinG: 30),
                    source: MealSource.chat,
                    clientUUID: UUID().uuidString.lowercased()
                )
            }
        }

        let block = await AssistantContextBuilder(store: store).build()
        let mealsBlock = try XCTUnwrap(block.components(separatedBy: "MEALS TODAY").last)

        XCTAssertEqual(
            block.components(separatedBy: "Last 7 days:").count - 1, 1,
            "The week is ONE line, not one per day"
        )
        XCTAssertEqual(
            mealsBlock.components(separatedBy: "\n- ID:").count - 1, 4,
            "Only today's four meals carry a row"
        )
        XCTAssertLessThan(
            mealsBlock.count, 1500,
            "28 logged meals must not put 28 rows in every prompt in the app"
        )
    }

    /// A user who has never opened Meals pays nothing for the block.
    func testContextBlockIsAbsentWithNoMealsAndNoTargets() async {
        let block = await AssistantContextBuilder(store: store).build()
        XCTAssertFalse(block.contains("MEALS TODAY"))
    }

    // MARK: - The tools reach both surfaces

    /// Advertised in the shared pool at all.
    func testAllToolsCarriesTheThreeMealTools() {
        let names = Set(ToolDefinitions.allTools.map(\.name))
        for tool in ["log_meal", "update_meal", "delete_meal"] {
            XCTAssertTrue(names.contains(tool), "\(tool) is missing from ToolDefinitions.allTools")
        }
        for tool in ["log_meal", "update_meal", "delete_meal"] {
            XCTAssertNotNil(ToolDefinitions.toolToActionType[tool], "\(tool) maps to no action type")
        }
    }

    /// And actually present in the request the CAPTURE path sends.
    ///
    /// Asserted against the real outgoing body rather than against `allTools`,
    /// because the failure this guards is a filter reintroduced at the call
    /// site — which leaves `allTools` correct and the Shortcut silently unable
    /// to log a meal. Same pattern, and same reason, as `CaptureToolSurfaceTests`.
    func testCapturePathAdvertisesTheMealTools() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-meal-tool-surface"))
        let sut = ChatToDrafts(
            anthropic: AnthropicClient(session: MealToolRequestProbe.makeSession()),
            context: AssistantContextBuilder(store: store),
            executor: executor
        )

        _ = try await sut.run(input: "I had two eggs on toast", timezone: "UTC")

        let names = try XCTUnwrap(
            MealToolRequestProbe.lastToolNames,
            "ChatToDrafts.run() never reached the network layer"
        )
        XCTAssertTrue(names.isSuperset(of: ["log_meal", "update_meal", "delete_meal"]))
    }

    /// And in the request the CHAT path sends. The two orchestrators build
    /// their prompts separately, so each needs its own proof.
    func testChatPathAdvertisesTheMealTools() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-meal-tool-surface"))
        let sut = ChatStream(
            anthropic: AnthropicClient(session: MealToolRequestProbe.makeSession()),
            context: AssistantContextBuilder(store: store)
        )

        for try await _ in sut.run(input: "I had two eggs on toast", timezone: "UTC") {}

        let names = try XCTUnwrap(
            MealToolRequestProbe.lastToolNames,
            "ChatStream.run() never reached the network layer"
        )
        XCTAssertTrue(names.isSuperset(of: ["log_meal", "update_meal", "delete_meal"]))
    }

    /// Both system prompts teach the meal rules, from the one source.
    ///
    /// The rules are stated once in `MealToolSchema` and interpolated into the
    /// estimation prompt AND the two tool descriptions. A second copy written
    /// in prose is the defect #475 and #500 both were.
    func testTheEstimationRulesAreStatedExactlyOnce() {
        let promptRule = AnthropicClient.mealEstimationPrompt(
            description: "two eggs on toast",
            mealTypeHint: .breakfast,
            loggedAt: Date()
        )
        let marker = "\"portion_unit\" must be exactly \"g\" or \"ml\""
        XCTAssertTrue(promptRule.contains(marker), "The composer's prompt lost the shared rules")

        let logTool = try? XCTUnwrap(ToolDefinitions.allTools.first { $0.name == "log_meal" })
        XCTAssertTrue(
            (logTool?.description ?? "").contains(marker),
            "log_meal states its own rules instead of the shared ones"
        )
        let updateTool = try? XCTUnwrap(ToolDefinitions.allTools.first { $0.name == "update_meal" })
        XCTAssertTrue((updateTool?.description ?? "").contains(marker))
    }

    /// The tool payload reaches the SAME guards the composer's answer does.
    func testToolInputDecodesIntoTheSharedEstimateType() {
        let estimate = MealToolSchema.estimatedMeal(from: logInput(id: UUID().uuidString))
        XCTAssertEqual(estimate.items.count, 1)
        XCTAssertEqual(estimate.items.first?.portionUnit, "g")
        XCTAssertEqual(estimate.mealType, "breakfast")

        let checked = MealEstimateGuards.check(estimate, fallbackMealType: .snack)
        XCTAssertEqual(checked.mealType, .breakfast)
        XCTAssertEqual(checked.nutrients.calories, 143, accuracy: 0.01)
        XCTAssertFalse(checked.needsDetail)
    }
}

/// Captures the tool names from the one outgoing Anthropic request the
/// orchestrator under test makes, and answers with a body each path can finish
/// on: a `stop_reason: end_turn` JSON for `send`, an SSE `message_stop` for
/// `stream`.
private final class MealToolRequestProbe: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastToolNames: Set<String>?

    static var lastToolNames: Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return _lastToolNames
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastToolNames = nil
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MealToolRequestProbe.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession commonly hands POST bodies to the protocol via
        // `httpBodyStream` rather than `httpBody`. Read whichever is present.
        let body: Data? = request.httpBody ?? Self.drain(request.httpBodyStream)
        var streaming = false
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let tools = json["tools"] as? [[String: Any]] {
                Self.lock.lock()
                Self._lastToolNames = Set(tools.compactMap { $0["name"] as? String })
                Self.lock.unlock()
            }
            streaming = (json["stream"] as? Bool) ?? false
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"]
        )!
        let payload: Data = streaming
            ? "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".data(using: .utf8)!
            : #"{"content": [], "stop_reason": "end_turn"}"#.data(using: .utf8)!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
