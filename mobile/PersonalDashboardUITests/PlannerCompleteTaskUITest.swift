import XCTest

/// #695 on the iPhone Planner: Mark complete from a task tile's quick view,
/// see the tile turn completed at once, then Mark incomplete to undo it.
///
/// Needs a task "Review hiring plan" due today at 3 PM with no plan in the
/// simulator store. The test leaves it open, the way it found it.
final class PlannerCompleteTaskUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitForLabel(_ element: XCUIElement, _ predicate: String, _ text: String, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: predicate, text), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    func testCompleteAndUndoFromTheQuickView() {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launchEnvironment["LAUNCH_PLANNER_MODE"] = "day"
        app.launchEnvironment["LAUNCH_PLANNER_SHEET"] = "quickview"
        app.launchEnvironment["LAUNCH_PLANNER_TEXT"] = "Review hiring"
        app.launch()

        let complete = app.buttons["planner.quick.complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10), "a task's quick view has the complete button")
        XCTAssertEqual(complete.label, "Mark complete")
        keep("1-quick-view-mark-complete", app)
        complete.tap()

        let tile = app.buttons["planner.tile.Review hiring plan"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "a completed task stays on its day")
        waitForLabel(tile, "label CONTAINS %@", "completed")
        keep("2-tile-completed", app)

        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let undo = app.buttons["planner.quick.complete"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertEqual(undo.label, "Mark incomplete")
        keep("3-quick-view-mark-incomplete", app)
        undo.tap()
        waitForLabel(tile, "NOT (label CONTAINS %@)", "completed")
        keep("4-tile-open-again", app)
    }
}
