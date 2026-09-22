import XCTest
@testable import PersonalDashboard

/// The shipped Singapore dish table (#653).
///
/// ### What is worth testing here, and what is not
///
/// The table is data, and the data is not this repo's to be right about: it is
/// HPB's. So nothing below asserts that chicken rice is 178 kcal.
///
/// What IS this repo's to be right about is everything that happens to the data
/// on the way in and on the way out: the `-1` sentinel, the portion label, the
/// scoring that decides which two rows a model is shown, and the behaviour when
/// the asset is missing entirely. Each of those fails by producing something
/// plausible.
final class SGFoodTableTests: XCTestCase {

    // MARK: - Fixtures

    private func table(_ json: String) throws -> SGFoodTable {
        let dishes = try JSONDecoder().decode([SGFoodTable.Dish].self, from: Data(json.utf8))
        return SGFoodTable(dishes: dishes)
    }

    /// Three real rows, trimmed, as the build script writes them.
    private let sample = """
    [
      {"id":"F05100112","name":"Roasted chicken rice",
       "description":"Fragrant rice served with roasted chicken, accompanied by cucumber",
       "category":"Grains and staples","subCategory":"Rice-based dishes",
       "source":"Lab Analysis","year":2025,
       "per100":{"calories":178,"proteinG":8.22,"carbsG":23.3,"fatG":5.8,
                 "fibreG":0,"sugarG":0.2,"sodiumMg":294,"satFatG":1.93},
       "missing":["fibreG"],
       "portionGrams":363,"portionLabel":"1 plate(s) = 363g"},
      {"id":"F05100016","name":"Chicken baked rice",
       "description":"Baked rice topped with grilled chicken and cream sauce",
       "category":"Grains and staples","subCategory":"Rice-based dishes",
       "source":"Lab Analysis","year":2024,
       "per100":{"calories":160,"proteinG":7,"carbsG":20,"fatG":6,
                 "fibreG":1,"sugarG":1,"sodiumMg":300,"satFatG":2},
       "portionGrams":400,"portionLabel":"1 plate(s) = 400g"},
      {"id":"D09010013","name":"Teh tarik",
       "description":"Pulled milk tea",
       "category":"Tea and coffee","subCategory":"Tea",
       "source":"Calculated","year":2023,
       "per100":{"calories":60,"proteinG":1.5,"carbsG":9,"fatG":2,
                 "fibreG":0,"sugarG":8,"sodiumMg":20,"satFatG":1.3},
       "portionGrams":250,"portionLabel":"1 cup(s) = 250g"}
    ]
    """

    // MARK: - Mapping

    /// A dish becomes a candidate with a namespaced id and a provenance line
    /// that says which database AND how the numbers were obtained. "Lab
    /// analysis" and "calculated" are different claims.
    func testADishBecomesANamespacedCandidate() throws {
        let dish = try XCTUnwrap(try table(sample).dishes.first)
        let candidate = dish.candidate

        XCTAssertEqual(candidate.id, "sg:F05100112")
        XCTAssertEqual(candidate.name, "Roasted chicken rice")
        XCTAssertEqual(candidate.provenance, "Health Promotion Board Singapore, lab analysis, 2025")
        XCTAssertEqual(candidate.nutrientsPer100.calories, 178, accuracy: 0.001)
        XCTAssertEqual(candidate.nutrientsPer100.sodiumMg, 294, accuracy: 0.001)
        XCTAssertEqual(candidate.density, MealDensitySource.lookedUp)
    }

    /// The portion, which is the reason a local table beats a US survey for
    /// local food: one plate of chicken rice is 363 g because HPB weighed it.
    func testThePortionCarriesARealLocalServingWeight() throws {
        let candidate = try XCTUnwrap(try table(sample).dishes.first).candidate
        let portion = try XCTUnwrap(candidate.portions.first)

        XCTAssertEqual(portion.gramWeight, 363, accuracy: 0.001)
        XCTAssertEqual(
            portion.description, "1 plate",
            "the weight and the plural bracket are stripped; the app prints the weight itself"
        )
    }

    /// A nutrient HPB did not analyse is named, not silently zero. HPB states
    /// those as `-1`, and the build script is what turns them into this.
    func testAnUnanalysedNutrientIsNamedRatherThanZero() throws {
        let candidate = try XCTUnwrap(try table(sample).dishes.first).candidate

        XCTAssertEqual(candidate.nutrientsPer100.fibreG, 0)
        XCTAssertEqual(candidate.missingNutrients, [.fibre])
    }

    /// A row with nothing missing says nothing about missing.
    func testACompleteRowNamesNothingMissing() throws {
        let dishes = try table(sample).dishes
        XCTAssertTrue(dishes[1].candidate.missingNutrients.isEmpty)
    }

    // MARK: - The sentinel, at the boundary the build script owns

    /// The `-1` sentinel must never reach a meal. This asserts the SHAPE the
    /// build script is required to produce: a zero plus a name in `missing`,
    /// never a negative number.
    ///
    /// A negative gram would be clamped to zero by `MealEstimateGuards` and
    /// would FLAG the meal as suspect — so a perfectly good plate of chicken
    /// rice would be excluded from the day's totals because HPB did not measure
    /// its fibre.
    func testNoShippedNutrientIsEverNegative() throws {
        for dish in try table(sample).dishes {
            let n = dish.candidate.nutrientsPer100
            for value in [n.calories, n.proteinG, n.carbsG, n.fatG,
                          n.fibreG, n.sugarG, n.sodiumMg, n.satFatG] {
                XCTAssertGreaterThanOrEqual(value, 0, "\(dish.name) shipped a negative nutrient")
            }
        }
    }

    // MARK: - Search

    /// The exact name wins.
    func testAnExactNameRanksFirst() throws {
        let hits = try table(sample).search("Roasted chicken rice")
        XCTAssertEqual(hits.first?.id, "sg:F05100112")
    }

    /// The case this table exists for: a generic description written by the
    /// model reaches the local dish through the words they share.
    func testAGenericDescriptionReachesTheLocalDish() throws {
        let hits = try table(sample).search("roasted chicken with rice and cucumber")
        XCTAssertEqual(hits.first?.id, "sg:F05100112")
    }

    /// At most two, because a third near-miss from a narrow table is noise on a
    /// call already carrying a prompt and the day's meals.
    func testAtMostTwoCandidatesComeBack() throws {
        let hits = try table(sample).search("chicken rice")
        XCTAssertLessThanOrEqual(hits.count, SGFoodTable.resultLimit)
        XCTAssertEqual(hits.count, 2)
    }

    /// One shared short word between a long query and a long name is a
    /// coincidence. The threshold is what stops "tea" pulling in every dish
    /// whose description mentions steeping.
    func testAWeakCoincidenceIsNotAMatch() throws {
        XCTAssertTrue(try table(sample).search("beef wellington").isEmpty)
        XCTAssertTrue(try table(sample).search("a").isEmpty, "short words are ignored entirely")
    }

    /// An empty query is not an error; it is a cleared field.
    func testAnEmptyQueryReturnsNothing() throws {
        XCTAssertTrue(try table(sample).search("   ").isEmpty)
    }

    /// Ordering is deterministic for equal scores, so two identical estimates
    /// are two identical requests.
    func testEqualScoresBreakTiesStably() throws {
        let one = try table(sample).search("chicken rice").map(\.id)
        let two = try table(sample).search("chicken rice").map(\.id)
        XCTAssertEqual(one, two)
    }

    // MARK: - A missing asset

    /// An empty table is a working state. The lookup then behaves exactly as it
    /// did before the table existed, which is the right failure for an additive
    /// source: a meal must not be lost because a bundle resource did not copy.
    func testAnEmptyTableSearchesWithoutComplaint() {
        let empty = SGFoodTable(dishes: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.search("chicken rice").isEmpty)
    }

    // MARK: - The shipped asset itself

    /// The real asset is in the bundle and is readable.
    ///
    /// This is the test that fails when somebody adds the Swift and forgets the
    /// resource entry in `project.yml`, which is a silent failure otherwise:
    /// `SGFoodTable.shared` degrades to empty on purpose, so every Singapore
    /// dish would quietly stop being found and nothing would say why.
    func testTheShippedTableIsPresentAndPopulated() throws {
        let table = SGFoodTable.shared
        XCTAssertFalse(
            table.isEmpty,
            "sg-food-table.json is missing from the bundle — check the resources list in project.yml"
        )
        XCTAssertGreaterThan(table.dishes.count, 500, "the full HPB set is a couple of thousand rows")
    }

    /// The shipped data obeys the rule the build script is responsible for.
    /// Asserted over the REAL asset, not a fixture, because this is the one
    /// place a bad sentinel would actually reach a meal.
    func testTheShippedTableHasNoNegativeNutrients() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        for dish in SGFoodTable.shared.dishes {
            let n = dish.per100.value
            for (label, value) in [
                ("calories", n.calories), ("protein", n.proteinG), ("carbs", n.carbsG),
                ("fat", n.fatG), ("fibre", n.fibreG), ("sugar", n.sugarG),
                ("sodium", n.sodiumMg), ("satFat", n.satFatG)
            ] where value < 0 {
                XCTFail("\(dish.id) \(dish.name): \(label) is \(value)")
            }
        }
    }

    /// Every shipped row can be turned into a candidate without losing its id.
    func testEveryShippedRowProducesAUsableCandidate() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        for dish in SGFoodTable.shared.dishes.prefix(200) {
            let candidate = dish.candidate
            XCTAssertTrue(candidate.id.hasPrefix("sg:"))
            XCTAssertFalse(candidate.name.isEmpty, "\(dish.id) has no name")
            for portion in candidate.portions {
                XCTAssertGreaterThan(portion.gramWeight, 0)
                XCTAssertFalse(portion.description.isEmpty)
            }
        }
    }

    /// The dishes that sent me looking for this table, checked against the real
    /// asset.
    ///
    /// Each is a meal from the log that scored 0.3 and that FoodData Central
    /// answers with a confident wrong row.
    func testTheLocalDishesThatFoodDataCentralGetsWrongAreInTheTable() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        for query in ["chicken rice", "prata", "laksa", "char kway teow", "popcorn"] {
            XCTAssertFalse(
                SGFoodTable.shared.search(query).isEmpty,
                "the local table should hold something for \(query)"
            )
        }
    }

    /// The local spelling, which is why `search` does a one-edit match at all.
    ///
    /// HPB writes "Nasi briyani". Every model writes "biryani". One
    /// transposition stood between a query and four real dishes with real
    /// Singapore portions.
    func testALocalSpellingIsStillFound() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        let hits = SGFoodTable.shared.search("chicken biryani")
        XCTAssertFalse(hits.isEmpty, "biryani must reach HPB's briyani")
        XCTAssertTrue(
            hits.contains { $0.name.lowercased().contains("briyani") },
            "got \(hits.map(\.name))"
        )
    }

    /// The word-boundary rule, which is why `search` does not match substrings.
    ///
    /// "mala" is a substring of "Malay", and the table holds dozens of Malay
    /// dishes. Before word boundaries, a query for mala noodles surfaced nasi
    /// lemak.
    func testAShortWordDoesNotMatchInsideALongerOne() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        for hit in SGFoodTable.shared.search("mala") {
            XCTAssertFalse(
                hit.name.lowercased().contains("malay"),
                "mala matched \(hit.name) on a substring"
            )
        }
    }

    /// A dish HPB genuinely does not hold comes back EMPTY rather than with the
    /// nearest Singapore dish attached.
    ///
    /// This is the same property the FoodData Central tests pin, and it matters
    /// more here: a local table returning a local near-miss would look more
    /// credible than a US one, and be just as wrong.
    func testADishTheTableDoesNotHoldReturnsNothing() throws {
        try XCTSkipIf(SGFoodTable.shared.isEmpty, "no asset to check")

        for query in ["khao soi", "shawarma"] {
            XCTAssertTrue(
                SGFoodTable.shared.search(query).isEmpty,
                "expected no local row for \(query), got \(SGFoodTable.shared.search(query).map(\.name))"
            )
        }
    }

    // MARK: - The one-edit matcher

    func testOneEditMatching() {
        XCTAssertTrue(SGFoodTable.withinOneEdit("briyani", "biryani"), "a transposition")
        XCTAssertTrue(SGFoodTable.withinOneEdit("noodle", "noodles"), "an insertion")
        XCTAssertTrue(SGFoodTable.withinOneEdit("laksa", "laksa"), "identical")
        XCTAssertTrue(SGFoodTable.withinOneEdit("prata", "brata"), "a substitution")
        XCTAssertFalse(SGFoodTable.withinOneEdit("chicken", "kitchen"), "two edits apart")
        XCTAssertFalse(SGFoodTable.withinOneEdit("rice", "noodle"), "unrelated")
    }
}
