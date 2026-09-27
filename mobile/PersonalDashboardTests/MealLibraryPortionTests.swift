import XCTest
@testable import PersonalDashboard

/// The portion a whole meal is kept at when it is saved to the library (#673).
///
/// A library row scales by a ratio, so a wrong base portion is wrong on every
/// later log of it, silently. The rule is: the sum of the dishes when every one
/// is stated in the same measured unit, and nothing at all otherwise, so the
/// editor asks for a weight instead of guessing one.
final class MealLibraryPortionTests: XCTestCase {

    func testDishesInGramsSumToTheMealWeight() {
        let portion = FoodItemEditorSheet.measuredPortion(of: [
            MealItemEntry(name: "Rice", portionQuantity: 200, portionUnit: "g"),
            MealItemEntry(name: "Chicken", portionQuantity: 150, portionUnit: "g"),
        ])
        XCTAssertEqual(portion?.0, 350)
        XCTAssertEqual(portion?.1, .grams)
    }

    func testAnUnmeasuredDishLeavesThePortionForTheUser() {
        XCTAssertNil(FoodItemEditorSheet.measuredPortion(of: [
            MealItemEntry(name: "Rice", portionQuantity: 200, portionUnit: "g"),
            MealItemEntry(name: "Curry", portionQuantity: 1, portionUnit: "bowl"),
        ]))
    }

    func testGramsBesideMillilitresCannotBeAdded() {
        XCTAssertNil(FoodItemEditorSheet.measuredPortion(of: [
            MealItemEntry(name: "Toast", portionQuantity: 60, portionUnit: "g"),
            MealItemEntry(name: "Flat white", portionQuantity: 240, portionUnit: "ml"),
        ]))
    }

    func testAMealWithNoBreakdownHasNoPortion() {
        XCTAssertNil(FoodItemEditorSheet.measuredPortion(of: []))
    }

    func testAZeroPortionIsNotAMeasurement() {
        XCTAssertNil(FoodItemEditorSheet.measuredPortion(of: [
            MealItemEntry(name: "Rice", portionQuantity: 0, portionUnit: "g"),
        ]))
    }
}
