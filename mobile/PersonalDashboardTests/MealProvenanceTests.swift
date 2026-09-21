import XCTest
import SwiftData
@testable import PersonalDashboard

/// The step between what the model claimed and what the device believes (#653).
///
/// ### What is actually being defended here
///
/// The estimate now carries per-item provenance, and a confidence band is
/// derived from it. That makes provenance load-bearing: a `source_id` nobody
/// checks would produce a HIGH band on a number the model made up, which is
/// strictly worse than the honest LOW it replaced. A guess reported as a guess
/// costs accuracy. A guess reported as a lookup costs trust.
///
/// So every test below is some version of the same question: can the model talk
/// the device into believing a source it was never given?
final class MealProvenanceTests: XCTestCase {

    // MARK: - Fixtures

    private func candidate(
        id: Int = 2706437,
        name: String = "Chicken curry",
        calories: Double = 107,
        portions: [FoodDataCentralPortion] = [
            FoodDataCentralPortion(description: "Quantity not specified", gramWeight: 240),
            FoodDataCentralPortion(description: "1 cup", gramWeight: 240)
        ]
    ) -> FoodDataCentralFood {
        FoodDataCentralFood(
            fdcID: id,
            description: name,
            dataType: .survey,
            brandOwner: nil,
            nutrientsPer100: MealNutrients(
                calories: calories,
                proteinG: 6.48,
                carbsG: 6.54,
                fatG: 6.48,
                fibreG: 1.4,
                sugarG: 2.56,
                sodiumMg: 376,
                satFatG: 1.56
            ),
            missingNutrients: [],
            portions: portions
        )
    }

    private func ledger(_ foods: [FoodDataCentralFood]) -> FoodLookupLedger {
        let ledger = FoodLookupLedger()
        ledger.record([
            FoodLookupResult(
                query: "chicken curry",
                candidates: foods.map(FoodLookupCandidate.init(fdc:)),
                note: nil
            )
        ])
        return ledger
    }

    private func meal(items: [EstimatedMealItem]) -> EstimatedMeal {
        EstimatedMeal(mealType: "dinner", title: "Dinner", items: items, confidence: "high")
    }

    // MARK: - An unoffered id is not a source

    /// The headline defence. An id the device never handed over is refused, the
    /// item falls back to `estimated`, and no trace of the claim survives on it.
    ///
    /// The last part matters as much as the first: a `sourceID` left in place
    /// on a rejected item would read, to every later reader and to the detail
    /// sheet, exactly like one that had been verified.
    func testAnIDThatWasNeverOfferedIsRefused() {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Chicken curry",
                portionQuantity: 240, portionUnit: "g",
                calories: 9999,
                sourceID: "fdc:1234567",
                massSource: "standard_portion"
            )
        ])

        let result = FoodLookupResolution.resolve(estimate, ledger: ledger([candidate()]))
        let verdict = try? XCTUnwrap(result.resolved.first)

        XCTAssertEqual(verdict?.densitySource, .estimated)
        XCTAssertNil(verdict?.sourceID, "a rejected claim must leave no trace")
        XCTAssertEqual(
            result.estimate.items.first?.calories, 9999,
            "the model's own numbers stand; nothing was substituted"
        )
    }

    /// An empty ledger is the ordinary state for a path that declares no lookup
    /// tool, and everything in it is honestly `estimated`.
    func testAnEmptyLedgerResolvesEverythingAsEstimated() {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Chicken curry",
                portionQuantity: 240, portionUnit: "g",
                calories: 260,
                sourceID: "fdc:2706437",
                massSource: "standard_portion"
            )
        ])

        let result = FoodLookupResolution.resolve(estimate, ledger: FoodLookupLedger())
        XCTAssertEqual(result.resolved.first?.densitySource, .estimated)
        XCTAssertNil(result.resolved.first?.sourceID)
    }

    // MARK: - A verified id means the device does the arithmetic

    /// The whole point of verifying: once the row checks out, the model's
    /// transcription is thrown away and the numbers are computed from the
    /// record. 240 g of a 107 kcal/100 g curry is 257 kcal whatever the model
    /// wrote.
    func testAVerifiedIDMakesTheDeviceRecomputeTheNumbers() throws {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Mum's chicken curry",
                portionQuantity: 240, portionUnit: "g",
                calories: 400,          // wrong on purpose
                proteinG: 2,            // wrong on purpose
                sodiumMg: 10,           // wrong on purpose
                sourceID: "fdc:2706437",
                massSource: "standard_portion"
            )
        ])

        let result = FoodLookupResolution.resolve(estimate, ledger: ledger([candidate()]))
        let item = try XCTUnwrap(result.estimate.items.first)

        XCTAssertEqual(item.calories ?? 0, 256.8, accuracy: 0.1)
        XCTAssertEqual(item.proteinG ?? 0, 15.55, accuracy: 0.01)
        XCTAssertEqual(item.sodiumMg ?? 0, 902.4, accuracy: 0.1)
        XCTAssertEqual(result.resolved.first?.densitySource, .lookedUp)
        XCTAssertEqual(result.resolved.first?.sourceID, "fdc:2706437")
    }

    /// The user's own words for the dish survive substitution.
    ///
    /// The database calls it "Chicken curry". They wrote "Mum's chicken curry",
    /// and that is their record of the meal, not the dataset's. The id carries
    /// the trace instead.
    func testSubstitutionKeepsTheUsersOwnNameForTheDish() throws {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Mum's chicken curry",
                portionQuantity: 240, portionUnit: "g",
                sourceID: "fdc:2706437",
                massSource: "stated"
            )
        ])

        let result = FoodLookupResolution.resolve(estimate, ledger: ledger([candidate()]))
        XCTAssertEqual(result.estimate.items.first?.name, "Mum's chicken curry")
    }

    /// A portion stated in something that cannot be scaled leaves the figures
    /// alone. There is no ratio to apply, so the density is still sourced but
    /// nothing is recomputed.
    func testAnUnscalablePortionBlocksSubstitutionWithoutLosingProvenance() throws {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Chicken curry",
                portionQuantity: 1, portionUnit: "bowl",
                calories: 400,
                sourceID: "fdc:2706437",
                massSource: "standard_portion"
            )
        ])

        let result = FoodLookupResolution.resolve(estimate, ledger: ledger([candidate()]))
        XCTAssertEqual(result.estimate.items.first?.calories, 400, "nothing to scale by")
        XCTAssertEqual(result.resolved.first?.densitySource, .lookedUp)
    }

    // MARK: - A standard portion is the one mass claim that can be checked

    /// A quoted portion weight that appears in the candidate's table is
    /// accepted.
    func testAPortionFromTheTableIsAccepted() {
        let verified = FoodLookupResolution.verify(
            .standardPortion,
            quantity: 240,
            against: FoodLookupCandidate(fdc: candidate())
        )
        XCTAssertEqual(verified, .standardPortion)
    }

    /// A weight that appears nowhere in the table is the model's own number
    /// wearing a citation, and is demoted.
    ///
    /// This is the claim most worth checking, because it is the one that turns
    /// a restaurant guess into a sourced mass — which is exactly the upgrade
    /// this feature exists to make, and therefore exactly the upgrade worth
    /// faking.
    func testAPortionNotInTheTableIsDemotedToEstimated() {
        let verified = FoodLookupResolution.verify(
            .standardPortion,
            quantity: 500,
            against: FoodLookupCandidate(fdc: candidate())
        )
        XCTAssertEqual(verified, .estimated)
    }

    /// Rounding is tolerated; adaptation is not. 2% is the width of a rounded
    /// number, not room to adjust one.
    func testRoundingIsToleratedOnAQuotedPortion() {
        let candidate = FoodLookupCandidate(fdc: candidate())
        XCTAssertEqual(FoodLookupResolution.verify(.standardPortion, quantity: 238, against: candidate), .standardPortion)
        XCTAssertEqual(FoodLookupResolution.verify(.standardPortion, quantity: 200, against: candidate), .estimated)
    }

    /// The other three mass claims are facts about things the device cannot see
    /// from here — the description, a packet, the store — so they are taken at
    /// face value rather than guessed at.
    func testTheUncheckableMassClaimsPassThrough() {
        let candidate = FoodLookupCandidate(fdc: candidate())
        for claim in [MealMassSource.stated, .publishedServing, .history, .estimated] {
            XCTAssertEqual(
                FoodLookupResolution.verify(claim, quantity: 999, against: candidate),
                claim
            )
        }
    }

    /// A grounded turn with no candidate id is `published`, not `estimated`.
    /// A brand's panel arrives as prose in a search result and has no id to
    /// quote, so it gets its own case rather than being folded into a
    /// neighbour.
    func testAGroundedItemWithNoIDIsPublished() {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Big Mac", portionQuantity: 219, portionUnit: "g", massSource: "published_serving")
        ])

        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            wasGrounded: true
        )
        XCTAssertEqual(result.resolved.first?.densitySource, .published)
        XCTAssertEqual(result.resolved.first?.massSource, .publishedServing)
    }

    /// A mass source the model invents outside the enum degrades to a guess
    /// rather than failing the decode and taking the meal with it.
    func testAnUnknownMassSourceReadsAsEstimated() {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Toast", portionQuantity: 60, portionUnit: "g", massSource: "vibes")
        ])
        let result = FoodLookupResolution.resolve(estimate, ledger: FoodLookupLedger())
        XCTAssertEqual(result.resolved.first?.massSource, .estimated)
    }

    // MARK: - The band

    /// Both halves sourced on every item.
    func testBothHalvesSourcedIsHigh() {
        let items = [
            MealItemEntry(name: "a", densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "b", densitySource: .saved, massSource: .stated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.3), 0.9)
    }

    /// One half sourced is medium, and it does not matter which half. The two
    /// errors are not equal in size and the band treats them as equal on
    /// purpose — see `derivedConfidence`.
    func testOneHalfSourcedIsMediumEitherWay() {
        let massOnly = [MealItemEntry(name: "a", densitySource: .estimated, massSource: .stated)]
        let densityOnly = [MealItemEntry(name: "a", densitySource: .lookedUp, massSource: .estimated)]

        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: massOnly, reported: 0.9), 0.6)
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: densityOnly, reported: 0.9), 0.6)
    }

    /// Guessed twice over is low, whatever the model said about itself.
    func testGuessedOnBothHalvesIsLow() {
        let items = [MealItemEntry(name: "a", densitySource: .estimated, massSource: .estimated)]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// The meal takes the WORST item, not the average.
    ///
    /// A meal is a sum. One dish guessed end to end puts the total in doubt
    /// however well the other three are sourced, and an average would let the
    /// good rows hide the bad one — which is the failure mode of every
    /// aggregate quality score.
    func testTheBandTakesTheWorstItem() {
        let items = [
            MealItemEntry(name: "a", densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "b", densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "c", densitySource: .estimated, massSource: .estimated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// A condiment cannot drag a well-sourced meal down.
    ///
    /// The live case, 2026-09-22: a plate of chicken rice resolved to HPB's own
    /// lab-analysed row at its weighed 346 g plate, and the meal graded LOW
    /// because a 5 g soy sauce drizzle beside it was a guess. That is the rule
    /// punishing the model for itemising properly.
    func testANegligibleItemDoesNotDecideTheBand() {
        let items = [
            MealItemEntry(name: "Chicken rice", calories: 615,
                          densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "Soy sauce drizzle", calories: 3,
                          densitySource: .estimated, massSource: .estimated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.3), 0.9)
    }

    /// A SUBSTANTIAL guessed item still decides it. The rule excuses a
    /// condiment, not a dish.
    func testASubstantialGuessedItemStillDecidesTheBand() {
        let items = [
            MealItemEntry(name: "Chicken rice", calories: 615,
                          densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "Fried chicken wing", calories: 300,
                          densitySource: .estimated, massSource: .estimated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// Exactly at the bar counts. A twentieth of the meal is material.
    func testAnItemExactlyAtTheThresholdIsMaterial() {
        let items = [
            MealItemEntry(name: "Main", calories: 950,
                          densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "Side", calories: 50,
                          densitySource: .estimated, massSource: .estimated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// A meal of five equally small things has no negligible item; it has five
    /// real ones, and they are all graded.
    func testWhenNothingClearsTheBarEverythingIsGraded() {
        let items = (1...5).map { i in
            MealItemEntry(name: "Item \(i)", calories: 20,
                          densitySource: i == 5 ? .estimated : .lookedUp,
                          massSource: i == 5 ? .estimated : .stated)
        }
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// A meal with no calories to apportion grades every item, rather than
    /// dividing by zero and excusing the lot.
    func testAZeroCalorieMealGradesEveryItem() {
        let items = [
            MealItemEntry(name: "Water", calories: 0, densitySource: .estimated, massSource: .estimated)
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.9), 0.3)
    }

    /// No provenance at all falls back to the model's band.
    ///
    /// This is what keeps every unconverted path, and every meal logged before
    /// #653, behaving as it did. Reading nil as "estimated" would re-grade the
    /// whole history as guesswork overnight.
    func testNoProvenanceFallsBackToTheReportedBand() {
        let items = [MealItemEntry(name: "a")]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.6), 0.6)
    }

    /// PARTIAL provenance also falls back, rather than grading the meal on the
    /// items that happen to carry it. A band computed from half the evidence is
    /// not a weaker claim, it is a different one.
    func testPartialProvenanceFallsBackRatherThanGradingHalfAMeal() {
        let items = [
            MealItemEntry(name: "a", densitySource: .lookedUp, massSource: .standardPortion),
            MealItemEntry(name: "b")
        ]
        XCTAssertEqual(MealEstimateGuards.derivedConfidence(items: items, reported: 0.6), 0.6)
    }

    // MARK: - Through the guards

    /// End to end: the resolution's verdict lands on the stored items and the
    /// band is the derived one, not the model's.
    func testProvenanceReachesTheStoredItemsAndTheBand() throws {
        let estimate = meal(items: [
            EstimatedMealItem(
                name: "Chicken curry",
                portionQuantity: 240, portionUnit: "g",
                calories: 400,
                sourceID: "fdc:2706437",
                massSource: "standard_portion"
            )
        ])

        let resolution = FoodLookupResolution.resolve(estimate, ledger: ledger([candidate()]))
        let checked = MealEstimateGuards.check(
            resolution.estimate,
            fallbackMealType: .dinner,
            provenance: resolution.resolved
        )

        let item = try XCTUnwrap(checked.items.first)
        XCTAssertEqual(item.densitySource, .lookedUp)
        XCTAssertEqual(item.massSource, .standardPortion)
        XCTAssertEqual(item.sourceID, "fdc:2706437")
        XCTAssertEqual(item.provenanceScore, 2)
        XCTAssertEqual(
            checked.confidence, 0.9, accuracy: 0.0001,
            "derived from provenance, not read from the model band"
        )
        XCTAssertEqual(checked.nutrients.calories, 256.8, accuracy: 0.1)
    }

    /// A meal the guards flag for an unusable portion cannot also claim a
    /// sourced mass. The two would contradict each other on the same row.
    func testARejectedPortionCannotClaimASourcedMass() throws {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Soup", portionQuantity: 0, portionUnit: "g", calories: 100, massSource: "stated")
        ])

        let resolution = FoodLookupResolution.resolve(estimate, ledger: FoodLookupLedger())
        let checked = MealEstimateGuards.check(
            resolution.estimate,
            fallbackMealType: .dinner,
            provenance: resolution.resolved
        )

        XCTAssertTrue(checked.isSuspect)
        XCTAssertEqual(checked.items.first?.massSource, .estimated)
        XCTAssertEqual(checked.confidence, 0.3, accuracy: 0.0001)
    }

    /// An item written before #653 decodes with no provenance rather than
    /// failing, because the items are a JSON blob and the fields are additive.
    func testAnOlderItemDecodesWithoutProvenance() throws {
        let json = """
        {"id":"AB1E5B1E-0000-0000-0000-000000000001","name":"Toast",
         "portionQuantity":60,"portionUnit":"g","calories":160,"proteinG":6,
         "carbsG":30,"fatG":2,"fibreG":3,"sugarG":2,"sodiumMg":300,"satFatG":0.5}
        """
        let item = try JSONDecoder().decode(MealItemEntry.self, from: Data(json.utf8))

        XCTAssertEqual(item.name, "Toast")
        XCTAssertNil(item.densitySource)
        XCTAssertNil(item.massSource)
        XCTAssertNil(item.provenanceScore, "absent is not the same as guessed")
    }

    // MARK: - Recovering a portion the user stated

    /// The live miss that put this rule in code: the description says 250 g,
    /// the item is 250 g, and the model reported the mass as a guess.
    func testAStatedWeightIsRecoveredWhenTheModelReportsAGuess() {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Chicken curry", portionQuantity: 250, portionUnit: "g", massSource: "estimated")
        ])

        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            description: "for dinner 250 g cooked chicken Indian curry"
        )
        XCTAssertEqual(result.resolved.first?.massSource, .stated)
    }

    /// It only ever promotes. A model that reported something stronger keeps it.
    func testRecoveryNeverDowngradesAStrongerClaim() {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Dal", portionQuantity: 240, portionUnit: "g", massSource: "standard_portion")
        ])

        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            description: "240 g of dal"
        )
        XCTAssertEqual(result.resolved.first?.massSource, .standardPortion)
    }

    /// A figure that would fit two items is used for neither, because nothing
    /// here can tell which 200 belongs to which row.
    func testAnAmbiguousFigureIsNotAttributed() {
        let estimate = meal(items: [
            EstimatedMealItem(name: "Rice", portionQuantity: 200, portionUnit: "g", massSource: "estimated"),
            EstimatedMealItem(name: "Chicken", portionQuantity: 200, portionUnit: "g", massSource: "estimated")
        ])

        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            description: "200 g of rice and 200 g of chicken"
        )
        XCTAssertTrue(result.resolved.allSatisfy { $0.massSource == .estimated })
    }

    /// Units are normalised, and a figure in one unit never matches an item in
    /// the other.
    func testUnitsAreNormalisedAndNotCrossMatched() {
        let grams = FoodLookupResolution.quantities(in: "1.5 kg of rice, 330 ml coke, 2 litres water, 150 grams dal")
        XCTAssertEqual(grams.map(\.value), [1500, 330, 2000, 150])
        XCTAssertEqual(grams.map(\.unit), ["g", "ml", "ml", "g"])

        let estimate = meal(items: [
            EstimatedMealItem(name: "Coke", portionQuantity: 330, portionUnit: "g", massSource: "estimated")
        ])
        let result = FoodLookupResolution.resolve(
            estimate, ledger: FoodLookupLedger(), description: "330 ml coke"
        )
        XCTAssertEqual(
            result.resolved.first?.massSource, .estimated,
            "330 ml must not satisfy an item measured in grams"
        )
    }

    /// The word boundary, which is why the pattern is not just "a number then a
    /// letter". Without it "2 gulab jamun" reports a 2 g weight nobody wrote,
    /// and "150 grams" reports 150 twice.
    func testAUnitLetterInsideAWordIsNotAQuantity() {
        XCTAssertTrue(FoodLookupResolution.quantities(in: "2 gulab jamun and 3 laddu").isEmpty)
        XCTAssertEqual(FoodLookupResolution.quantities(in: "150 grams of dal").count, 1)
    }

    /// Household measures are deliberately NOT read. "A cup" is the portion
    /// this feature resolves from a portion table; guessing at it here would put
    /// the device back in the business of inventing masses.
    func testHouseholdMeasuresAreNotTreatedAsStated() {
        XCTAssertTrue(FoodLookupResolution.quantities(in: "a cup of dal and two slices of toast").isEmpty)
    }

    // MARK: - The tool's own input handling

    func testQueriesAreTrimmedDedupedAndCapped() {
        let input: [String: AnthropicJSONValue] = [
            "queries": .array(
                [.string("  chicken curry "), .string("CHICKEN CURRY"), .string("")]
                + (1...12).map { .string("dish \($0)") }
            )
        ]
        let queries = FoodLookupTool.queries(from: input)

        XCTAssertEqual(queries.first, "chicken curry")
        XCTAssertEqual(queries.count, FoodLookupTool.maxQueries)
        XCTAssertFalse(queries.contains(""))
        XCTAssertEqual(Set(queries.map { $0.lowercased() }).count, queries.count)
    }

    /// The rendered result leads with the id and the name, because the name is
    /// what the model's choice turns on and the id is what it has to quote.
    func testRenderedCandidatesLeadWithIDAndName() {
        let rendered = FoodLookupTool.render([
            FoodLookupResult(
                query: "chicken curry",
                candidates: [FoodLookupCandidate(fdc: candidate())],
                note: nil
            )
        ])

        XCTAssertTrue(rendered.contains("QUERY: chicken curry"))
        XCTAssertTrue(rendered.contains("id: fdc:2706437"))
        XCTAssertTrue(rendered.contains("name: Chicken curry"))
        XCTAssertTrue(rendered.contains("107 kcal"))
        XCTAssertTrue(rendered.contains("1 cup = 240 g"))
    }

    /// A miss says so, and says what to do about it. "No candidates" alone
    /// would leave the model guessing whether to rephrase or to give up.
    func testAMissRendersAsAnInstructionRatherThanSilence() {
        let rendered = FoodLookupTool.render([
            FoodLookupResult(query: "khao soi", candidates: [], note: "No match. Estimate this one yourself, or try a broader description.")
        ])
        XCTAssertTrue(rendered.contains("no candidates"))
        XCTAssertTrue(rendered.contains("Estimate this one yourself"))
    }

    /// Nutrients the record never measured are named, so a zero that means
    /// "unknown" is not read by the model as a zero that means zero.
    func testUnmeasuredNutrientsAreNamedInTheRendering() {
        let food = FoodDataCentralFood(
            fdcID: 1, description: "Sparse", dataType: .foundation, brandOwner: nil,
            nutrientsPer100: MealNutrients(calories: 90, proteinG: 3, carbsG: 0, fatG: 0,
                                           fibreG: 0, sugarG: 0, sodiumMg: 0, satFatG: 0),
            missingNutrients: [.fibre, .sodium],
            portions: []
        )
        let rendered = FoodLookupTool.render([
            FoodLookupResult(query: "sparse", candidates: [FoodLookupCandidate(fdc: food)], note: nil)
        ])

        XCTAssertTrue(rendered.contains("NOT measured"))
        XCTAssertTrue(rendered.contains("portions: none published"))
    }
}

/// The end-to-end test: a real description, a real model, real lookups (#653).
///
/// ### Why this exists when the unit tests above pass
///
/// Everything above proves the device handles a provenance claim correctly. It
/// proves nothing about whether the model MAKES one. The rules that ask for it
/// live in a prompt, and a prompt is exactly the thing this repo has learned not
/// to trust without replaying it (#484 to #487, four rounds of strengthening
/// prose that all slipped).
///
/// So this runs the actual estimate and asserts on the provenance that comes
/// back. The description is one the user really logged, which scored 0.3 on
/// 2026-09-15 — the model recognised every dish and guessed every portion.
///
/// Costs a real Anthropic call. Skipped unless asked for.
final class LiveMealLookupTests: XCTestCase {

    private func liveClient() throws -> (AnthropicClient, FoodLookupService) {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["DEXTER_LIVE_MEAL_LOOKUP"] == "1" || env["TEST_RUNNER_DEXTER_LIVE_MEAL_LOOKUP"] == "1",
            "set DEXTER_LIVE_MEAL_LOOKUP=1 to spend a real Anthropic call"
        )
        let fdc = env["USDA_FDC_API_KEY"] ?? env["TEST_RUNNER_USDA_FDC_API_KEY"] ?? ""
        try XCTSkipIf(fdc.isEmpty, "no USDA_FDC_API_KEY in the environment")
        // `AnthropicClient` resolves its own key through `AppConfig`, which
        // reads the UNPREFIXED variable, so this one has to arrive that way.
        try XCTSkipIf(
            (AppConfig.anthropicAPIKey ?? "").isEmpty,
            "no ANTHROPIC_API_KEY reached the test process"
        )

        return (
            AnthropicClient(),
            FoodLookupService(fdc: FoodDataCentralClient(apiKey: fdc))
        )
    }

    /// A multi-dish home-cooked meal, with one portion the user stated.
    ///
    /// What is asserted is deliberately about PROVENANCE and not about calories.
    /// A test that pinned "this meal is 1,240 kcal" would fail the first time
    /// the dataset was revised or the model picked a different row, and it would
    /// be failing on something nobody can call wrong. What must hold is that the
    /// numbers stopped being invented.
    func testARealMealResolvesItsDishesToRealRecords() async throws {
        let (client, lookups) = try liveClient()
        let description = "for dinner 250 g cooked chicken Indian curry + 2 ghee-shallow fried parathas + 1 cup arhar dal"

        let grounded = try await client.estimateMeal(
            description: description,
            mealTypeHint: .dinner,
            lookups: lookups
        )

        XCTAssertFalse(
            grounded.lookupLedger.isEmpty,
            "the model was told to look food up and did not; the FOOD LOOKUP rule is not landing"
        )

        let resolution = FoodLookupResolution.resolve(
            grounded.estimate,
            ledger: grounded.lookupLedger,
            wasGrounded: !grounded.groundingSources.isEmpty,
            description: description
        )
        let checked = MealEstimateGuards.check(
            resolution.estimate,
            fallbackMealType: .dinner,
            groundingSources: grounded.groundingSources,
            provenance: resolution.resolved
        )

        // Printed rather than only asserted, because the useful output of this
        // test when it fails is WHICH dish went unsourced.
        for item in checked.items {
            print("""
            ITEM \(item.name) — \(item.portionDescription), \
            \(Int(item.calories.rounded())) kcal, \
            composition: \(item.densitySource?.displayName ?? "none"), \
            portion: \(item.massSource?.displayName ?? "none"), \
            id: \(item.sourceID ?? "-")
            """)
        }
        print("BAND \(checked.confidence)")

        // Not an exact count. A run on 2026-09-22 returned FOUR items, having
        // split the shallow-frying ghee out of the parathas, which is a better
        // decomposition than the three dishes named. Pinning the count would
        // fail the estimate for being more careful than the test.
        XCTAssertGreaterThanOrEqual(checked.items.count, 3, "at least the three named dishes")
        XCTAssertTrue(
            checked.items.allSatisfy { $0.densitySource != nil },
            "every item must carry a verdict once the composer path runs"
        )
        XCTAssertTrue(
            checked.items.allSatisfy { $0.densitySource == .lookedUp },
            "every dish here is in FNDDS; an unsourced one means the lookup rule is slipping"
        )
        XCTAssertTrue(
            checked.items.contains { $0.massSource == .stated },
            "the description states 250 g outright — see statedQuantities(in:)"
        )
        XCTAssertGreaterThanOrEqual(
            checked.confidence, 0.6,
            "this description scored 0.3 before #653"
        )
    }

    /// A Singapore dish, which is the case the whole shipped table exists for.
    ///
    /// FoodData Central answers "hainanese chicken rice" with "Chicken curry
    /// with rice". HPB holds four real chicken rice dishes with lab-analysed
    /// figures and a weighed plate. If the local table is doing its job, this
    /// resolves to an `sg:` id and the portion comes from that plate.
    func testALocalDishResolvesToTheSingaporeTable() async throws {
        let (client, lookups) = try liveClient()
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no shipped table to test against")

        let description = "hainanese chicken rice for lunch at the hawker centre"
        let grounded = try await client.estimateMeal(
            description: description,
            mealTypeHint: .lunch,
            lookups: lookups
        )
        let resolution = FoodLookupResolution.resolve(
            grounded.estimate,
            ledger: grounded.lookupLedger,
            wasGrounded: !grounded.groundingSources.isEmpty,
            description: description
        )

        for verdict in resolution.resolved {
            print("""
            ITEM \(verdict.item.name ?? "?") — \
            \(Int((verdict.item.portionQuantity ?? 0).rounded())) \(verdict.item.portionUnit ?? "") \
            composition: \(verdict.densitySource.displayName), \
            portion: \(verdict.massSource.displayName), id: \(verdict.sourceID ?? "-")
            """)
        }

        XCTAssertTrue(
            resolution.resolved.contains { ($0.sourceID ?? "").hasPrefix("sg:") },
            "the local table should have answered this; got \(resolution.resolved.map { $0.sourceID ?? "-" })"
        )
    }

    /// The other half of the claim: a dish no public database holds must NOT
    /// come back claiming a source.
    ///
    /// This is the test that would catch the worst outcome of the whole change.
    /// "Mala beef tendon noodles" is a real meal the user logged and FNDDS has
    /// nothing for it, but it does have plenty of noodle dishes that a careless
    /// match would attach to. An honest low beats a sourced wrong number.
    func testADishTheDatabaseDoesNotHoldIsNotFakedIntoASource() async throws {
        let (client, lookups) = try liveClient()

        let grounded = try await client.estimateMeal(
            description: "mala beef tendon noodles from a hawker stall, small bowl, did not eat the beef",
            mealTypeHint: .dinner,
            lookups: lookups
        )
        let resolution = FoodLookupResolution.resolve(
            grounded.estimate,
            ledger: grounded.lookupLedger,
            wasGrounded: !grounded.groundingSources.isEmpty
        )

        for verdict in resolution.resolved {
            print("""
            ITEM \(verdict.item.name ?? "?") — \
            composition: \(verdict.densitySource.displayName), \
            portion: \(verdict.massSource.displayName), \
            id: \(verdict.sourceID ?? "-")
            """)
        }

        // Every surviving id was verified against the ledger by construction,
        // so what this really asserts is that verification ran and that the
        // resolver did not invent a verdict for an item with no claim.
        for verdict in resolution.resolved where verdict.sourceID != nil {
            XCTAssertEqual(verdict.densitySource, .lookedUp)
            XCTAssertNotNil(
                grounded.lookupLedger.candidate(verdict.sourceID!),
                "a surviving id must be one the device offered"
            )
        }
    }
}

/// The two sources that come from the user rather than from a database (#653):
/// their own saved library, and the portions they have already accepted.
@MainActor
final class MealUserSourcesTests: XCTestCase {

    private var store: SwiftDataStore!
    private var meals: MealService!

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
        _ name: String,
        quantity: Double,
        unit: String = "g",
        daysAgo: Int = 1,
        isSuspect: Bool = false
    ) throws -> LocalMeal {
        let when = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
        return try meals.addMeal(
            date: when,
            loggedAt: when,
            mealType: .lunch,
            mealDescription: name,
            items: [MealItemEntry(name: name, portionQuantity: quantity, portionUnit: unit)],
            source: MealSource.composer,
            isSuspect: isSuspect,
            suspectReason: isSuspect ? "test" : nil
        )
    }

    private func allMeals() throws -> [LocalMeal] {
        try store.context.fetch(FetchDescriptor<LocalMeal>())
    }

    // MARK: - History

    /// The last portion wins, not an average. An average of 200 and 400 is a
    /// portion that never happened.
    func testTheMostRecentPortionWins() throws {
        try log("Latte", quantity: 200, unit: "ml", daysAgo: 5)
        try log("Latte", quantity: 176, unit: "ml", daysAgo: 1)

        let entries = MealPortionHistory.entries(from: try allMeals())
        let latte = try XCTUnwrap(entries.first { $0.name == "latte" })

        XCTAssertEqual(latte.quantity, 176, accuracy: 0.001)
        XCTAssertEqual(latte.timesLogged, 2)
    }

    /// A flagged meal's portions are exactly the ones nobody should quote back:
    /// the meal is held out of every total because its numbers are not trusted.
    func testASuspectMealContributesNoPortions() throws {
        try log("Biryani", quantity: 350, daysAgo: 1, isSuspect: true)
        let entries = MealPortionHistory.entries(from: try allMeals())
        XCTAssertTrue(entries.isEmpty)
    }

    /// Outside the window, and therefore out of the block.
    func testAnOldPortionFallsOutOfTheWindow() throws {
        try log("Khao soi", quantity: 550, daysAgo: 90)
        let entries = MealPortionHistory.entries(from: try allMeals())
        XCTAssertTrue(entries.isEmpty)
    }

    /// A portion stated in something that cannot be scaled is not a portion
    /// anything can reuse.
    func testAnUnscalableUnitIsNotCarried() throws {
        try log("Soup", quantity: 1, unit: "bowl", daysAgo: 1)
        XCTAssertTrue(MealPortionHistory.entries(from: try allMeals()).isEmpty)
    }

    /// Most repeated first, because the block is capped and the dishes worth
    /// carrying are the ones that come back.
    func testTheMostRepeatedDishesLeadTheBlock() throws {
        try log("Latte", quantity: 176, unit: "ml", daysAgo: 4)
        try log("Latte", quantity: 176, unit: "ml", daysAgo: 3)
        try log("Latte", quantity: 176, unit: "ml", daysAgo: 2)
        try log("Trail mix", quantity: 10, daysAgo: 1)

        let entries = MealPortionHistory.entries(from: try allMeals())
        XCTAssertEqual(entries.first?.name, "latte")
        XCTAssertEqual(entries.first?.timesLogged, 3)
    }

    /// The block says what the list is FOR, and what it is not for. Reading it
    /// as a composition source is the one misuse that would inflate the band.
    func testThePromptBlockSaysItIsAboutPortionsOnly() throws {
        try log("Latte", quantity: 176, unit: "ml", daysAgo: 1)
        let block = MealPortionHistory.promptBlock(MealPortionHistory.entries(from: try allMeals()))

        XCTAssertTrue(block.contains("latte: 176 ml"))
        XCTAssertTrue(block.contains("mass_source"))
        XCTAssertTrue(block.contains("say nothing about what the food CONTAINS"))
    }

    /// No history, no block. An empty heading would still cost tokens and would
    /// invite the model to explain its absence.
    func testAnEmptyHistoryRendersNothing() {
        XCTAssertTrue(MealPortionHistory.promptBlock([]).isEmpty)
    }

    // MARK: - Verifying a history claim

    func testAHistoryClaimMatchingTheListIsAccepted() {
        let entries = [MealPortionHistory.Entry(name: "latte", quantity: 176, unit: "ml", timesLogged: 3)]
        XCTAssertTrue(MealPortionHistory.supports(name: "Latte with whole milk", quantity: 176, unit: "ml", in: entries))
    }

    /// The quantity is matched strictly. A claim of history for a portion that
    /// is not in the list is the model's own number wearing a citation.
    func testAHistoryClaimWithADifferentPortionIsRejected() {
        let entries = [MealPortionHistory.Entry(name: "latte", quantity: 176, unit: "ml", timesLogged: 3)]
        XCTAssertFalse(MealPortionHistory.supports(name: "Latte", quantity: 300, unit: "ml", in: entries))
    }

    func testAHistoryClaimForADishNotInTheListIsRejected() {
        let entries = [MealPortionHistory.Entry(name: "latte", quantity: 176, unit: "ml", timesLogged: 3)]
        XCTAssertFalse(MealPortionHistory.supports(name: "Biryani", quantity: 176, unit: "ml", in: entries))
    }

    /// End to end through the resolver: an unsupported claim is demoted, so it
    /// cannot buy a confidence point.
    func testAnUnsupportedHistoryClaimIsDemotedByTheResolver() {
        let estimate = EstimatedMeal(
            mealType: "lunch",
            items: [EstimatedMealItem(name: "Biryani", portionQuantity: 350, portionUnit: "g", massSource: "history")]
        )
        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            portionHistory: [MealPortionHistory.Entry(name: "latte", quantity: 176, unit: "ml", timesLogged: 3)]
        )
        XCTAssertEqual(result.resolved.first?.massSource, .estimated)
    }

    func testASupportedHistoryClaimSurvivesTheResolver() {
        let estimate = EstimatedMeal(
            mealType: "lunch",
            items: [EstimatedMealItem(name: "Latte", portionQuantity: 176, portionUnit: "ml", massSource: "history")]
        )
        let result = FoodLookupResolution.resolve(
            estimate,
            ledger: FoodLookupLedger(),
            portionHistory: [MealPortionHistory.Entry(name: "latte", quantity: 176, unit: "ml", timesLogged: 3)]
        )
        XCTAssertEqual(result.resolved.first?.massSource, .history)
    }

    // MARK: - The library as a lookup source

    /// A library row's figures are restated per 100 so every candidate in one
    /// answer is on the same footing, and its usual portion is offered as a
    /// portion row.
    func testALibraryRowBecomesACandidateStatedPerHundred() throws {
        let library = FoodItemService(store: store)
        let row = try library.createItem(
            name: "Superyou Protein Wafer",
            basePortionQuantity: 40,
            basePortionUnit: FoodPortionUnit.grams.rawValue,
            nutrients: MealNutrients(
                calories: 186, proteinG: 10, carbsG: 20, fatG: 10,
                fibreG: 3, sugarG: 3.5, sodiumMg: 177, satFatG: 8.5
            ),
            defaultPortionQuantity: 40,
            source: FoodItemSource.openFoodFacts,
            isVerified: false
        )

        let candidate = FoodLookupCandidate(saved: row)

        XCTAssertEqual(candidate.id, "saved:\(row.clientUUID)")
        XCTAssertEqual(candidate.density, MealDensitySource.saved)
        XCTAssertEqual(candidate.nutrientsPer100.calories, 465, accuracy: 0.5, "186 kcal per 40 g is 465 per 100")
        XCTAssertEqual(candidate.portions.first?.description, "your usual portion")
        XCTAssertEqual(candidate.portions.first?.gramWeight ?? 0, 40, accuracy: 0.001)
    }

    /// A verified library id resolves as `saved`, not as `looked_up`. The two
    /// are both transcriptions and they are not the same claim.
    func testAVerifiedLibraryIDResolvesAsSaved() throws {
        let library = FoodItemService(store: store)
        let row = try library.createItem(
            name: "Whey protein shake",
            basePortionQuantity: 100,
            basePortionUnit: FoodPortionUnit.millilitres.rawValue,
            nutrients: MealNutrients(
                calories: 40, proteinG: 8, carbsG: 1, fatG: 0.5,
                fibreG: 0, sugarG: 0.5, sodiumMg: 30, satFatG: 0.2
            ),
            defaultPortionQuantity: 300,
            source: FoodItemSource.manual,
            isVerified: true
        )
        let ledger = FoodLookupLedger()
        ledger.record([
            FoodLookupResult(query: "whey", candidates: [FoodLookupCandidate(saved: row)], note: nil)
        ])

        let estimate = EstimatedMeal(
            mealType: .none,
            items: [
                EstimatedMealItem(
                    name: "Protein shake",
                    portionQuantity: 300, portionUnit: "ml",
                    calories: 999,
                    sourceID: "saved:\(row.clientUUID)",
                    massSource: "history"
                )
            ]
        )

        let result = FoodLookupResolution.resolve(estimate, ledger: ledger)

        XCTAssertEqual(result.resolved.first?.densitySource, .saved)
        XCTAssertEqual(
            result.estimate.items.first?.calories ?? 0, 120, accuracy: 0.5,
            "300 ml of a 40 kcal/100 ml shake, computed by the device"
        )
    }

    /// The library search is reachable from a real store, and matches on a word
    /// rather than on the whole phrase — the query is a generic description and
    /// the row is a short name.
    func testTheLibrarySearchMatchesAGenericQuery() throws {
        let library = FoodItemService(store: store)
        _ = try library.createItem(
            name: "Latte",
            basePortionQuantity: 176,
            basePortionUnit: FoodPortionUnit.millilitres.rawValue,
            nutrients: MealNutrients(calories: 100, proteinG: 5, carbsG: 8, fatG: 5,
                                     fibreG: 0, sugarG: 8, sodiumMg: 60, satFatG: 3),
            defaultPortionQuantity: 176,
            source: FoodItemSource.estimate,
            isVerified: false
        )

        let service = FoodLookupService.backedBy(store: store)
        XCTAssertEqual(service.library("latte with whole milk").count, 1)
        XCTAssertTrue(service.library("chicken biryani").isEmpty)
    }
}
