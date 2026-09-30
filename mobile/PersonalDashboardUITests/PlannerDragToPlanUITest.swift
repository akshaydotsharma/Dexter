import XCTest

/// Drag a task from the iPhone To-plan panel onto the grid (#687 fix).
final class PlannerDragToPlanUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testHoldADragsAndDropPlansTheTask() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()

        let grid = app.otherElements["Empty time"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        sleep(1)
        let gridFrame = grid.frame
        app.buttons["Tasks to plan"].firstMatch.tap()

        let title = "Book flights for Bali"
        let source = app.otherElements["planner.toplan.drag.\(title)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), "the To-plan panel lists the task")
        keep("1-toplan-panel", app)

        // Today scrolls so the hour before now is at the top of the grid.
        let hour = Calendar.current.component(.hour, from: Date())
        let topHour = max(0, min(23, hour - 1))
        let gridTop = gridFrame.minY + CGFloat(topHour) * 54
        let drop = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: gridFrame.midX, dy: gridTop + 54 + 20))   // (topHour+1):20
        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        from.press(forDuration: 0.6, thenDragTo: drop, withVelocity: .slow, thenHoldForDuration: 0.5)

        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the dropped task is a tile on the grid")
        let h12 = (topHour + 1) % 12 == 0 ? 12 : (topHour + 1) % 12
        XCTAssertTrue(tile.label.contains("\(h12):15"), "it landed at the snapped drop time (\(tile.label))")
        keep("2-dropped-task", app)

        // Put the simulator back: remove the plan again.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let remove = app.buttons["Remove from plan"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.buttons.matching(identifier: "Remove from plan").element(boundBy: 1)
        if confirm.waitForExistence(timeout: 3) { confirm.tap() } else { app.buttons["Remove from plan"].firstMatch.tap() }
    }

    /// Release over nothing (the day header): the card flies back and the
    /// row is on the list again, and nothing is planned.
    func testAMissReturnsTheRowToTheList() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()
        XCTAssertTrue(app.otherElements["Empty time"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Tasks to plan"].firstMatch.tap()
        let title = "Book flights for Bali"
        let source = app.otherElements["planner.toplan.drag.\(title)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let header = app.staticTexts["30 September"].firstMatch.exists
            ? app.staticTexts["30 September"].firstMatch
            : app.buttons["Day"].firstMatch
        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        from.press(forDuration: 0.6, thenDragTo: header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertTrue(source.waitForExistence(timeout: 3) && source.frame.height > 10, "the row is back on the list")
        let planned = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertFalse(planned.exists, "nothing was planned")
        keep("3-miss-row-back", app)
    }
}
