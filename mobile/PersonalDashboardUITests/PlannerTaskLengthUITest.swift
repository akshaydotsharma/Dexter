import XCTest

/// Task length on the iPhone Planner (#687 fix): change it in the sheet and
/// Save, or drag a tile's bottom edge.
final class PlannerTaskLengthUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Minutes after midnight of the end in a tile label like
    /// "Deep work, 10 AM - 1:15 PM, Dexter block".
    private func endMinutes(_ label: String) -> Int? {
        guard let dash = label.range(of: " - ") else { return nil }
        let rest = label[dash.upperBound...]
        let endText = rest.split(separator: ",").first.map(String.init) ?? ""
        let parts = endText.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let hm = parts[0].split(separator: ":").compactMap { Int($0) }
        guard let h = hm.first else { return nil }
        let m = hm.count > 1 ? hm[1] : 0
        let h24 = (h % 12) + (parts[1] == "PM" ? 12 : 0)
        return h24 * 60 + m
    }

    private func tile(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// A timed task with no plan block: tap it, set the length to 1h 30m,
    /// Save, and the tile runs 5 to 6:30 PM.
    func testSaveANewLengthForATimedTask() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()
        let deck = tile(app, "Send roadmap deck")
        XCTAssertTrue(deck.waitForExistence(timeout: 10))
        let grid = app.otherElements["Empty time"].firstMatch
        for _ in 0..<5 where !deck.isHittable { grid.swipeUp(velocity: .slow) }
        // Tap the upper part of the tile; the bottom edge is the resize strip.
        deck.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        // The tap opens the quick view (#687 round 6); Edit opens the sheet.
        let edit = app.buttons["planner.quick.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let save = app.buttons["planner.sheet.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save is in the header, on screen at once")
        app.buttons["planner.details.length"].firstMatch.tap()
        app.buttons["1h 30m"].firstMatch.tap()
        keep("1-task-sheet-length", app)
        save.tap()

        XCTAssertFalse(save.waitForExistence(timeout: 2))
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send roadmap deck' AND label CONTAINS '6:30 PM'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the tile now ends at 6:30 PM")
        keep("2-task-tile-after-save", app)
    }

    /// Drag the bottom edge of a block down one hour.
    func testDragTheBottomEdgeToResize() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "planner"
        app.launch()
        let next = app.buttons["Next day"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let weekday = Calendar.current.component(.weekday, from: Date())
        for _ in 0..<((8 - weekday) % 7 == 0 ? 7 : (8 - weekday) % 7) { next.tap() }

        let block = tile(app, "Deep work")
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        let before = block.label
        let handle = app.otherElements["planner.resize.Deep work"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "a Dexter block has a resize handle")
        sleep(1)
        XCTAssertTrue(handle.isHittable, "the edge is on screen before it is dragged")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.4, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 54)), withVelocity: .slow, thenHoldForDuration: 0.3)

        let after = tile(app, "Deep work")
        let predicate = NSPredicate(format: "label != %@", before)
        expectation(for: predicate, evaluatedWith: after)
        waitForExpectations(timeout: 5)
        keep("3-after-resize", app)
        let b = try XCTUnwrap(endMinutes(before)), a = try XCTUnwrap(endMinutes(after.label))
        XCTAssertEqual(a - b, 60, "54 points is one hour at 54pt per hour (\(before) -> \(after.label))")

        // Drag it back up one hour, so the simulator's data is the same after
        // every run and the next run finds the edge on screen.
        let back = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.4, thenDragTo: back.withOffset(CGVector(dx: 0, dy: -54)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let restored = NSPredicate(format: "label == %@", before)
        expectation(for: restored, evaluatedWith: tile(app, "Deep work"))
        waitForExpectations(timeout: 5)
    }
}
