import XCTest

/// The task option starts off in each new-item flow and keeps its state within a draft.
final class PlannerAddAsTaskUITest: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ sheet: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launchEnvironment["LAUNCH_PLANNER_SHEET"] = sheet
        app.launchEnvironment["LAUNCH_PLANNER_TEXT"] = "Checklist probe 3:30pm 15m"
        app.launch()
        return app
    }

    private func checkbox(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["planner.addAsTask"].firstMatch
    }

    func testQuickEntryDefaultsOffAndDoneResetsThatDefault() {
        let app = launch("quickadd")
        let box = checkbox(app)
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        XCTAssertEqual(box.value as? String, "Unchecked")
        box.tap()
        XCTAssertEqual(box.value as? String, "Checked")
        app.buttons["planner.sheet.done"].firstMatch.tap()

        // A fresh entry starts unchecked after dismissing the previous entry.
        app.buttons["Add a block"].firstMatch.tap()
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        XCTAssertEqual(box.value as? String, "Unchecked")
    }

    func testQuickEntryFormRetainsTheChoice() {
        let app = launch("quickadd")
        let box = checkbox(app)
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap()
        app.buttons["Use the form instead"].tap()
        XCTAssertEqual(box.value as? String, "Checked")
        app.buttons["planner.sheet.done"].firstMatch.tap()
    }

    func testGridQuickCreateDefaultsOffAndCancel() {
        let app = launch("draft")
        let box = checkbox(app)
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        XCTAssertEqual(box.value as? String, "Unchecked")
        box.tap()
        XCTAssertEqual(box.value as? String, "Checked")
        app.buttons["Discard"].firstMatch.tap()
        XCTAssertFalse(app.textFields["planner.quickcreate.title"].waitForExistence(timeout: 2))
    }

    func testGridMoreOptionsRetainsTheChoice() {
        let app = launch("draft")
        let box = checkbox(app)
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap()
        app.buttons["More options"].tap()
        XCTAssertTrue(app.buttons["planner.sheet.save"].waitForExistence(timeout: 5))
        XCTAssertEqual(box.value as? String, "Checked")
        app.buttons["planner.sheet.cancel"].firstMatch.tap()
    }
}
