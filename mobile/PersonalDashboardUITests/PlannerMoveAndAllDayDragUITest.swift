import XCTest

/// #693 on the iPhone Planner: drag a task from the All Day row onto the grid,
/// and touch and hold a Dexter tile to move it, while the bottom-edge resize
/// and tap-to-open keep working.
///
/// Needs today's seed in the simulator store: a dayless task "Call the bank",
/// a manual block "Standup notes" 9 to 10 AM, and a task "Review hiring plan"
/// due at 3 PM with no plan. Each test puts the data back the way it found it.
final class PlannerMoveAndAllDayDragUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Matches `PlannerGridMetrics.hourHeight` on iOS.
    private let hourHeight: CGFloat = 54

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()
        XCTAssertTrue(app.otherElements["Empty time"].firstMatch.waitForExistence(timeout: 10))
        sleep(1)   // let the auto-scroll settle before aiming
        return app
    }

    /// A tile on the grid, by its identifier. Not by label: an All Day pill
    /// is a button with the same title.
    private func tile(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["planner.tile.\(title)"].firstMatch
    }

    /// The screen y of a time on today's grid, measured from the "Standup
    /// notes" tile, whose top is the 9 AM line. Not from the drag layer:
    /// XCUITest reports a frame for it that does not move with the scroll.
    private func y(_ app: XCUIApplication, hour: Int, minute: Int = 0) -> CGFloat {
        tile(app, "Standup notes").frame.minY + (CGFloat(hour - 9) + CGFloat(minute) / 60) * hourHeight
    }

    private func gridX(_ app: XCUIApplication) -> CGFloat {
        app.otherElements["Empty time"].firstMatch.frame.midX
    }

    /// Scroll the grid by a measured distance: a slow drag on the hour ruler,
    /// held at the end so there is no momentum. Positive moves content up.
    private func scrollGrid(_ app: XCUIApplication, by dy: CGFloat) {
        let x = app.otherElements["Empty time"].firstMatch.frame.minX - 20
        let from = point(app, x: x, y: 680)
        from.press(forDuration: 0.05, thenDragTo: point(app, x: x, y: 680 - dy), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
    }

    /// Scroll until `target()` (a screen y) sits in the open middle of the grid.
    private func bringIntoView(_ app: XCUIApplication, _ target: () -> CGFloat) {
        for _ in 0..<6 {
            let yy = target()
            if yy > 740 { scrollGrid(app, by: min(yy - 660, 250)) }
            else if yy < 610 { scrollGrid(app, by: max(yy - 660, -250)) }
            else { return }
        }
    }

    private func point(_ app: XCUIApplication, x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func waitForLabel(_ element: XCUIElement, contains text: String, timeout: TimeInterval = 5) {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        expectation(for: p, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    /// Remove the plan a test made through the quick view's Delete, so the
    /// task itself stays and the next run finds the same data.
    private func removePlan(_ app: XCUIApplication, _ t: XCUIElement) {
        bringIntoView(app) { t.frame.midY }
        t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let delete = app.buttons["planner.quick.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "a tap opens the quick view")
        delete.tap()
        let remove = app.buttons["planner.delete.removePlan"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
    }

    // MARK: All Day -> grid

    func testAnAllDayTaskDropsOnTwoPMInItsLength() throws {
        let app = launch()
        let title = "Call the bank"
        let source = app.otherElements["planner.allday.drag.\(title)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), "the dayless task is a pill in the All Day row")
        keep("1-allday-before", app)
        bringIntoView(app) { y(app, hour: 14) }

        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = point(app, x: gridX(app), y: y(app, hour: 14, minute: 5))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)

        let placed = tile(app, title)
        XCTAssertTrue(placed.waitForExistence(timeout: 5), "the dropped task is a tile on the grid")
        waitForLabel(placed, contains: "2 - 2:30 PM")
        XCTAssertFalse(app.otherElements["planner.allday.drag.\(title)"].exists, "and it left the All Day row")
        keep("2-allday-dropped-2pm", app)

        removePlan(app, placed)
        XCTAssertTrue(app.otherElements["planner.allday.drag.\(title)"].waitForExistence(timeout: 5),
                      "removing the plan puts the task back in the All Day row")
    }

    func testAnAllDayTaskDroppedOffTheGridFliesBack() throws {
        let app = launch()
        let title = "Call the bank"
        let source = app.otherElements["planner.allday.drag.\(title)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let header = app.buttons["Next day"].firstMatch
        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.6, thenDragTo: header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertTrue(source.exists && source.frame.height > 10, "the pill is back in the All Day row")
        XCTAssertFalse(tile(app, title).exists, "nothing was planned")
        keep("3-allday-miss", app)
    }

    func testATapOnAnAllDayTaskStillOpensIt() throws {
        let app = launch()
        let source = app.otherElements["planner.allday.drag.Call the bank"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        // A dayless task opens the day and slot picker, with Done.
        let done = app.buttons["planner.sheet.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the tap opens the task's plan sheet")
        keep("4-allday-tap-opens", app)
        done.tap()
    }

    // MARK: Move a tile

    func testHoldAndDragMovesABlockKeepingItsLength() throws {
        let app = launch()
        let block = tile(app, "Standup notes")
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        bringIntoView(app) { block.frame.midY }
        XCTAssertTrue(block.label.contains("9 - 10 AM"), block.label)

        // 2.5 hours down is 135pt.
        let from = block.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.6, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 2.5 * hourHeight)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForLabel(tile(app, "Standup notes"), contains: "11:30 AM - 12:30 PM")
        keep("5-block-moved-1130", app)

        // And back, so the next run finds it at 9. Scroll first: at 11:30
        // the tile can sit under the floating tab bar.
        bringIntoView(app) { tile(app, "Standup notes").frame.midY }
        let back = tile(app, "Standup notes").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        back.press(forDuration: 0.6, thenDragTo: back.withOffset(CGVector(dx: 0, dy: -2.5 * hourHeight)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForLabel(tile(app, "Standup notes"), contains: "9 - 10 AM")
    }

    func testHoldAndDragMovesATaskTile() throws {
        let app = launch()
        let task = tile(app, "Review hiring plan")
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        bringIntoView(app) { task.frame.midY }
        XCTAssertTrue(task.label.contains("3 - 3:30 PM"), task.label)

        let from = task.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.6, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -2 * hourHeight)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        let moved = tile(app, "Review hiring plan")
        waitForLabel(moved, contains: "1 - 1:30 PM")
        keep("6-task-moved-1pm", app)

        // Remove the plan the move made: the task is back at its 3 PM due time.
        removePlan(app, moved)
        waitForLabel(tile(app, "Review hiring plan"), contains: "3 - 3:30 PM")
    }

    func testResizeAndTapStillWorkOnAMovableTile() throws {
        let app = launch()
        let block = tile(app, "Standup notes")
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        bringIntoView(app) { block.frame.maxY }
        let handle = app.otherElements["planner.resize.Standup notes"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.4, thenDragTo: from.withOffset(CGVector(dx: 0, dy: hourHeight)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForLabel(tile(app, "Standup notes"), contains: "9 - 11 AM")
        keep("7-resize-still-works", app)
        let back = app.otherElements["planner.resize.Standup notes"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.4, thenDragTo: back.withOffset(CGVector(dx: 0, dy: -hourHeight)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForLabel(tile(app, "Standup notes"), contains: "9 - 10 AM")

        tile(app, "Standup notes").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(app.buttons["planner.quick.edit"].waitForExistence(timeout: 5), "a tap opens the quick view")
        keep("8-tap-opens-quick-view", app)
    }
}
