import XCTest

/// The "high protein per calorie" mark on saved items (#690).
///
/// Walks the three surfaces it touches: the meal sheet's protein density row,
/// the picker's badge, and the editor's toggle. Needs a meal and a marked
/// saved item in the simulator store; skips when there are none.
final class HighProteinSavedItemUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_marked_item_shows_badge_and_protein_density() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launch()

        if app.staticTexts["No meals logged today"].waitForExistence(timeout: 6) {
            throw XCTSkip("No meals logged today in this simulator's store.")
        }

        // 1. The meal sheet: protein per 100 kcal under the totals.
        guard let row = app.buttons.allElementsBoundByIndex
            .first(where: { $0.exists && $0.frame.height > 100 && $0.frame.width > 300 })
        else { throw XCTSkip("No meal row found on the opening day.") }
        row.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 6), "The meal detail sheet did not open.")
        let density = app.staticTexts["Protein density"]
        var attempts = 0
        while !density.isHittable, attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(density.exists, "The meal sheet shows protein density.")
        attach(app, name: "01-meal-detail-density")
        app.buttons["Done"].tap()

        // 2. The picker: the marked item carries the badge.
        let find = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Find an item to add'")).firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 6), "The composer offers the picker.")
        find.tap()
        let marked = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'high protein per calorie'")).firstMatch
        XCTAssertTrue(marked.waitForExistence(timeout: 6), "A marked saved item is labelled as marked.")
        sleep(1)
        attach(app, name: "02-picker-badge")

        // 3. The editor: the toggle and the live ratio.
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'More actions for'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 4))
        more.tap()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 4))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Saved item"].waitForExistence(timeout: 6), "The editor opened.")
        sleep(1)
        attach(app, name: "03-editor-header")
        let toggle = app.buttons["High protein per calorie"]
        attempts = 0
        while !(toggle.exists && toggle.isHittable), attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(toggle.exists, "The editor shows the high protein toggle.")
        attach(app, name: "04-editor-toggle")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
