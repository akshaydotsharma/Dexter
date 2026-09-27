import XCTest

/// "Save to library" keeps the whole meal, not one of its dishes (#673).
///
/// The per-dish button used to sit inside each item's drawer. This opens a
/// logged meal, checks the save is a meal-level action, and checks it opens the
/// editor on the meal rather than on a component.
final class MealSaveToLibraryUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_save_to_library_keeps_the_whole_meal() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launch()

        if app.staticTexts["No meals logged today"].waitForExistence(timeout: 6) {
            throw XCTSkip("No meals logged today in this simulator's store, so there is no meal to open.")
        }
        // A meal row is the one full-width card that is also tall; see
        // `MealRowSwipeUITest.firstMealRow` for why both dimensions.
        guard let row = app.buttons.allElementsBoundByIndex
            .first(where: { $0.exists && $0.frame.height > 100 && $0.frame.width > 300 })
        else { throw XCTSkip("No meal row found on the opening day.") }
        row.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 6), "The meal detail sheet did not open.")

        // One save, at the meal's own level. The sheet opens with every dish
        // drawer closed, so a per-dish button would not be on screen anyway;
        // exactly one match is the meal's.
        let save = app.buttons["Save to library"]
        var attempts = 0
        while !save.exists || !save.isHittable, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertEqual(app.buttons.matching(identifier: "Save to library").count, 1)
        attach(app, name: "01-meal-actions")

        save.tap()
        XCTAssertTrue(
            app.navigationBars["Keep this meal"].waitForExistence(timeout: 6),
            "Save to library did not open the editor on the whole meal."
        )
        attach(app, name: "02-keep-this-meal")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
