import XCTest
@testable import PersonalDashboard

/// What a list is allowed to print for a meal (#603).
///
/// Every case here is one a screen can be wrong about silently. A name that
/// overruns pushes the calorie figure onto its own line; a name cut mid-word
/// reads as a rendering bug; a meal that resolves to an empty string leaves a
/// row with nothing to aim at. None of those throw, and none of them look like
/// a failure in a build log.
final class MealDisplayNameTests: XCTestCase {

    // MARK: - The stored title wins

    func testAStoredTitleIsUsedVerbatimWhenItFits() {
        let name = MealDisplayName.short(
            title: "Eggs on toast and a flat white",
            items: [MealItemEntry(name: "Poached egg")],
            text: "two eggs on toast with butter and a flat white, made at home"
        )
        XCTAssertEqual(name, "Eggs on toast and a flat white")
    }

    func testAnOverlongTitleIsStillShortened() {
        let name = MealDisplayName.short(
            title: "Hainanese chicken rice with cucumber, chilli sauce and a bowl of soup",
            items: [],
            text: "lunch"
        )
        XCTAssertLessThanOrEqual(name.count, MealDisplayName.characterCap + 1)
        XCTAssertTrue(name.hasSuffix("…"), "a shortened name says it was shortened: \(name)")
    }

    func testABlankTitleFallsThroughRatherThanPrintingNothing() {
        let name = MealDisplayName.short(
            title: "   ",
            items: [],
            text: "Chicken rice"
        )
        XCTAssertEqual(name, "Chicken rice")
    }

    // MARK: - A short description is already a name

    func testAShortDescriptionIsLeftExactlyAsTyped() {
        let name = MealDisplayName.short(title: nil, items: [], text: "Chicken rice")
        XCTAssertEqual(name, "Chicken rice")
    }

    // MARK: - The item fallback

    func testItemNamesNameAMealLoggedBeforeTitlesExisted() {
        let name = MealDisplayName.short(
            title: nil,
            items: [
                MealItemEntry(name: "Poached egg"),
                MealItemEntry(name: "Flat white")
            ],
            text: "two eggs on toast with butter and a flat white, made at home"
        )
        XCTAssertEqual(name, "Poached egg, flat white")
    }

    func testABrandKeepsItsCapitals() {
        let name = MealDisplayName.short(
            title: nil,
            items: [
                MealItemEntry(name: "Chips"),
                MealItemEntry(name: "Big Mac")
            ],
            text: "a Big Mac and a large fries from the place by the station"
        )
        XCTAssertEqual(name, "Chips, Big Mac")
    }

    func testTheItemsThatDoNotFitBecomeACount() {
        let name = MealDisplayName.short(
            title: nil,
            items: [
                MealItemEntry(name: "Hainanese chicken rice"),
                MealItemEntry(name: "Cucumber salad"),
                MealItemEntry(name: "Barley water"),
                MealItemEntry(name: "Soup")
            ],
            text: "chicken rice with cucumber, a barley water and the soup that came with it"
        )
        XCTAssertLessThanOrEqual(name.count, MealDisplayName.characterCap + 1)
        XCTAssertTrue(name.contains("+"), "the dishes that did not fit are counted: \(name)")
    }

    // MARK: - The floor

    func testAnUnnamedMealIsTruncatedAtAWordAndNeverMidWord() {
        let text = "something from the canteen that I could not identify at all really"
        let name = MealDisplayName.short(title: nil, items: [], text: text)
        XCTAssertTrue(name.hasSuffix("…"))

        let body = String(name.dropLast())
        XCTAssertTrue(
            text.hasPrefix(body),
            "the name is a prefix of the description: \(name)"
        )
        // The character after the cut is a space, which is what makes the cut a
        // word boundary rather than a slice through one.
        let next = text[text.index(text.startIndex, offsetBy: body.count)]
        XCTAssertEqual(next, " ", "cut mid-word: \(name)")
    }

    func testAMealWithNothingAtAllStillDrawsSomething() {
        let name = MealDisplayName.short(title: nil, items: [], text: "   ")
        XCTAssertFalse(name.isEmpty)
    }

    func testAWordLongerThanTheCapIsCutRatherThanDropped() {
        let text = String(repeating: "a", count: 80)
        let name = MealDisplayName.short(title: nil, items: [], text: text)
        XCTAssertLessThanOrEqual(name.count, MealDisplayName.characterCap + 1)
        XCTAssertTrue(name.hasSuffix("…"))
    }
}
