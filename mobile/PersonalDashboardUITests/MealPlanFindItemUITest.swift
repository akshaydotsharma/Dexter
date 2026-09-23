import XCTest

/// The plan sheet offers the saved list as an alternative to Estimate, laid
/// out the way the Tracking composer lays it out (#659).
final class MealPlanFindItemUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_plan_sheet_offers_find_an_item_under_estimate() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launchEnvironment["LAUNCH_MEALS_TAB"] = "plan"
        app.launch()

        let add = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'No ' AND label ENDSWITH 'Add one'")
        ).firstMatch
        let addSmall = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        let target = add.waitForExistence(timeout: 15) ? add : addSmall
        XCTAssertTrue(target.waitForExistence(timeout: 5), "an add control is on the plan")
        target.tap()

        let estimate = app.buttons["Estimate"].firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 10), "the plan sheet is up")

        let find = app.buttons["Find an item to add"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Find an item sits under Estimate")
        XCTAssertLessThan(estimate.frame.maxY, find.frame.minY, "Find an item is below Estimate")
        attach(name: "01-plan-sheet")

        find.tap()
        sleep(2)
        attach(name: "02-picker")
    }

    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
