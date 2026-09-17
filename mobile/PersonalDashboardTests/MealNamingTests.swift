import XCTest
import SwiftData
@testable import PersonalDashboard

/// Naming meals that are already stored (#603).
///
/// Everything here is about a wrong name rather than a missing one. A row that
/// is not named keeps its own shortened words, which is visibly a stub; a row
/// named from another row's description reads as a fact and is never
/// questioned. So the reply is matched by id, and four classes of answer are
/// thrown away rather than stored.
@MainActor
final class MealNamingTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: MealNamingService!
    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = MealNamingService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Reading the reply

    private func entry(_ id: String, _ title: String) -> AnthropicJSONValue {
        .object(["id": .string(id), "title": .string(title)])
    }

    private let asked = [
        MealNamingRequest(id: "a", text: "two eggs on toast with butter and a flat white, made at home"),
        MealNamingRequest(id: "b", text: "leftover chicken biryani with raita and two papadums from last night")
    ]

    func testANameIsMatchedByIdAndNotByPosition() {
        let names = AnthropicClient.names(
            from: [entry("b", "Chicken biryani with raita"), entry("a", "Eggs on toast and a flat white")],
            asked: asked
        )
        XCTAssertEqual(names["a"], "Eggs on toast and a flat white")
        XCTAssertEqual(names["b"], "Chicken biryani with raita")
    }

    func testAnIdNobodyAskedAboutIsDropped() {
        let names = AnthropicClient.names(from: [entry("zzz", "Chicken rice")], asked: asked)
        XCTAssertTrue(names.isEmpty)
    }

    func testAnEmptyNameIsDropped() {
        let names = AnthropicClient.names(from: [entry("a", "   ")], asked: asked)
        XCTAssertTrue(names.isEmpty)
    }

    /// A name identical to the text stores the sentence in the field that
    /// exists to avoid one.
    func testANameThatCopiesTheDescriptionIsDropped() {
        let names = AnthropicClient.names(from: [entry("a", asked[0].text)], asked: asked)
        XCTAssertTrue(names.isEmpty)
    }

    /// A name over the display cap would be truncated on every surface it
    /// reaches, which is the state this whole field exists to leave.
    func testANameLongerThanTheCapIsDropped() {
        let long = String(repeating: "Very long dish ", count: 6)
        XCTAssertGreaterThan(long.count, MealDisplayName.characterCap)
        let names = AnthropicClient.names(from: [entry("a", long)], asked: asked)
        XCTAssertTrue(names.isEmpty)
    }

    func testATrailingFullStopIsTrimmedRatherThanRejected() {
        let names = AnthropicClient.names(from: [entry("a", "Eggs on toast.")], asked: asked)
        XCTAssertEqual(names["a"], "Eggs on toast")
    }

    func testAPartialAnswerNamesWhatItAnswered() {
        let names = AnthropicClient.names(from: [entry("a", "Eggs on toast")], asked: asked)
        XCTAssertEqual(names.count, 1)
        XCTAssertNil(names["b"])
    }

    // MARK: - The prompt

    /// A description carrying a quote or a newline must not break the JSON
    /// block the model reads.
    func testTheDescriptionIsEscapedIntoThePrompt() {
        let prompt = AnthropicClient.mealNamingPrompt([
            MealNamingRequest(id: "a", text: "a \"large\" coffee\nand a bun")
        ])
        XCTAssertTrue(prompt.contains("\\\"large\\\""), prompt)
        XCTAssertFalse(prompt.contains("coffee\nand"), "the newline survived into the JSON block")
    }

    /// The rule is the shared one, never a second statement of it.
    func testThePromptCarriesTheSharedNamingRule() {
        let prompt = AnthropicClient.mealNamingPrompt(asked)
        XCTAssertTrue(prompt.contains(MealToolSchema.titleRule))
    }

    // MARK: - What the pass asks about

    private func meal(_ description: String, title: String? = nil, at offset: TimeInterval = 0) {
        let row = LocalMeal(
            date: day, loggedAt: day.addingTimeInterval(offset),
            mealType: MealType.lunch.rawValue,
            mealDescription: description,
            title: title,
            confidence: 0.6, source: MealSource.composer
        )
        store.context.insert(row)
    }

    private func planEntry(_ title: String, shortTitle: String? = nil) {
        let row = LocalMealPlanEntry(
            date: day, mealType: MealType.dinner.rawValue,
            title: title, shortTitle: shortTitle
        )
        store.context.insert(row)
    }

    private let longText = "leftover chicken biryani with raita and two papadums from last night"

    func testAMealThatAlreadyHasANameIsNotAskedAbout() {
        meal(longText, title: "Chicken biryani")
        XCTAssertTrue(service.unnamedMeals().isEmpty)
    }

    /// A description short enough to print is printed, so naming it would spend
    /// a call to say the same thing.
    func testAShortDescriptionIsNotAskedAbout() {
        meal("Chicken rice")
        XCTAssertTrue(service.unnamedMeals().isEmpty)
    }

    func testALongUnnamedDescriptionIsAskedAbout() {
        meal(longText)
        XCTAssertEqual(service.unnamedMeals().count, 1)
    }

    /// Newest first: the day on screen is the one being read.
    func testTheNewestMealsAreAskedAboutFirst() {
        meal(longText + " one", at: 0)
        meal(longText + " two", at: 3_600)
        let asked = service.unnamedMeals()
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(asked[0].mealDescription.hasSuffix("two"))
    }

    func testOnePassAsksAboutNoMoreThanTheBatchLimit() {
        for i in 0..<(MealNamingService.batchLimit + 15) {
            meal("\(longText) number \(i)", at: TimeInterval(i))
        }
        XCTAssertEqual(service.unnamedMeals().count, MealNamingService.batchLimit)
    }

    func testAPlannedBlockIsAskedAboutOnTheSameTerms() {
        planEntry(longText)
        planEntry("Chicken rice")
        planEntry(longText + " again", shortTitle: "Biryani")
        XCTAssertEqual(service.unnamedEntries().count, 1)
    }

    // MARK: - What the name is used for

    func testAStoredPlanNameIsWhatATileDraws() {
        let row = LocalMealPlanEntry(
            date: day, mealType: MealType.dinner.rawValue,
            title: longText, shortTitle: "Chicken biryani"
        )
        XCTAssertEqual(MealDisplayName.short(for: row), "Chicken biryani")
    }

    func testAPlanBlockWithNoNameFallsBackToItsOwnWords() {
        let row = LocalMealPlanEntry(
            date: day, mealType: MealType.dinner.rawValue, title: longText
        )
        let drawn = MealDisplayName.short(for: row)
        XCTAssertTrue(drawn.hasSuffix("…"))
        XCTAssertTrue(longText.hasPrefix(String(drawn.dropLast())))
    }
}
