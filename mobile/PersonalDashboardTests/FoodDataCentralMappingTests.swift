import XCTest
@testable import PersonalDashboard

/// Pure mapping tests for the FoodData Central client (#653).
///
/// ### Why these are worth having
///
/// The same argument `OpenFoodFactsMappingTests` makes, with one addition that
/// is specific to this database.
///
/// The client is plumbing: a wrong URL fails loudly and immediately. The
/// MAPPING fails by producing a plausible number, and a plausible number is
/// written into a meal, summed into a day, and averaged over a week without
/// anything objecting. `MealEstimateGuards` cannot help, because it grades what
/// a MODEL returned and a looked-up figure never goes near it.
///
/// The addition is that this API states one concept in TWO shapes. `/foods/
/// search` returns nutrients flat, as `{nutrientId, value}`. `/food/{id}`
/// returns them nested, as `{nutrient: {id}, amount}`. A decoder written for
/// either one reads every nutrient of the other as ABSENT, which does not throw
/// and does not warn: it produces a food whose eight values are all zero and
/// whose `missingNutrients` nobody reads. Both shapes are pinned below.
///
/// Every test here runs off a JSON string in this file. No network, no key, no
/// store. The tests that do hit the live API are in the class at the bottom and
/// skip unless an environment variable asks for them.
final class FoodDataCentralMappingTests: XCTestCase {

    // MARK: - Fixtures

    /// `Chicken curry`, fdcId 2706437, as `/foods/search` returns it.
    ///
    /// A real record, trimmed to the eight nutrients plus one distractor. The
    /// live response carries 65 nutrients; the extra one here is Water, which
    /// is present on every FNDDS row and must be ignored rather than mistaken
    /// for anything.
    private let chickenCurrySearchJSON = """
    {
      "totalHits": 455,
      "foods": [
        {
          "fdcId": 2706437,
          "description": "Chicken curry",
          "dataType": "Survey (FNDDS)",
          "foodNutrients": [
            {"nutrientId": 1003, "nutrientName": "Protein", "unitName": "G", "value": 6.48},
            {"nutrientId": 1004, "nutrientName": "Total lipid (fat)", "unitName": "G", "value": 6.48},
            {"nutrientId": 1005, "nutrientName": "Carbohydrate, by difference", "unitName": "G", "value": 6.54},
            {"nutrientId": 1008, "nutrientName": "Energy", "unitName": "KCAL", "value": 107},
            {"nutrientId": 1051, "nutrientName": "Water", "unitName": "G", "value": 78.1},
            {"nutrientId": 1079, "nutrientName": "Fiber, total dietary", "unitName": "G", "value": 1.4},
            {"nutrientId": 1093, "nutrientName": "Sodium, Na", "unitName": "MG", "value": 376},
            {"nutrientId": 1258, "nutrientName": "Fatty acids, total saturated", "unitName": "G", "value": 1.56},
            {"nutrientId": 2000, "nutrientName": "Total Sugars", "unitName": "G", "value": 2.56}
          ]
        }
      ]
    }
    """

    /// The same food as `/food/{id}` returns it: nutrients NESTED, and the
    /// portion table that only this endpoint carries.
    ///
    /// The two portion rows are the live ones, verified 2026-09-22. Note that
    /// `measureUnit` is the placeholder "undetermined" and `amount` is null on
    /// both, so `portionDescription` is the only field that says what the
    /// measure is.
    private let chickenCurryDetailJSON = """
    {
      "fdcId": 2706437,
      "description": "Chicken curry",
      "dataType": "Survey (FNDDS)",
      "foodNutrients": [
        {"type": "FoodNutrient", "nutrient": {"id": 1003, "name": "Protein", "unitName": "g"}, "amount": 6.48},
        {"type": "FoodNutrient", "nutrient": {"id": 1004, "name": "Total lipid (fat)", "unitName": "g"}, "amount": 6.48},
        {"type": "FoodNutrient", "nutrient": {"id": 1005, "name": "Carbohydrate, by difference", "unitName": "g"}, "amount": 6.54},
        {"type": "FoodNutrient", "nutrient": {"id": 1008, "name": "Energy", "unitName": "kcal"}, "amount": 107},
        {"type": "FoodNutrient", "nutrient": {"id": 1079, "name": "Fiber, total dietary", "unitName": "g"}, "amount": 1.4},
        {"type": "FoodNutrient", "nutrient": {"id": 1093, "name": "Sodium, Na", "unitName": "mg"}, "amount": 376},
        {"type": "FoodNutrient", "nutrient": {"id": 1258, "name": "Fatty acids, total saturated", "unitName": "g"}, "amount": 1.56},
        {"type": "FoodNutrient", "nutrient": {"id": 2000, "name": "Total Sugars", "unitName": "g"}, "amount": 2.56}
      ],
      "foodPortions": [
        {
          "portionDescription": "Quantity not specified",
          "gramWeight": 240,
          "amount": null,
          "modifier": "90000",
          "measureUnit": {"id": 9999, "name": "undetermined", "abbreviation": "undetermined"}
        },
        {
          "portionDescription": "1 cup",
          "gramWeight": 240,
          "amount": null,
          "modifier": "10205",
          "measureUnit": {"id": 9999, "name": "undetermined", "abbreviation": "undetermined"}
        }
      ]
    }
    """

    // MARK: - Helpers

    private func searchFood(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FoodDataCentralFood {
        let decoded = try JSONDecoder().decode(
            FoodDataCentralSearchResponse.self,
            from: Data(json.utf8)
        )
        let row = try XCTUnwrap(
            decoded.foods.first,
            "the fixture must decode to at least one food",
            file: file,
            line: line
        )
        return row.food
    }

    private func detailFood(_ json: String) throws -> FoodDataCentralFood {
        try JSONDecoder()
            .decode(FoodDataCentralDetail.self, from: Data(json.utf8))
            .food
    }

    // MARK: - The two shapes

    /// The flat search shape maps to all eight.
    func testSearchRowMapsEveryNutrient() throws {
        let food = try searchFood(chickenCurrySearchJSON)

        XCTAssertEqual(food.fdcID, 2706437)
        XCTAssertEqual(food.description, "Chicken curry")
        XCTAssertEqual(food.dataType, .survey)

        XCTAssertEqual(food.nutrientsPer100.calories, 107, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.proteinG, 6.48, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.fatG, 6.48, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.carbsG, 6.54, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.fibreG, 1.4, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.sugarG, 2.56, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.sodiumMg, 376, accuracy: 0.001)
        XCTAssertEqual(food.nutrientsPer100.satFatG, 1.56, accuracy: 0.001)

        XCTAssertTrue(food.missingNutrients.isEmpty, "this record carries all eight")
    }

    /// The nested detail shape maps to the SAME eight.
    ///
    /// The point of asserting the same numbers twice is that the two decoders
    /// are separate code. A change to one that is not made to the other shows
    /// up here as a disagreement rather than as a quietly zeroed meal.
    func testDetailShapeMapsToTheSameNutrientsAsSearch() throws {
        let fromSearch = try searchFood(chickenCurrySearchJSON)
        let fromDetail = try detailFood(chickenCurryDetailJSON)

        XCTAssertEqual(fromDetail.nutrientsPer100, fromSearch.nutrientsPer100)
        XCTAssertTrue(fromDetail.missingNutrients.isEmpty)
    }

    /// The search endpoint carries no portion table, and the food must say so
    /// rather than inventing an empty-but-plausible default.
    func testSearchRowHasNoPortions() throws {
        let food = try searchFood(chickenCurrySearchJSON)
        XCTAssertTrue(food.portions.isEmpty)
        XCTAssertNil(food.defaultPortion)
    }

    // MARK: - The mass half

    /// The portion table, which is the reason this database is here at all.
    func testDetailCarriesPortionWeights() throws {
        let food = try detailFood(chickenCurryDetailJSON)

        XCTAssertEqual(food.portions.count, 2)
        XCTAssertEqual(food.portions.map(\.description), ["Quantity not specified", "1 cup"])
        XCTAssertEqual(food.portions.map(\.gramWeight), [240, 240])
    }

    /// "Quantity not specified" is the dataset's own default serving, and it is
    /// identified by its DESCRIPTION because nothing structural marks it: its
    /// `measureUnit` is the placeholder "undetermined" and its `amount` is null.
    func testDefaultPortionPrefersTheUnspecifiedRow() throws {
        let food = try detailFood(chickenCurryDetailJSON)
        let fallback = try XCTUnwrap(food.defaultPortion)

        XCTAssertEqual(fallback.description, "Quantity not specified")
        XCTAssertTrue(fallback.isUnspecifiedQuantity)
        XCTAssertEqual(fallback.gramWeight, 240, accuracy: 0.001)
    }

    /// With no unspecified row, the first named measure is the default. A food
    /// that states only "1 piece" still has an answer to "how much is one".
    func testDefaultPortionFallsBackToTheFirstNamedMeasure() throws {
        let json = """
        {
          "fdcId": 1, "description": "Roti", "dataType": "Survey (FNDDS)",
          "foodNutrients": [{"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 300}],
          "foodPortions": [
            {"portionDescription": "1 piece", "gramWeight": 45, "amount": null,
             "measureUnit": {"name": "undetermined"}}
          ]
        }
        """
        let food = try detailFood(json)
        let fallback = try XCTUnwrap(food.defaultPortion)

        XCTAssertEqual(fallback.description, "1 piece")
        XCTAssertFalse(fallback.isUnspecifiedQuantity)
        XCTAssertEqual(fallback.gramWeight, 45, accuracy: 0.001)
    }

    /// Foundation and SR Legacy leave `portionDescription` null and state the
    /// measure as an amount plus a unit instead. Both shapes must read as one
    /// sentence, or half the database's portions come back unlabelled.
    func testAmountAndUnitPortionsAreLabelled() throws {
        let json = """
        {
          "fdcId": 2, "description": "Rice, white, cooked", "dataType": "SR Legacy",
          "foodNutrients": [{"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 130}],
          "foodPortions": [
            {"portionDescription": null, "gramWeight": 158, "amount": 1,
             "measureUnit": {"name": "cup"}},
            {"portionDescription": null, "gramWeight": 79, "amount": 0.5,
             "measureUnit": {"name": "cup"}}
          ]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.portions.map(\.description), ["1 cup", "0.5 cup"])
    }

    /// A portion with no usable label and one with no weight are both dropped.
    /// A row the model cannot name is a row it cannot choose, and a zero weight
    /// would scale every nutrient to nothing.
    func testUnusablePortionsAreDropped() throws {
        let json = """
        {
          "fdcId": 3, "description": "Mystery", "dataType": "Foundation",
          "foodNutrients": [{"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 100}],
          "foodPortions": [
            {"portionDescription": null, "gramWeight": 100, "amount": null,
             "measureUnit": {"name": "undetermined"}},
            {"portionDescription": "1 cup", "gramWeight": 0, "amount": null,
             "measureUnit": {"name": "undetermined"}},
            {"portionDescription": "1 slice", "gramWeight": 30, "amount": null,
             "measureUnit": {"name": "undetermined"}}
          ]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.portions.map(\.description), ["1 slice"])
    }

    // MARK: - Energy, the one unit that changes meaning

    /// Nutrient 1008 in KILOJOULES must be converted, not taken at face value.
    ///
    /// Some Foundation rows state it that way. Reading 447 kJ as 447 kcal is a
    /// 4.184x error, and every guard downstream would wave it through as a
    /// large meal rather than a broken unit.
    func testEnergyInKilojoulesIsConverted() throws {
        let json = """
        {
          "fdcId": 4, "description": "Kilojoule food", "dataType": "Foundation",
          "foodNutrients": [{"nutrient": {"id": 1008, "unitName": "kJ"}, "amount": 447}]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.nutrientsPer100.calories, 447 / 4.184, accuracy: 0.01)
    }

    /// With no 1008 at all, the Atwater-specific row answers. Preferred over
    /// the general one because it is the more precisely derived of the two.
    func testEnergyFallsBackToAtwaterWhenTheKcalRowIsAbsent() throws {
        let json = """
        {
          "fdcId": 5, "description": "Atwater food", "dataType": "Foundation",
          "foodNutrients": [
            {"nutrient": {"id": 2047, "unitName": "kcal"}, "amount": 210},
            {"nutrient": {"id": 2048, "unitName": "kcal"}, "amount": 205}
          ]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.nutrientsPer100.calories, 205, accuracy: 0.001)
    }

    /// Sugar under its older id. An SR Legacy row that carries only 1063 must
    /// not read as a food with no sugar in it.
    func testSugarFallsBackToTheOlderNutrientID() throws {
        let json = """
        {
          "fdcId": 6, "description": "Legacy sugar food", "dataType": "SR Legacy",
          "foodNutrients": [
            {"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 380},
            {"nutrient": {"id": 1063, "unitName": "g"}, "amount": 12.5}
          ]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.nutrientsPer100.sugarG, 12.5, accuracy: 0.001)
        XCTAssertFalse(food.missingNutrients.contains(.sugar))
    }

    // MARK: - Absent is not zero

    /// A nutrient the record does not carry sits at zero AND is named, so a
    /// caller can tell "no fibre in this" from "nobody measured the fibre".
    func testAbsentNutrientsAreNamedRatherThanSilentlyZero() throws {
        let json = """
        {
          "fdcId": 7, "description": "Sparse food", "dataType": "Foundation",
          "foodNutrients": [
            {"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 90},
            {"nutrient": {"id": 1003, "unitName": "g"}, "amount": 3}
          ]
        }
        """
        let food = try detailFood(json)

        XCTAssertEqual(food.nutrientsPer100.fibreG, 0)
        XCTAssertEqual(
            food.missingNutrients,
            [.carbs, .fat, .fibre, .sugar, .sodium, .saturatedFat],
            "every unmeasured nutrient is named, in Nutrient.allCases order"
        )
        XCTAssertFalse(food.missingNutrients.contains(.calories))
        XCTAssertFalse(food.missingNutrients.contains(.protein))
    }

    /// A record with no energy row at all names calories as missing rather than
    /// reporting a zero-calorie food.
    func testAbsentEnergyIsNamed() throws {
        let json = """
        {
          "fdcId": 8, "description": "No energy row", "dataType": "Foundation",
          "foodNutrients": [{"nutrient": {"id": 1003, "unitName": "g"}, "amount": 3}]
        }
        """
        let food = try detailFood(json)
        XCTAssertEqual(food.nutrientsPer100.calories, 0)
        XCTAssertTrue(food.missingNutrients.contains(.calories))
    }

    // MARK: - Scaling, which is where mass and density meet

    /// The two halves multiplied. 240 g of a 107 kcal/100 g curry is 257 kcal,
    /// and neither number was invented.
    func testNutrientsScaleToAPortionWeight() throws {
        let food = try detailFood(chickenCurryDetailJSON)
        let oneCup = try XCTUnwrap(food.portions.first { $0.description == "1 cup" })

        let scaled = food.nutrients(forGrams: oneCup.gramWeight)

        XCTAssertEqual(scaled.calories, 256.8, accuracy: 0.1)
        XCTAssertEqual(scaled.proteinG, 15.55, accuracy: 0.01)
        XCTAssertEqual(scaled.sodiumMg, 902.4, accuracy: 0.1)
    }

    // MARK: - The library draft

    /// A hit saved into the library keeps its provenance, so a later reader can
    /// tell a transcription from a guess.
    func testDraftCarriesProvenanceAndTheDatasetServing() throws {
        let draft = try detailFood(chickenCurryDetailJSON).draft()

        XCTAssertEqual(draft.name, "Chicken curry")
        XCTAssertEqual(draft.basePortionQuantity, 100, accuracy: 0.001)
        XCTAssertEqual(draft.basePortionUnit, .grams)
        XCTAssertEqual(draft.calories, 107, accuracy: 0.001)
        XCTAssertEqual(draft.sodiumMg, 376, accuracy: 0.001)
        XCTAssertEqual(
            draft.defaultPortionQuantity, 240, accuracy: 0.001,
            "the dataset's own serving, not the 100 g the numbers are stated at"
        )
        XCTAssertEqual(draft.externalSource, FoodItemSource.usdaFDC)
        XCTAssertEqual(draft.externalID, "2706437")
        XCTAssertEqual(draft.source, FoodItemSource.usdaFDC)
        XCTAssertNil(draft.barcode, "a dish has no barcode")
    }

    /// With no portion table the draft opens at 100 g rather than at nothing.
    func testDraftWithoutPortionsDefaultsToOneHundredGrams() throws {
        let draft = try searchFood(chickenCurrySearchJSON).draft()
        XCTAssertEqual(draft.defaultPortionQuantity, 100, accuracy: 0.001)
    }

    // MARK: - Configuration

    /// With no key the client reports itself unconfigured and every call
    /// throws, rather than sending a keyless request that comes back 403.
    func testAnUnconfiguredClientRefusesBeforeSendingAnything() async throws {
        let client = FoodDataCentralClient(apiKey: nil)
        XCTAssertFalse(client.isConfigured)

        do {
            _ = try await client.search("chicken curry")
            XCTFail("a keyless search must throw")
        } catch let error as FoodDataCentralError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    /// An empty query is not an error. It returns nothing, even unconfigured,
    /// because a cleared field is a working state.
    func testAnEmptyQueryReturnsNothing() async throws {
        let client = FoodDataCentralClient(apiKey: "unused")
        let hits = try await client.search("   ")
        XCTAssertTrue(hits.isEmpty)
    }

    /// The datasets are asked for in the order that matches how a meal is
    /// described: dishes first, ingredients after, and Branded excluded so one
    /// brand's twelve flavours cannot fill a generic query's five slots.
    func testDefaultDatasetOrderPutsDishesFirst() {
        XCTAssertEqual(
            FoodDataCentralDataType.defaultOrder,
            [.survey, .foundation, .srLegacy]
        )
        XCTAssertFalse(FoodDataCentralDataType.defaultOrder.contains(.branded))
    }
}

/// The tests that actually call USDA FoodData Central (#653).
///
/// Skipped unless asked for, like every other live suite in this repo. These
/// cost no money — the API is free — but they need a key and a network, and a
/// suite that fails on a plane is a suite people stop running.
///
/// ### What these pin that the fixtures cannot
///
/// The fixtures pin the mapping against a response shape recorded on
/// 2026-09-22. They cannot notice the shape CHANGING. They also cannot notice
/// the thing that most affects this feature in practice, which is whether a
/// given query still finds the dish it found before.
///
/// ### Why this whole file is in the iOS suite and not the Mac one
///
/// `OpenFoodFactsMappingTests` is in `DexterMacTests`, so that is the obvious
/// home and it is the wrong one. `DexterMacTests` is app-hosted with no
/// `XCTestConfigurationFilePath` guard in `DexterMacApp`, so running ANY test
/// in it — `-only-testing` included — boots a real instance against the user's
/// live store, runs a sync pass into the real iCloud folder, and runs the trip
/// cover reaper. The iOS suite is app-hosted in a SIMULATOR, which has its own
/// store and its own container. Nothing here needs to touch the real one.
///
/// The cost is that a `TEST_RUNNER_`-prefixed variable is how a value reaches a
/// simulator test process, so the live class below reads both spellings.
final class FoodDataCentralLiveTests: XCTestCase {

    private func liveClient() throws -> FoodDataCentralClient {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["DEXTER_LIVE_FDC"] == "1" || env["TEST_RUNNER_DEXTER_LIVE_FDC"] == "1",
            "set DEXTER_LIVE_FDC=1 to call FoodData Central for real"
        )
        // Both spellings: a simulator test process receives a variable only
        // when the runner prefixes it, and a Mac process receives it bare.
        let key = env["USDA_FDC_API_KEY"]
            ?? env["TEST_RUNNER_USDA_FDC_API_KEY"]
            ?? ""
        try XCTSkipIf(key.isEmpty, "no USDA_FDC_API_KEY in the environment")
        return FoodDataCentralClient(apiKey: key)
    }

    /// A dish search still answers, and the winner still carries the eight.
    func testACompositeDishIsFound() async throws {
        let client = try liveClient()
        let hits = try await client.search("chicken curry")

        let top = try XCTUnwrap(hits.first)
        XCTAssertTrue(
            top.description.lowercased().contains("curry"),
            "expected a curry, got \(top.description)"
        )
        XCTAssertGreaterThan(top.nutrientsPer100.calories, 0)
        XCTAssertGreaterThan(top.nutrientsPer100.proteinG, 0)
    }

    /// The portion table still arrives on the detail call, which is the whole
    /// reason for the second round trip.
    func testAChosenFoodArrivesWithItsPortionTable() async throws {
        let client = try liveClient()
        let hits = try await client.search("chicken curry")
        let hit = try XCTUnwrap(hits.first)
        let food = await client.withPortions(hit)

        XCTAssertFalse(
            food.portions.isEmpty,
            "an FNDDS dish must carry portion weights; without them the mass half is unanswered"
        )
        let serving = try XCTUnwrap(food.defaultPortion)
        XCTAssertGreaterThan(serving.gramWeight, 0)
    }

    /// The relevance limit, pinned as a FACT rather than as a wish.
    ///
    /// This is the test that shaped the client's design, so it is worth stating
    /// what it found. The expectation going in was that a local dish name
    /// returns NOTHING, which is what a narrower search had suggested. What it
    /// actually returns is five confident wrong answers, none of which is the
    /// dish:
    ///
    ///     Chicken curry with rice
    ///     Rice, fried, with chicken
    ///     Babyfood, dinner, chicken and rice
    ///     Burrito bowl, chicken, with rice
    ///     Burrito, chicken, with rice, cheese
    ///
    /// An empty result is honest and a caller can fall back from it. A wrong
    /// result carrying a real `fdcId` is not: it would price Hainanese chicken
    /// rice as a curry and label the figure as looked up. That is why this
    /// client has no take-the-first-hit helper — see `withPortions(_:)`.
    ///
    /// The assertion is deliberately weak on WHICH wrong answers come back,
    /// because the dataset is revised and they will drift. It is strong on the
    /// thing the design depends on: the top hit is not the dish, so something
    /// with judgement has to sit between the search and the meal.
    func testALocalDishNameReturnsHitsThatAreNotTheDish() async throws {
        let client = try liveClient()
        let hits = try await client.search("hainanese chicken rice")

        try XCTSkipIf(hits.isEmpty, "an empty result is the honest outcome; nothing to guard")

        let top = try XCTUnwrap(hits.first)
        let description = top.description.lowercased()
        XCTAssertFalse(
            description.contains("hainanese"),
            """
            FDC now names the dish itself, so the no-take-the-first-hit rule in \
            FoodDataCentralClient should be revisited rather than left as folklore. \
            Top hit: \(top.description)
            """
        )
    }
}

/// What actually goes on the wire, and what comes back off it, with no network
/// involved (#653).
///
/// The mapping tests above prove the client understands a response. These prove
/// it asks the right question and reads the right meaning out of a status code.
/// Both failures are silent in their own way: a dropped `dataType` gives
/// plausible hits from the wrong dataset, and a 429 read as a generic failure
/// makes the client retry an allowance that cannot refill for an hour.
final class FoodDataCentralRequestTests: XCTestCase {

    private func client(status: Int = 200, body: String = "{\"foods\":[]}") -> FoodDataCentralClient {
        FoodDataCentralProbe.reset()
        FoodDataCentralProbe.status = status
        FoodDataCentralProbe.body = body

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FoodDataCentralProbe.self]
        return FoodDataCentralClient(
            session: URLSession(configuration: config),
            apiKey: "test-key"
        )
    }

    /// Every parameter the search endpoint needs, and crucially NOT `dataType`.
    ///
    /// Sending `dataType=Survey (FNDDS)` makes the API answer HTTP 400 from
    /// nginx for about three requests in five — measured, see
    /// `FoodDataCentralClient.wirePageSize`. The parameter is therefore never
    /// sent and the dataset filter runs on the device.
    ///
    /// This is asserted rather than left to the live tests because the failure
    /// it guards is INTERMITTENT. A dataType parameter reintroduced here would
    /// pass a live run two times in five, which is exactly often enough to be
    /// merged.
    func testSearchNeverSendsTheDataTypeParameter() async throws {
        let client = client()
        _ = try await client.search("chicken curry")

        let url = try XCTUnwrap(FoodDataCentralProbe.lastURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.host, "api.nal.usda.gov")
        XCTAssertEqual(components.path, "/fdc/v1/foods/search")
        XCTAssertEqual(items.first { $0.name == "api_key" }?.value, "test-key")
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "chicken curry")
        XCTAssertEqual(
            items.first { $0.name == "pageSize" }?.value, "25",
            "the wider page is what makes device-side filtering viable"
        )
        XCTAssertTrue(
            items.filter { $0.name == "dataType" }.isEmpty,
            "dataType=Survey (FNDDS) answers 400 three times in five; filter on the device instead"
        )
    }

    /// The dataset filter runs on the device, keeps the API's relevance order,
    /// and caps the result at what the caller is shown.
    func testDatasetsAreFilteredOnTheDevice() async throws {
        let client = client(body: """
        {"foods": [
          {"fdcId": 1, "description": "Branded curry sauce", "dataType": "Branded",
           "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 50}]},
          {"fdcId": 2, "description": "Chicken curry", "dataType": "Survey (FNDDS)",
           "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 107}]},
          {"fdcId": 3, "description": "Curry powder", "dataType": "SR Legacy",
           "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 325}]},
          {"fdcId": 4, "description": "Mystery", "dataType": "Experimental",
           "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 1}]}
        ]}
        """)

        let hits = try await client.search("curry")

        XCTAssertEqual(
            hits.map(\.fdcID), [2, 3],
            "Branded is not in the default order, and an unknown dataset is dropped"
        )
    }

    /// A caller asking for one dataset gets only that one.
    func testAFilteredSearchHonoursTheRequestedDatasets() async throws {
        let client = client(body: """
        {"foods": [
          {"fdcId": 2, "description": "Chicken curry", "dataType": "Survey (FNDDS)",
           "foodNutrients": []},
          {"fdcId": 3, "description": "Curry powder", "dataType": "SR Legacy",
           "foodNutrients": []}
        ]}
        """)

        let hits = try await client.search("curry", kinds: [.srLegacy])
        XCTAssertEqual(hits.map(\.fdcID), [3])
    }

    /// The detail call puts the id in the PATH and carries no dataset filter.
    func testDetailAddressesTheFoodByID() async throws {
        let client = client(body: """
        {"fdcId": 2706437, "description": "Chicken curry", "dataType": "Survey (FNDDS)",
         "foodNutrients": [], "foodPortions": []}
        """)
        _ = try await client.food(id: 2706437)

        let url = try XCTUnwrap(FoodDataCentralProbe.lastURL)
        XCTAssertEqual(url.path, "/fdc/v1/food/2706437")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["api_key"])
    }

    /// A rejected key reads as a setup problem, not as a server having a bad
    /// day. The user can fix one of those.
    func testARejectedKeyReadsAsUnconfigured() async throws {
        let client = client(status: 403, body: "{}")
        await assertThrows(.notConfigured) { _ = try await client.search("egg") }
    }

    /// A spent allowance is its own case, so the retry ladder does not spend
    /// 400 ms proving that an hour has not passed.
    func testARateLimitIsNotRetried() async throws {
        let client = client(status: 429, body: "{}")
        await assertThrows(.rateLimited) { _ = try await client.search("egg") }
        XCTAssertEqual(
            FoodDataCentralProbe.requestCount, 1,
            "a 429 must not be retried; the allowance cannot refill in 400 ms"
        )
    }

    /// A 5xx IS retried, once, because a transient failure is the case the
    /// ladder exists for.
    func testAServerErrorIsRetriedOnce() async throws {
        let client = client(status: 500, body: "{}")
        await assertThrows(.unavailable) { _ = try await client.search("egg") }
        XCTAssertEqual(FoodDataCentralProbe.requestCount, 2)
    }

    /// An id that names nothing is nil, not a throw. A miss is an ordinary
    /// outcome and every caller would otherwise have to filter it.
    func testAMissingFoodIsNilRatherThanAnError() async throws {
        let client = client(status: 404, body: "{}")
        let food = try await client.food(id: 999_999_999)
        XCTAssertNil(food)
    }

    /// `withPortions` keeps the density when the portion call fails.
    ///
    /// Half an answer beats none: the caller can still price a portion the user
    /// stated themselves, it just cannot offer a standard one.
    func testWithPortionsKeepsTheSearchRowWhenTheDetailCallFails() async throws {
        FoodDataCentralProbe.reset()
        FoodDataCentralProbe.scriptedResponses = [
            (200, """
            {"foods": [{"fdcId": 2706437, "description": "Chicken curry",
              "dataType": "Survey (FNDDS)",
              "foodNutrients": [{"nutrientId": 1008, "unitName": "KCAL", "value": 107}]}]}
            """),
            (500, "{}"),
            (500, "{}")
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FoodDataCentralProbe.self]
        let client = FoodDataCentralClient(
            session: URLSession(configuration: config),
            apiKey: "test-key"
        )

        let hits = try await client.search("chicken curry")
        let hit = try XCTUnwrap(hits.first)
        let food = await client.withPortions(hit)

        XCTAssertEqual(food.fdcID, 2706437)
        XCTAssertEqual(food.nutrientsPer100.calories, 107, accuracy: 0.001)
        XCTAssertTrue(food.portions.isEmpty, "the portions were what failed")
    }

    private func assertThrows(
        _ expected: FoodDataCentralError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as FoodDataCentralError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// A URLProtocol that answers every request from a script, and remembers what
/// was asked. Modelled on `PlanSearchProbe`.
private final class FoodDataCentralProbe: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _body = "{}"
    nonisolated(unsafe) private static var _lastURL: URL?
    nonisolated(unsafe) private static var _count = 0
    nonisolated(unsafe) private static var _scripted: [(Int, String)] = []

    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    static var body: String {
        get { lock.lock(); defer { lock.unlock() }; return _body }
        set { lock.lock(); _body = newValue; lock.unlock() }
    }

    /// Answers served in order, for a test that needs the second call to differ
    /// from the first. Falls back to `status` / `body` once it runs out.
    static var scriptedResponses: [(Int, String)] {
        get { lock.lock(); defer { lock.unlock() }; return _scripted }
        set { lock.lock(); _scripted = newValue; lock.unlock() }
    }

    static var lastURL: URL? {
        lock.lock(); defer { lock.unlock() }; return _lastURL
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _count
    }

    static func reset() {
        lock.lock()
        _status = 200
        _body = "{}"
        _lastURL = nil
        _count = 0
        _scripted = []
        lock.unlock()
    }

    private static func next(_ url: URL?) -> (Int, String) {
        lock.lock(); defer { lock.unlock() }
        _lastURL = url
        defer { _count += 1 }
        if _count < _scripted.count { return _scripted[_count] }
        return (_status, _body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.next(request.url)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
