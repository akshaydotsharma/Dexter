import XCTest
@testable import DexterMac

/// Pure mapping tests for the Open Food Facts importer (#625).
///
/// ### Why these are worth having
///
/// The client itself is plumbing: if the URL is wrong or the JSON will not
/// decode, nothing appears and you find out immediately. The MAPPING is the
/// opposite. It fails by producing a plausible number, and a plausible number
/// goes into the library, gets logged, and is summed into a week of totals
/// without anything in the app ever objecting. `MealEstimateGuards` cannot
/// help: it grades an ESTIMATE, and an imported figure never goes near it.
///
/// Sodium is the sharpest case and has its own test. Open Food Facts states it
/// in GRAMS, `LocalFoodItem.sodiumMg` holds MILLIGRAMS, and the whole defence
/// against a thousandfold error is one multiplication that no downstream guard
/// would question.
///
/// Every test here runs off a JSON string in this file. No network, no store,
/// no container, so the suite says the same thing on any machine at any hour.
/// The one test that does hit the network lives in the class at the bottom and
/// skips unless an environment variable asks for it.
final class OpenFoodFactsMappingTests: XCTestCase {

    // MARK: - Fixtures

    /// The Superyou protein wafer, `8908024977013`, in the shape the search
    /// endpoint returns it with the nine requested fields.
    ///
    /// A real record rather than an invented one, so the numbers this file
    /// asserts on are numbers the live database actually serves. It is also a
    /// useful record because it carries BOTH sodium and salt, and BOTH kcal and
    /// kJ, which lets the preference order be tested rather than assumed.
    private let superyouSearchJSON = """
    {
      "count": 1,
      "page_size": 20,
      "products": [
        {
          "code": "8908024977013",
          "product_name": "Protein Wafer Chocolate",
          "brands": "superyou",
          "quantity": "40 g",
          "serving_size": "40 g",
          "serving_quantity": 40,
          "nutrition_data_per": "100g",
          "image_front_small_url": "https://images.openfoodfacts.org/images/products/890/802/497/7013/front_en.4.200.jpg",
          "nutriments": {
            "energy-kcal_100g": 466,
            "energy-kj_100g": 1950,
            "proteins_100g": 25,
            "carbohydrates_100g": 50,
            "fat_100g": 25.9,
            "fiber_100g": 7.6,
            "sugars_100g": 8.85,
            "sodium_100g": 0.4425,
            "salt_100g": 1.10625,
            "saturated-fat_100g": 21.25,
            "energy-kcal_serving": 186.4,
            "proteins_serving": 10
          }
        }
      ]
    }
    """

    private func products(_ json: String) throws -> [OpenFoodFactsProduct] {
        let decoded = try JSONDecoder().decode(
            OpenFoodFactsSearchResponse.self,
            from: Data(json.utf8)
        )
        return decoded.products
    }

    private func firstDraft(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> FoodItemDraft {
        let hits = try products(json)
        let first = try XCTUnwrap(hits.first, "the fixture must decode to at least one product", file: file, line: line)
        return first.draft
    }

    // MARK: - The whole record

    func testTheRealSuperyouRecordMapsOntoTheEightNutrients() throws {
        let draft = try firstDraft(superyouSearchJSON)

        XCTAssertEqual(draft.name, "Protein Wafer Chocolate")
        XCTAssertEqual(draft.brand, "Superyou", "an all-lowercase brand is title-cased")
        XCTAssertEqual(draft.basePortionQuantity, 100, "the _100g keys are per 100 by definition")
        XCTAssertEqual(draft.basePortionUnit, .grams)

        XCTAssertEqual(draft.calories, 466, accuracy: 0.001)
        XCTAssertEqual(draft.proteinG, 25, accuracy: 0.001)
        XCTAssertEqual(draft.carbsG, 50, accuracy: 0.001)
        XCTAssertEqual(draft.fatG, 25.9, accuracy: 0.001)
        XCTAssertEqual(draft.fibreG, 7.6, accuracy: 0.001)
        XCTAssertEqual(draft.sugarG, 8.85, accuracy: 0.001)
        XCTAssertEqual(draft.satFatG, 21.25, accuracy: 0.001)

        XCTAssertEqual(draft.defaultPortionQuantity, 40, accuracy: 0.001)
        XCTAssertEqual(draft.barcode, "8908024977013")
        XCTAssertEqual(draft.externalID, "8908024977013")
        XCTAssertEqual(draft.externalSource, FoodItemSource.openFoodFacts)
        XCTAssertEqual(
            draft.imageURL?.absoluteString,
            "https://images.openfoodfacts.org/images/products/890/802/497/7013/front_en.4.200.jpg"
        )
        XCTAssertTrue(draft.missingNutrients.isEmpty, "this record carries all eight")
    }

    // MARK: - Rule 1: sodium

    /// The thousandfold error, pinned.
    ///
    /// `sodium_100g` is 0.4425 GRAMS. The row must hold 442.5 MILLIGRAMS. A
    /// missing conversion gives 0.4425 and a doubled one gives 442,500, and
    /// both would sail through every other check in the app.
    func testSodiumGramsBecomeMilligrams() throws {
        let draft = try firstDraft(superyouSearchJSON)
        XCTAssertEqual(draft.sodiumMg, 442.5, accuracy: 0.0001)
    }

    /// A record with salt and no sodium, which is the normal shape for an EU
    /// panel. Salt / 2.5 is the standard labelling factor, then grams to
    /// milligrams. 1.10625 g of salt is the same 442.5 mg of sodium.
    func testSaltIsConvertedToSodiumWhenSodiumIsAbsent() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1111111111111",
          "product_name":"Salt Only Biscuit",
          "brands":"Testo",
          "serving_size":"25 g",
          "nutrition_data_per":"100g",
          "nutriments":{
            "energy-kcal_100g":400,"proteins_100g":6,"carbohydrates_100g":60,
            "fat_100g":15,"fiber_100g":2,"sugars_100g":20,
            "saturated-fat_100g":7,"salt_100g":1.10625
          }
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.sodiumMg, 442.5, accuracy: 0.0001)
        XCTAssertFalse(
            draft.missingNutrients.contains(.sodium),
            "a derived sodium is present, not missing"
        )
    }

    /// Neither sodium nor salt. Zero, and flagged, so the confirm form can say
    /// the record did not state it instead of printing a confident 0 mg.
    func testSodiumIsZeroAndMissingWhenNeitherSodiumNorSaltIsStated() throws {
        let json = """
        {"count":1,"products":[{
          "code":"2222222222222","product_name":"No Sodium Listed","brands":"Testo",
          "nutriments":{"energy-kcal_100g":100,"proteins_100g":1,"carbohydrates_100g":1,
          "fat_100g":1,"fiber_100g":1,"sugars_100g":1,"saturated-fat_100g":1}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.sodiumMg, 0)
        XCTAssertEqual(draft.missingNutrients, [.sodium])
    }

    // MARK: - Rule 2: calories

    func testKilojoulesAreConvertedWhenKilocaloriesAreAbsent() throws {
        let json = """
        {"count":1,"products":[{
          "code":"3333333333333","product_name":"EU Panel Bar","brands":"Testo",
          "nutriments":{"energy-kj_100g":1950,"proteins_100g":25,"carbohydrates_100g":50,
          "fat_100g":25.9,"fiber_100g":7.6,"sugars_100g":8.85,"sodium_100g":0.4425,
          "saturated-fat_100g":21.25}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.calories, 1950 / 4.184, accuracy: 0.001)
        XCTAssertFalse(draft.missingNutrients.contains(.calories))
    }

    func testKilocaloriesWinOverKilojoulesWhenBothArePresent() throws {
        let draft = try firstDraft(superyouSearchJSON)
        // 1950 kJ would be 466.06 kcal. The stated 466 is what must be used,
        // because a record's own kcal figure is the one the packet prints.
        XCTAssertEqual(draft.calories, 466, accuracy: 0.0001)
        XCTAssertNotEqual(draft.calories, 1950 / 4.184, accuracy: 0.0001)
    }

    func testCaloriesAreZeroAndMissingWithNoEnergyFieldAtAll() throws {
        let json = """
        {"count":1,"products":[{
          "code":"4444444444444","product_name":"No Energy","brands":"Testo",
          "nutriments":{"proteins_100g":3}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.calories, 0)
        XCTAssertTrue(draft.missingNutrients.contains(.calories))
    }

    // MARK: - Rule 3: the base portion and its unit

    func testADrinkIsInferredAsMillilitresFromNutritionDataPer() throws {
        let json = """
        {"count":1,"products":[{
          "code":"5555555555555","product_name":"Iced Latte","brands":"Testo",
          "quantity":"330 ml","nutrition_data_per":"100ml",
          "nutriments":{"energy-kcal_100g":42,"proteins_100g":2,"carbohydrates_100g":5,
          "fat_100g":1,"fiber_100g":0,"sugars_100g":5,"sodium_100g":0.05,
          "saturated-fat_100g":0.6}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.basePortionUnit, .millilitres)
        XCTAssertEqual(draft.basePortionQuantity, 100)
    }

    /// No `nutrition_data_per` at all, so the pack size has to answer.
    func testMillilitresAreInferredFromThePackSizeWhenNutritionDataPerIsSilent() throws {
        let json = """
        {"count":1,"products":[{
          "code":"6666666666666","product_name":"Sparkling Water","brands":"Testo",
          "quantity":"1.5 L",
          "nutriments":{"energy-kcal_100g":0,"proteins_100g":0,"carbohydrates_100g":0,
          "fat_100g":0,"fiber_100g":0,"sugars_100g":0,"sodium_100g":0.01,
          "saturated-fat_100g":0}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.basePortionUnit, .millilitres)
    }

    func testASolidStaysInGrams() throws {
        let draft = try firstDraft(superyouSearchJSON)
        XCTAssertEqual(draft.basePortionUnit, .grams)
    }

    /// The unit reader on its own, including the shapes that must NOT read as
    /// a volume.
    func testVolumeSuffixDetection() {
        XCTAssertTrue(OpenFoodFactsProduct.endsInVolumeUnit("330ml"))
        XCTAssertTrue(OpenFoodFactsProduct.endsInVolumeUnit("330 ml"))
        XCTAssertTrue(OpenFoodFactsProduct.endsInVolumeUnit("1.5 L"))
        XCTAssertTrue(OpenFoodFactsProduct.endsInVolumeUnit("6 x 200ml"))
        XCTAssertFalse(OpenFoodFactsProduct.endsInVolumeUnit("150 g"))
        XCTAssertFalse(OpenFoodFactsProduct.endsInVolumeUnit("40g"))
        XCTAssertFalse(OpenFoodFactsProduct.endsInVolumeUnit(""))
        XCTAssertFalse(
            OpenFoodFactsProduct.endsInVolumeUnit("olive oil"),
            "a word with no digits in it is not a measurement"
        )
    }

    // MARK: - Rule 4: the default portion

    func testServingSizeParsesABareNumberAndUnit() {
        XCTAssertEqual(OpenFoodFactsProduct.portion(fromServingSize: "40 g"), 40)
        XCTAssertEqual(OpenFoodFactsProduct.portion(fromServingSize: "40g"), 40)
    }

    /// The shape that breaks a naive "first number in the string" rule: the
    /// answer is 160, not the 1 that leads the line.
    func testServingSizeParsesTheNumberThatCarriesTheUnit() {
        XCTAssertEqual(OpenFoodFactsProduct.portion(fromServingSize: "1 serving size (160 g)"), 160)
    }

    func testServingSizeFoldsLargerUnitsDownToTheBase() throws {
        let kg = try XCTUnwrap(OpenFoodFactsProduct.portion(fromServingSize: "0.2 kg"))
        XCTAssertEqual(kg, 200, accuracy: 0.0001)
        let litre = try XCTUnwrap(OpenFoodFactsProduct.portion(fromServingSize: "0.33 l"))
        XCTAssertEqual(litre, 330, accuracy: 0.0001)
    }

    func testServingSizeFallsBackToABareNumber() {
        XCTAssertEqual(OpenFoodFactsProduct.portion(fromServingSize: "150"), 150)
        XCTAssertNil(OpenFoodFactsProduct.portion(fromServingSize: "one biscuit"))
        XCTAssertNil(OpenFoodFactsProduct.portion(fromServingSize: ""))
    }

    func testServingQuantityWinsOverTheParsedServingSize() throws {
        let json = """
        {"count":1,"products":[{
          "code":"7777777777777","product_name":"Pot","brands":"Testo",
          "serving_size":"1 pot (170 g)","serving_quantity":150,
          "nutriments":{"energy-kcal_100g":60}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.defaultPortionQuantity, 150, accuracy: 0.0001)
    }

    func testAZeroServingQuantityFallsThroughToTheServingSize() throws {
        let json = """
        {"count":1,"products":[{
          "code":"8888888888888","product_name":"Pot","brands":"Testo",
          "serving_size":"1 pot (170 g)","serving_quantity":0,
          "nutriments":{"energy-kcal_100g":60}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.defaultPortionQuantity, 170, accuracy: 0.0001)
    }

    func testTheDefaultPortionFallsBackToOneHundred() throws {
        let json = """
        {"count":1,"products":[{
          "code":"9999999999999","product_name":"Nothing Stated","brands":"Testo",
          "nutriments":{"energy-kcal_100g":60}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.defaultPortionQuantity, 100, accuracy: 0.0001)
    }

    // MARK: - Rule 5: leniency and missing values

    /// The same record with every number written as a STRING, which is how a
    /// real slice of the database stores them. It must map identically.
    func testNumericStringsDecodeExactlyLikeNumbers() throws {
        let stringly = """
        {
          "count": "1",
          "products": [
            {
              "code": "8908024977013",
              "product_name": "Protein Wafer Chocolate",
              "brands": "superyou",
              "quantity": "40 g",
              "serving_size": "40 g",
              "serving_quantity": "40",
              "nutrition_data_per": "100g",
              "image_front_small_url": "https://images.openfoodfacts.org/images/products/890/802/497/7013/front_en.4.200.jpg",
              "nutriments": {
                "energy-kcal_100g": "466",
                "energy-kj_100g": "1950",
                "proteins_100g": "25",
                "carbohydrates_100g": "50",
                "fat_100g": "25.9",
                "fiber_100g": "7.6",
                "sugars_100g": "8.85",
                "sodium_100g": "0.4425",
                "salt_100g": "1.10625",
                "saturated-fat_100g": "21.25"
              }
            }
          ]
        }
        """
        let fromStrings = try firstDraft(stringly)
        let fromNumbers = try firstDraft(superyouSearchJSON)
        XCTAssertEqual(fromStrings, fromNumbers, "a stringly record must map to the same draft")
    }

    /// A European decimal comma, which the same records use.
    func testACommaDecimalIsReadAsADecimalPoint() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1010101010101","product_name":"Comma Decimals","brands":"Testo",
          "serving_quantity":"40,5",
          "nutriments":{"energy-kcal_100g":"466","fat_100g":"25,9"}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.fatG, 25.9, accuracy: 0.0001)
        XCTAssertEqual(draft.defaultPortionQuantity, 40.5, accuracy: 0.0001)
    }

    /// Absent, negative and non-numeric all mean the same thing: zero on the
    /// row and a flag on the draft.
    func testAbsentAndNegativeNutrientsAreZeroedAndListed() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1212121212121","product_name":"Half A Panel","brands":"Testo",
          "nutriments":{
            "energy-kcal_100g":250,
            "proteins_100g":-4,
            "carbohydrates_100g":30,
            "fat_100g":"not a number",
            "sugars_100g":12,
            "sodium_100g":0.2
          }
        }]}
        """
        let draft = try firstDraft(json)

        XCTAssertEqual(draft.calories, 250, accuracy: 0.0001)
        XCTAssertEqual(draft.carbsG, 30, accuracy: 0.0001)
        XCTAssertEqual(draft.sugarG, 12, accuracy: 0.0001)
        XCTAssertEqual(draft.sodiumMg, 200, accuracy: 0.0001)

        XCTAssertEqual(draft.proteinG, 0, "a negative is a typo, not a measurement")
        XCTAssertEqual(draft.fatG, 0)
        XCTAssertEqual(draft.fibreG, 0)
        XCTAssertEqual(draft.satFatG, 0)

        // Ordered by the canonical nutrient order, not by the order the reads
        // happened, so this comparison is stable.
        XCTAssertEqual(draft.missingNutrients, [.protein, .fat, .fibre, .saturatedFat])
    }

    /// The British spelling, which a minority of records use for the same
    /// field.
    func testTheBritishFibreSpellingIsAccepted() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1313131313131","product_name":"Fibre Spelt British","brands":"Testo",
          "nutriments":{"energy-kcal_100g":100,"fibre_100g":4.2}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.fibreG, 4.2, accuracy: 0.0001)
        XCTAssertFalse(draft.missingNutrients.contains(.fibre))
    }

    // MARK: - Rule 6: name and brand

    func testOnlyTheFirstBrandIsTaken() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1414141414141","product_name":"Greek Style High Protein Yogurt",
          "brands":"Farmers Union,Farmers Union Australia,Lactalis",
          "nutriments":{"energy-kcal_100g":97}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.brand, "Farmers Union")
    }

    /// An all-lowercase brand is a typing shortcut and is title-cased. A brand
    /// with any capital in it is left exactly as written, because "LU" and
    /// "Ben & Jerry's" are spellings, not mistakes.
    func testBrandCasingIsOnlyFixedWhenItIsEntirelyLowercase() throws {
        XCTAssertEqual(OpenFoodFactsProduct.primaryBrand("superyou"), "Superyou")
        XCTAssertEqual(OpenFoodFactsProduct.primaryBrand("farmers union"), "Farmers Union")
        XCTAssertEqual(OpenFoodFactsProduct.primaryBrand("LU"), "LU")
        XCTAssertEqual(OpenFoodFactsProduct.primaryBrand("Ben & Jerry's"), "Ben & Jerry's")
        XCTAssertNil(OpenFoodFactsProduct.primaryBrand(""))
        XCTAssertNil(OpenFoodFactsProduct.primaryBrand("   "))
    }

    func testAnEmptyProductNameFallsBackToTheBrand() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1515151515151","product_name":"","brands":"kinder",
          "quantity":"100 g","nutriments":{"energy-kcal_100g":500}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.name, "Kinder")
    }

    /// No name and no brand. The name stays empty on purpose, so the confirm
    /// form has something obviously blank to demand rather than a row called
    /// "Unknown product".
    func testANamelessBrandlessRecordKeepsAnEmptyName() throws {
        let json = """
        {"count":1,"products":[{
          "code":"1616161616161","product_name":"","brands":"",
          "nutriments":{"energy-kcal_100g":500}
        }]}
        """
        let draft = try firstDraft(json)
        XCTAssertEqual(draft.name, "")
        XCTAssertNil(draft.brand)
        XCTAssertEqual(draft.barcode, "1616161616161", "the code is still the way back to this record")
    }

    // MARK: - Decoding resilience

    /// One unreadable field must not lose the product. A strict decoder would
    /// throw on the whole record and the hit would simply not appear, which
    /// looks exactly like the product not being in the database.
    func testAProductWithMissingFieldsStillDecodes() throws {
        let json = """
        {"count":1,"products":[{"code":"1717171717171"}]}
        """
        let hits = try products(json)
        XCTAssertEqual(hits.count, 1)
        let draft = try XCTUnwrap(hits.first).draft
        XCTAssertEqual(draft.missingNutrients.count, 8, "an empty record is missing all eight")
        XCTAssertEqual(draft.basePortionQuantity, 100)
        XCTAssertEqual(draft.defaultPortionQuantity, 100)
    }

    /// The barcode endpoint's not-found shape. `status: 0` is the only thing
    /// that says so; the HTTP layer answers 200.
    func testAStatusZeroProductResponseCarriesNoProduct() throws {
        let json = """
        {"status":0,"status_verbose":"product not found","code":"0000000000000"}
        """
        let decoded = try JSONDecoder().decode(
            OpenFoodFactsProductResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.status, 0)
        XCTAssertNil(decoded.product)
    }

    func testAStatusOneProductResponseCarriesTheProduct() throws {
        let json = """
        {"status":1,"code":"8908024977013","product":{
          "code":"8908024977013","product_name":"Protein Wafer Chocolate","brands":"superyou",
          "serving_size":"40 g","nutrition_data_per":"100g",
          "nutriments":{"energy-kcal_100g":466,"sodium_100g":0.4425}
        }}
        """
        let decoded = try JSONDecoder().decode(
            OpenFoodFactsProductResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.status, 1)
        let draft = try XCTUnwrap(decoded.product).draft
        XCTAssertEqual(draft.calories, 466, accuracy: 0.0001)
        XCTAssertEqual(draft.sodiumMg, 442.5, accuracy: 0.0001)
    }

    // MARK: - The request itself

    /// Their usage policy names the default agent as grounds for a block, so
    /// this app must never send it.
    func testTheUserAgentNamesTheAppAndAContact() {
        let agent = OpenFoodFactsClient.userAgent
        XCTAssertTrue(agent.hasPrefix("Dexter/"), "the agent must name the app first")
        XCTAssertTrue(agent.contains("github.com/akshaydotsharma/Dexter"), "it must carry a contact")
        XCTAssertFalse(agent.contains("CFNetwork"), "never the stock URLSession agent")
    }

    /// The session timeout caps the request timeout, so the two must agree.
    /// A session shorter than the request is a silent clamp, which is exactly
    /// how #594's Anthropic timeouts hid.
    func testTheSessionTimeoutMatchesTheRequestTimeout() {
        XCTAssertEqual(
            OpenFoodFactsClient.defaultSession.configuration.timeoutIntervalForRequest,
            OpenFoodFactsClient.timeout,
            accuracy: 0.001
        )
    }

    /// An empty query must not reach the network at all.
    func testAnEmptySearchReturnsNothingWithoutCallingOut() async throws {
        let client = OpenFoodFactsClient(session: Self.refusingSession())
        let hits = try await client.search("   ")
        XCTAssertTrue(hits.isEmpty)
    }

    /// A session whose configuration makes any real request fail immediately,
    /// so a test that accidentally hits the network fails rather than passing
    /// slowly.
    private static func refusingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.001
        config.allowsCellularAccess = false
        return URLSession(configuration: config)
    }
}

// MARK: - Live

/// The one test here that spends a real network call (#625).
///
/// Skipped unless `DEXTER_LIVE_OPEN_FOOD_FACTS=1`, and the variable needs the
/// `TEST_RUNNER_` prefix to reach the test process:
///
///     TEST_RUNNER_DEXTER_LIVE_OPEN_FOOD_FACTS=1 \
///       xcodebuild test -project PersonalDashboard.xcodeproj -scheme DexterMac \
///       -destination 'platform=macOS' \
///       -only-testing:DexterMacTests/OpenFoodFactsLiveTests
///
/// ### Why the gate, and why it is worth being careful about
///
/// A live test in the default suite makes the suite fail on a plane and makes
/// it depend on a third party's uptime. So it is off by default, following
/// `LiveMealBrandGroundingTests`.
///
/// But a skipped test reports `TEST SUCCEEDED`, which reads exactly like a pass
/// and has already cost this repo real time (see project memory
/// `anthropic_server_tool_traps`). A plain `export` without the `TEST_RUNNER_`
/// prefix is silently ignored and every test here skips while the banner says
/// everything is fine. Always read the EXECUTED COUNT, never the banner.
final class OpenFoodFactsLiveTests: XCTestCase {

    private func liveClient() throws -> OpenFoodFactsClient {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DEXTER_LIVE_OPEN_FOOD_FACTS"] == "1",
            "set TEST_RUNNER_DEXTER_LIVE_OPEN_FOOD_FACTS=1 to hit the real database"
        )
        return OpenFoodFactsClient()
    }

    /// The barcode this file's fixture was taken from. If the shape of the live
    /// answer ever drifts from the fixture, this is what catches it.
    func testTheRealBarcodeStillReturnsTheWaferWithSodiumInGrams() async throws {
        let client = try liveClient()
        let product = try await client.product(barcode: "8908024977013")
        let hit = try XCTUnwrap(product, "8908024977013 must still be in the database")

        XCTAssertEqual(hit.code, "8908024977013")
        let sodiumG = try XCTUnwrap(
            OpenFoodFactsProduct.reading(hit.nutriments, "sodium_100g"),
            "the live record must still state sodium"
        )
        XCTAssertLessThan(
            sodiumG, 10,
            "sodium must still arrive in GRAMS. A value in the hundreds means the wire changed unit and the ×1000 is now a thousandfold error"
        )
        XCTAssertEqual(hit.draft.sodiumMg, sodiumG * 1_000, accuracy: 0.0001)
    }

    func testAnUnknownBarcodeIsNilAndNotAnError() async throws {
        let client = try liveClient()
        let product = try await client.product(barcode: "0000000000000")
        XCTAssertNil(product, "not found is nil, never a thrown error")
    }

    /// Free-text search against the real endpoint.
    ///
    /// ### Why a 503 SKIPS this test rather than failing it
    ///
    /// `cgi/search.pl` is their legacy, expensive endpoint and it sheds load
    /// openly: on 2026-09-18 six identical plain requests returned 200, 200,
    /// 200, 503, 503, 200, and the same flap reproduces from `curl`. The client
    /// retries once, which is what makes the feature usable, but no number of
    /// retries makes a third party's uptime into something this repo can
    /// assert.
    ///
    /// Failing here would teach whoever runs the suite that a red result means
    /// nothing, which is worse than no test. Skipping says what is actually
    /// true: the contract could not be checked this minute. What IS asserted is
    /// the contract itself, whenever the service does answer.
    func testAFreeTextSearchReturnsUsableHits() async throws {
        let client = try liveClient()
        let hits: [OpenFoodFactsProduct]
        do {
            hits = try await client.search("greek yogurt")
        } catch OpenFoodFactsError.unavailable {
            throw XCTSkip("cgi/search.pl is shedding load right now (503 twice). Not a code failure.")
        }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThanOrEqual(hits.count, OpenFoodFactsClient.pageSize)
        // The fields parameter must actually be honoured, or every search
        // downloads a hundred kilobytes per hit.
        let named = hits.filter { !$0.productName.isEmpty }
        XCTAssertFalse(named.isEmpty, "a search must return at least one named product")
    }
}
