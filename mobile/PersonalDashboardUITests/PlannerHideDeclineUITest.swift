import XCTest

/// Remove a repeating calendar event from the Planner (#689): the series
/// choice, the Undo toast, and the restore list in settings.
final class PlannerHideDeclineUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testRemoveOneOccurrenceShowsTheSeriesChoiceAndUndo() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launchEnvironment["LAUNCH_PLANNER_SHEET"] = "event"
        app.launchEnvironment["LAUNCH_PLANNER_TEXT"] = "Daily sync"
        app.launch()

        let remove = app.buttons["planner.event.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the event sheet offers Remove from Planner")
        XCTAssertTrue(app.buttons["planner.event.decline"].exists, "and Decline in Dexter")
        keep("1-event-details-actions", app)

        remove.tap()
        let only = app.buttons["Only this event"].firstMatch
        XCTAssertTrue(only.waitForExistence(timeout: 5), "a repeating event asks which ones")
        XCTAssertTrue(app.buttons["All events in the series"].exists)
        keep("2-series-choice", app)

        only.tap()
        let undo = app.buttons["planner.toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "an Undo toast follows the hide")
        keep("3-undo-toast", app)
        undo.tap()
        XCTAssertFalse(undo.waitForExistence(timeout: 2))
    }

    func testSettingsListsHiddenAndDeclinedEvents() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launchEnvironment["LAUNCH_PLANNER_SHEET"] = "settings"
        app.launch()
        let restore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Restore'")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 8), "the restore list has entries")
        // Swipe inside the sheet (not the page behind it) until the list is on screen.
        let heading = app.staticTexts["Planner settings"].firstMatch
        for _ in 0..<6 where !restore.isHittable {
            heading.swipeUp()
            app.staticTexts["Calendars".uppercased()].firstMatch.swipeUp()
        }
        keep("4-settings-hidden-list", app)
    }
}
