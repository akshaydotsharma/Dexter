import XCTest
@testable import PersonalDashboard

/// Every check that runs in Swift after a meal estimate comes back (#543).
///
/// These are the highest-risk part of the feature and the cheapest part to
/// cover, because all of it is pure arithmetic over a decoded value. The reason
/// the rules live in code rather than in the prompt is exactly the reason they
/// are tested here: a prompt cannot be asserted against, and a rule graded by
/// the model whose output is in question is not a rule.
final class MealEstimateGuardTests: XCTestCase {

    // MARK: - Fixtures

    /// A dish whose four Atwater terms agree with its calories, so it passes
    /// the consistency check on its own and can be varied one field at a time.
    private func item(
        name: String = "Poached egg",
        quantity: Double? = 100,
        unit: String? = "g",
        calories: Double = 200,
        protein: Double = 10,
        carbs: Double = 15,
        fat: Double = 10,
        fibre: Double = 2,
        sugar: Double = 3,
        sodium: Double = 200,
        satFat: Double = 3
    ) -> EstimatedMealItem {
        EstimatedMealItem(
            name: name,
            portionQuantity: quantity,
            portionUnit: unit,
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fibreG: fibre,
            sugarG: sugar,
            sodiumMg: sodium,
            satFatG: satFat
        )
    }

    private func meal(
        _ items: [EstimatedMealItem],
        alcohol: Bool = false,
        type: String? = "lunch",
        noFood: Bool = false
    ) -> EstimatedMeal {
        EstimatedMeal(
            mealType: type,
            items: items,
            containsAlcohol: alcohol,
            confidence: "medium",
            assumptions: "Assumed a medium portion.",
            noFoodIdentified: noFood
        )
    }

    private func checked(
        _ items: [EstimatedMealItem],
        alcohol: Bool = false,
        type: String? = "lunch",
        noFood: Bool = false
    ) -> CheckedMealEstimate {
        MealEstimateGuards.check(
            meal(items, alcohol: alcohol, type: type, noFood: noFood),
            fallbackMealType: .snack
        )
    }

    // MARK: - The passing case

    /// A well-formed estimate must produce NO failures. Without this the whole
    /// suite could pass with a guard that fires on everything.
    func testAConsistentEstimatePassesEveryGuard() {
        let result = checked([item()])

        XCTAssertTrue(result.failures.isEmpty, "unexpected failures: \(result.failures)")
        XCTAssertFalse(result.isSuspect)
        XCTAssertNil(result.suspectReason)
        XCTAssertFalse(result.needsDetail)
        XCTAssertEqual(result.mealType, .lunch)
        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.0001)
    }

    /// The meal's totals are the sum of its items, never a second number the
    /// model stated alongside them.
    func testTotalsAreTheSumOfTheItems() {
        let result = checked([
            item(name: "Rice", calories: 300, protein: 6, carbs: 65, fat: 1, fibre: 1, sugar: 0, sodium: 5, satFat: 0),
            item(name: "Chicken", calories: 200, protein: 30, carbs: 0, fat: 9, fibre: 0, sugar: 0, sodium: 400, satFat: 2)
        ])

        XCTAssertEqual(result.nutrients.calories, 500, accuracy: 0.0001)
        XCTAssertEqual(result.nutrients.proteinG, 36, accuracy: 0.0001)
        XCTAssertEqual(result.nutrients.sodiumMg, 405, accuracy: 0.0001)
        XCTAssertEqual(result.items.count, 2)
    }

    // MARK: - Hard bounds

    func testANegativeValueIsClampedToZeroAndFlagged() {
        let result = checked([item(protein: -12)])

        XCTAssertTrue(result.isSuspect)
        XCTAssertTrue(result.failures.contains(.negativeValue(.protein)))
        // Clamped rather than dropped: `MealService` refuses a negative, so an
        // unclamped value would make the meal unstorable, which is the one
        // outcome no guard is allowed to produce.
        XCTAssertEqual(result.nutrients.proteinG, 0, accuracy: 0.0001)
        XCTAssertFalse(result.nutrients.hasNegativeValue)
    }

    func testAMealOverTheCalorieCeilingIsFlagged() {
        // 3,200 kcal, with macros that agree with it so only the ceiling fires.
        let result = checked([
            item(calories: 3200, protein: 100, carbs: 400, fat: 133.3, sugar: 50, satFat: 40)
        ])

        XCTAssertTrue(result.isSuspect)
        XCTAssertTrue(
            result.failures.contains { if case .caloriesOverCeiling = $0 { return true }; return false },
            "expected a calorie-ceiling failure, got \(result.failures)"
        )
    }

    func testAMealUnderTheCalorieCeilingIsNotFlagged() {
        let result = checked([
            item(calories: 2900, protein: 100, carbs: 400, fat: 100, sugar: 50, satFat: 40)
        ])

        XCTAssertFalse(
            result.failures.contains { if case .caloriesOverCeiling = $0 { return true }; return false }
        )
    }

    func testProteinOverTheCeilingIsFlagged() {
        // 260 g of protein. Calories are set to agree with the macros so the
        // consistency check stays out of this assertion.
        let result = checked([
            item(calories: 1040, protein: 260, carbs: 0, fat: 0, sugar: 0, satFat: 0)
        ])

        XCTAssertTrue(
            result.failures.contains { if case .proteinOverCeiling = $0 { return true }; return false },
            "expected a protein-ceiling failure, got \(result.failures)"
        )
    }

    func testSodiumOverTheCeilingIsFlagged() {
        let result = checked([item(sodium: 8400)])

        XCTAssertTrue(
            result.failures.contains { if case .sodiumOverCeiling = $0 { return true }; return false },
            "expected a sodium-ceiling failure, got \(result.failures)"
        )
    }

    // MARK: - Internal consistency

    /// The highest-value check in the set: it proves an estimate wrong without
    /// knowing anything about the food.
    func testMacrosThatMissTheStatedCaloriesAreFlagged() {
        // 4(10) + 4(15) + 9(10) = 190 kcal implied against 700 stated: a 73% miss.
        let result = checked([item(calories: 700)])

        guard let failure = result.failures.first(where: {
            if case .macroMismatch = $0 { return true }; return false
        }) else {
            return XCTFail("expected a macro mismatch, got \(result.failures)")
        }
        guard case .macroMismatch(let stated, let implied) = failure else { return }
        XCTAssertEqual(stated, 700, accuracy: 0.0001)
        XCTAssertEqual(implied, 190, accuracy: 0.0001)
        XCTAssertTrue(result.isSuspect)
        XCTAssertEqual(result.suspectReason, "The macros account for 190 kcal but the meal states 700 kcal.")
    }

    /// Exactly at the tolerance the check must NOT fire. The boundary is where a
    /// rule like this goes wrong, and a 20% rule that fires at 20% would flag
    /// estimates that are merely approximate — which is every estimate here.
    func testAMissExactlyAtTheToleranceDoesNotFire() {
        // Implied 4(25) + 4(25) + 9(0) = 200. Stated 250 is a drift of exactly
        // 0.2, which is not greater than the tolerance.
        let result = checked([item(calories: 250, protein: 25, carbs: 25, fat: 0, sugar: 10, satFat: 0)])

        XCTAssertFalse(
            result.failures.contains { if case .macroMismatch = $0 { return true }; return false },
            "a drift of exactly the tolerance must pass, got \(result.failures)"
        )
    }

    func testAMissJustOverTheToleranceFires() {
        // Implied 200 against a stated 255: a drift of about 0.216.
        let result = checked([item(calories: 255, protein: 25, carbs: 25, fat: 0, sugar: 10, satFat: 0)])

        XCTAssertTrue(
            result.failures.contains { if case .macroMismatch = $0 { return true }; return false }
        )
    }

    /// A meal with no calories at all has nothing to compare against, and
    /// dividing by it would be a crash rather than a verdict.
    func testAZeroCalorieMealSkipsTheConsistencyCheck() {
        let result = checked([
            item(calories: 0, protein: 0, carbs: 0, fat: 0, fibre: 0, sugar: 0, sodium: 0, satFat: 0)
        ])

        XCTAssertFalse(
            result.failures.contains { if case .macroMismatch = $0 { return true }; return false }
        )
    }

    // MARK: - The alcohol exemption

    /// Without this exemption the consistency check fires on every beer, and a
    /// check that cries wolf is one nobody reads.
    func testAnAlcoholFlaggedMealIsExemptFromTheConsistencyCheck() {
        // A 330 ml lager: 140 kcal, of which roughly 100 is ethanol. The macros
        // imply 4(1.6) + 4(11) + 9(0) = 50.4 against 140 stated — a 64% miss
        // that is entirely correct, because alcohol sits in none of the three.
        let beer = item(
            name: "Lager",
            quantity: 330, unit: "ml",
            calories: 140, protein: 1.6, carbs: 11, fat: 0,
            fibre: 0, sugar: 0, sodium: 10, satFat: 0
        )

        let exempt = checked([beer], alcohol: true)
        XCTAssertFalse(
            exempt.failures.contains { if case .macroMismatch = $0 { return true }; return false },
            "the alcohol exemption did not apply: \(exempt.failures)"
        )
        XCTAssertFalse(exempt.isSuspect)

        // The same numbers WITHOUT the flag must still fail, or the test above
        // would pass for the wrong reason.
        let notExempt = checked([beer], alcohol: false)
        XCTAssertTrue(
            notExempt.failures.contains { if case .macroMismatch = $0 { return true }; return false },
            "the same numbers must fail when nothing says they contain alcohol"
        )
    }

    /// The exemption covers the consistency check only. A beer that is somehow
    /// 9,000 mg of sodium is still wrong.
    func testTheAlcoholExemptionDoesNotCoverTheHardBounds() {
        let result = checked([item(calories: 140, sodium: 9000)], alcohol: true)

        XCTAssertTrue(
            result.failures.contains { if case .sodiumOverCeiling = $0 { return true }; return false },
            "alcohol must not exempt a hard bound, got \(result.failures)"
        )
    }

    // MARK: - Subset clamps

    func testSaturatedFatAboveFatIsClampedAndFlagged() {
        // Consistency is held by moving the calories with the fat, so only the
        // subset rule fires.
        let result = checked([
            item(calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 3, satFat: 22)
        ])

        XCTAssertEqual(result.nutrients.satFatG, 10, accuracy: 0.0001)
        XCTAssertEqual(result.items.first?.satFatG, 10)
        XCTAssertTrue(
            result.failures.contains(.saturatedFatClamped(from: 22, to: 10)),
            "expected a saturated-fat clamp, got \(result.failures)"
        )
        // The clamp REPAIRED the meal, so it still counts.
        XCTAssertFalse(result.isSuspect)
        XCTAssertNil(result.suspectReason)
        XCTAssertEqual(
            result.repairNote,
            "Saturated fat (22 g) exceeded total fat and was clamped to 10 g."
        )
    }

    func testSugarAboveCarbsIsClampedAndFlagged() {
        let result = checked([
            item(calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 40, satFat: 3)
        ])

        XCTAssertEqual(result.nutrients.sugarG, 15, accuracy: 0.0001)
        XCTAssertTrue(
            result.failures.contains(.sugarClamped(from: 40, to: 15)),
            "expected a sugar clamp, got \(result.failures)"
        )
        XCTAssertFalse(result.isSuspect)
        XCTAssertNotNil(result.repairNote)
    }

    // MARK: - Repair versus invalidation

    /// The line that decides whether a meal counts.
    ///
    /// A clamp leaves the numbers coherent, so it must not flag the meal. Every
    /// other failure leaves them unusable, so it must.
    func testWhichFailuresInvalidateAnEstimate() {
        XCTAssertFalse(MealGuardFailure.saturatedFatClamped(from: 22, to: 10).invalidatesEstimate)
        XCTAssertFalse(MealGuardFailure.sugarClamped(from: 40, to: 15).invalidatesEstimate)

        XCTAssertTrue(MealGuardFailure.caloriesOverCeiling(3200).invalidatesEstimate)
        XCTAssertTrue(MealGuardFailure.proteinOverCeiling(260).invalidatesEstimate)
        XCTAssertTrue(MealGuardFailure.sodiumOverCeiling(8400).invalidatesEstimate)
        XCTAssertTrue(MealGuardFailure.macroMismatch(stated: 700, impliedByMacros: 190).invalidatesEstimate)
        XCTAssertTrue(MealGuardFailure.missingPortion(itemName: "Rice").invalidatesEstimate)
        // Zeroing a negative does not recover the right value, it erases the
        // wrong one, so it invalidates rather than repairs.
        XCTAssertTrue(MealGuardFailure.negativeValue(.protein).invalidatesEstimate)
    }

    /// A repair alongside a real failure must not soften the failure.
    func testARepairAlongsideAnInvalidationStillFlagsTheMeal() {
        // Sugar over carbs (a repair) AND macros that miss the calories (an
        // invalidation) on the same estimate.
        let result = checked([
            item(calories: 700, protein: 10, carbs: 15, fat: 10, sugar: 40, satFat: 3)
        ])

        XCTAssertTrue(result.isSuspect)
        XCTAssertEqual(result.repairs.count, 1)
        XCTAssertEqual(result.invalidatingFailures.count, 1)
        // The two sentences go to two different fields, so neither hides the
        // other.
        XCTAssertEqual(
            result.suspectReason,
            "The macros account for 190 kcal but the meal states 700 kcal."
        )
        XCTAssertTrue(result.repairNote?.hasPrefix("Sugar (40 g)") == true)
    }

    /// The repair is written to the front of the assumptions note, because a
    /// row shows that note on one line and the sentence about a changed number
    /// is the half that must survive truncation.
    func testTheRepairLeadsTheStoredAssumptionsNote() {
        let result = checked([
            item(calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 40, satFat: 3)
        ])

        let stored = result.storedAssumptionsNote
        XCTAssertTrue(stored?.hasPrefix("Sugar (40 g) exceeded total carbs") == true, "got \(stored ?? "nil")")
        XCTAssertTrue(stored?.hasSuffix("Assumed a medium portion.") == true, "got \(stored ?? "nil")")
    }

    /// With nothing to repair the note is the model's own, unchanged.
    func testAnUnrepairedEstimateStoresTheModelsNoteVerbatim() {
        let result = checked([item()])

        XCTAssertNil(result.repairNote)
        XCTAssertEqual(result.storedAssumptionsNote, "Assumed a medium portion.")
    }

    /// Saturated fat EQUAL to fat is a real food (coconut oil is close), so the
    /// rule has to be "exceeds", not "reaches".
    func testSaturatedFatEqualToFatIsNotClamped() {
        let result = checked([
            item(calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 3, satFat: 10)
        ])

        XCTAssertFalse(
            result.failures.contains { if case .saturatedFatClamped = $0 { return true }; return false }
        )
    }

    /// The clamp is applied PER ITEM, so the meal's totals satisfy the subset
    /// rule by construction rather than by a second pass over the sum.
    func testTheClampIsAppliedPerItemSoTheTotalsStayConsistent() {
        let result = checked([
            item(name: "Butter", calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 3, satFat: 18),
            item(name: "Toast", calories: 190, protein: 10, carbs: 15, fat: 10, sugar: 3, satFat: 2)
        ])

        XCTAssertLessThanOrEqual(result.nutrients.satFatG, result.nutrients.fatG)
        XCTAssertEqual(result.items.map(\.satFatG), [10, 2])
    }

    // MARK: - Missing portions

    func testAnItemWithNoPortionQuantityIsFlagged() {
        let result = checked([item(quantity: nil)])

        XCTAssertTrue(result.failures.contains(.missingPortion(itemName: "Poached egg")))
        XCTAssertTrue(result.isSuspect)
        // The numbers are kept. They are what the user has to argue with.
        XCTAssertEqual(result.nutrients.calories, 200, accuracy: 0.0001)
    }

    func testAnItemWithNoPortionUnitIsFlagged() {
        let result = checked([item(unit: nil)])

        XCTAssertTrue(result.failures.contains(.missingPortion(itemName: "Poached egg")))
    }

    func testAZeroPortionIsFlagged() {
        let result = checked([item(quantity: 0)])

        XCTAssertTrue(result.failures.contains(.missingPortion(itemName: "Poached egg")))
    }

    /// A household measure is not a portion assumption for this feature's
    /// purposes: nothing can scale "1 bowl" by a ratio, which is the only thing
    /// the stored portion is for.
    func testAHouseholdMeasureIsNotAnAcceptablePortion() {
        for unit in ["bowl", "serving", "slice", "cup", ""] {
            let result = checked([item(unit: unit)])
            XCTAssertTrue(
                result.failures.contains(.missingPortion(itemName: "Poached egg")),
                "\"\(unit)\" should not count as a scalable portion"
            )
        }
    }

    func testMillilitresAreAnAcceptablePortion() {
        let result = checked([item(quantity: 250, unit: "ml")])

        XCTAssertFalse(
            result.failures.contains { if case .missingPortion = $0 { return true }; return false }
        )
        XCTAssertEqual(result.items.first?.portionUnit, "ml")
    }

    // MARK: - Nothing to estimate

    func testNoFoodIdentifiedSavesWithZeroNutrientsAndNeedsDetail() {
        let result = checked([], noFood: true)

        XCTAssertTrue(result.needsDetail)
        XCTAssertEqual(result.nutrients, .zero)
        XCTAssertEqual(result.confidence, 0)
        // Needs-detail and suspect are different states: one wants an answer
        // FROM the user, the other is a warning ABOUT the estimate.
        XCTAssertFalse(result.isSuspect)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testAnEmptyItemsArrayIsTreatedAsNothingToEstimate() {
        let result = checked([], noFood: false)

        XCTAssertTrue(result.needsDetail)
        XCTAssertEqual(result.nutrients, .zero)
    }

    // MARK: - Meal type

    func testAnUnmappableMealTypeFallsBackRatherThanTrapping() {
        let result = checked([item()], type: "brunch")

        XCTAssertEqual(result.mealType, .snack)
    }

    func testTheReturnedMealTypeIsUsedWhenItMaps() {
        XCTAssertEqual(checked([item()], type: "dinner").mealType, .dinner)
        XCTAssertEqual(checked([item()], type: "BREAKFAST").mealType, .breakfast)
    }
}
