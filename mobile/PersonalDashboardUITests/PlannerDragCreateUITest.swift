import XCTest

/// Drag-to-create on the iPhone Planner grid (#687 round 3), end to end:
/// press and hold on empty time, drag down, name the draft, save it, and find
/// the new tile. Screenshots of each step are kept as attachments.
final class PlannerDragCreateUITest: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Matches `PlannerGridMetrics.hourHeight` on iOS.
    private let hourHeight: CGFloat = 54

    /// Step forward to a Sunday with nothing during working hours in the
    /// seeded simulator, and return the grid's drag layer.
    private func openEmptyDay(_ app: XCUIApplication) throws -> XCUIElement {
        let next = app.buttons["Next day"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let weekday = Calendar.current.component(.weekday, from: Date())
        // The Sunday AFTER next: nothing is seeded there, and the other UI
        // tests use this Sunday, so its hours stay empty run after run.
        for _ in 0..<(((8 - weekday) % 7 == 0 ? 7 : (8 - weekday) % 7) + 7) { next.tap() }
        let empty = app.otherElements["Empty time"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "the grid's drag layer is on screen")
        sleep(1)   // let the scroll settle before aiming
        return empty
    }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testHoldAndDragCreatesANamedBlock() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()

        let empty = try openEmptyDay(app)
        // A day other than today scrolls so the workday start (9 AM) is at
        // the top of the grid, which puts 10 AM at gridTop + one hour.
        let frame = empty.frame
        let gridTop = frame.minY + 9 * hourHeight
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: gridTop + hourHeight + 10))
        let to = from.withOffset(CGVector(dx: 0, dy: 110))

        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)

        let title = app.textFields["planner.quickcreate.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "release shows the quick-create title field")
        keep("1-draft-and-quick-create", app)

        title.typeText("Deep work")
        keep("2-typed-title", app)
        app.buttons["Save"].firstMatch.tap()

        XCTAssertFalse(title.waitForExistence(timeout: 2), "Save closes the quick-create card")
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Deep work'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "the new block is a tile on the grid")
        keep("3-saved-tile", app)

        // Tap the tile: its quick view (#687 round 6), with Edit and Delete.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let edit = app.buttons["planner.quick.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "a tap opens the quick view")
        XCTAssertTrue(app.buttons["planner.quick.delete"].exists, "with Delete beside Edit")
        keep("4-quick-view", app)

        // Edit: the details sheet, on the Tasks editor's components.
        edit.tap()
        let notes = app.descendants(matching: .any)["planner.details.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "Edit opens the details sheet")
        XCTAssertTrue(app.buttons["Start"].exists, "the start is an EdDateTimeField row")
        keep("5-details-sheet", app)

        // Delete from the sheet, confirm, and the tile is gone. This also puts
        // the simulator back, so the next run finds this time empty.
        app.buttons["planner.details.delete"].tap()
        let confirm = app.buttons["planner.delete.deleteBlock"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete asks first")
        keep("6-delete-confirm", app)
        confirm.tap()
        XCTAssertFalse(tile.waitForExistence(timeout: 3), "the block is deleted")
    }

    func testATapWithNoDragMakesADraftAndCancelWritesNothing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()
        let empty = try openEmptyDay(app)
        let gridTop = empty.frame.minY + 9 * hourHeight
        let point = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: empty.frame.midX, dy: gridTop + 2.5 * hourHeight))
        point.tap()
        let title = app.textFields["planner.quickcreate.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "a plain tap makes a draft too")
        app.buttons["Discard"].firstMatch.tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2), "Discard closes it")
    }
}
