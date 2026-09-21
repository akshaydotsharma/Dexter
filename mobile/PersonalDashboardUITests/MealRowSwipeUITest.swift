import XCTest

/// The meal row's swipe strip, driven rather than assumed (#645).
///
/// A meal row lives in a `VStack` inside a `ScrollView`, not a `List`, so the
/// affordance under test is NOT `.swipeActions` — that modifier does nothing
/// outside a `List` and would have failed silently. It is `rowSwipeActions`,
/// whose iOS path is a bridged `UIPanGestureRecognizer`. A static build proves
/// none of that, which is why this drags a real finger across a real row.
///
/// The three buttons exist in the view tree at opacity 0 before the swipe and
/// are explicitly excluded from hit testing until the row has travelled most of
/// the reveal width. So every assertion here is on `isHittable`, never on
/// `exists`: existence passes against an unswiped row and would make this test
/// green whether the gesture worked or not.
final class MealRowSwipeUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_swiping_a_meal_row_reveals_repeat_edit_and_delete() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launch()

        let row = try firstMealRow(in: app)
        attach(app, name: "01-meals-day")

        // Deliberately not `swipeLeft()`. That synthesises a fast flick, and a
        // flick is the one input this recogniser has a separate velocity path
        // for — passing on it would leave the ordinary slow drag untested.
        let rowOrigin = row.frame.minX
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.08, thenDragTo: end)

        // Matched on the SF Symbol IDENTIFIER, not the visible label.
        //
        // `app.buttons["Delete"]` is ambiguous here: the meal detail sheet also
        // carries a Delete, so a label query can resolve to a button on a
        // completely different surface and pass or fail for the wrong reason.
        // The strip's glyph names are unique to the strip.
        let repeatToday = app.buttons["arrow.triangle.2.circlepath"]
        let edit = app.buttons["pencil"]
        let delete = app.buttons["trash"]

        for button in [repeatToday, edit, delete] {
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "\(button.identifier) never appeared, so the pan did not open the strip."
            )
        }

        // The row has to have actually travelled, not merely rendered buttons
        // underneath itself. One 60pt slot per action, so three actions move the
        // row a full 180pt left of where it started.
        let moved = rowOrigin - (tallestRowFrame(app)?.minX ?? rowOrigin)
        XCTAssertEqual(
            moved, 180, accuracy: 8,
            "The row moved \(moved)pt; three 60pt slots should move it 180pt."
        )

        // Order is the point of the array, and it is what muscle memory depends
        // on: the trash keeps the trailing edge on every swipeable row in the
        // app, with the reversible actions inboard of it.
        XCTAssertLessThan(repeatToday.frame.minX, edit.frame.minX, "Repeat should sit inboard of Edit.")
        XCTAssertLessThan(edit.frame.minX, delete.frame.minX, "Edit should sit inboard of Delete.")

        // Prove a revealed button really answers a touch.
        //
        // Deliberately NOT `delete.tap()`, and deliberately not asserting
        // `isHittable`. XCUITest resolves a hit point through the UIKit view
        // that hosts the pan recogniser, which spans the whole row, so it
        // reports these buttons as unhittable even while the row is fully open
        // and they are plainly on screen. A coordinate tap goes through the same
        // touch path a finger does and settles the question by its effect.
        //
        // Edit, because it is the one of the three that changes no data: it
        // opens the detail sheet, and the sheet appearing is the proof.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: edit.frame.midX, dy: edit.frame.midY))
            .tap()

        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 6),
            "Tapping Edit on the open strip did not open the meal detail sheet."
        )

        attach(app, name: "02-swipe-revealed")
    }

    /// The long-press menu carries the same three. This is the half of #645 that
    /// matters most for discoverability: the swipe strip gives up
    /// full-swipe-to-commit once it holds more than one button, so the menu is
    /// the affordance a user can still find by accident.
    func test_long_pressing_a_meal_row_offers_the_same_three_actions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launch()

        let row = try firstMealRow(in: app)
        row.press(forDuration: 1.1)

        XCTAssertTrue(
            waitForHittable(app.buttons["trash"]),
            "Long-press did not present a context menu containing Delete."
        )
        XCTAssertTrue(waitForHittable(app.buttons["pencil"]), "Context menu had no Edit.")
        XCTAssertTrue(
            waitForHittable(app.buttons["arrow.triangle.2.circlepath"]),
            "Context menu had no Repeat today."
        )

        attach(app, name: "03-long-press-menu")
    }

    // MARK: - Helpers

    /// The first logged-meal row on the day the section opens on.
    ///
    /// Skips rather than fails on a store with nothing logged today: this test
    /// is about the gesture, and a simulator with an empty day is a fixture
    /// problem, not a regression. A silent pass would be worse than either.
    private func firstMealRow(in app: XCUIApplication) throws -> XCUIElement {
        let empty = app.staticTexts["No meals logged today"]
        if empty.waitForExistence(timeout: 6) {
            throw XCTSkip("No meals logged today in this simulator's store, so there is no row to swipe.")
        }
        // The row is one Button wrapping the whole card, so it is by far the
        // tallest button on the day (~209pt against 44pt for the chrome).
        // Matching on height keeps this off the composer's controls and the tab
        // strip without hard-coding a dish name.
        // Width AND height. Height alone matched a 71x64 tab-bar control before
        // the meal row, so the drag was being aimed at the wrong thing entirely;
        // a meal row is a full-width card (~370x209) and nothing else on the day
        // is both that wide and that tall.
        func tallestButton() -> XCUIElement? {
            app.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.frame.height > 100 && $0.frame.width > 300 }
                .first
        }
        guard var row = tallestButton() else {
            throw XCTSkip("No meal row found on the opening day.")
        }

        // Scroll it fully into view before anyone tries to drag it.
        //
        // This is what the first version of this test got wrong, and it failed
        // in a way worth recording: the day card is tall enough that the first
        // meal row starts near the bottom edge, so a drag anchored at the row's
        // own midpoint began at a y BELOW the window. The touch landed nowhere,
        // the pan never started, and the assertion read exactly as it would
        // have if the gesture were broken.
        let window = app.windows.firstMatch
        var attempts = 0
        while row.frame.maxY > window.frame.maxY - 8, attempts < 6 {
            app.swipeUp()
            attempts += 1
            guard let refreshed = tallestButton() else {
                throw XCTSkip("Meal row disappeared while scrolling it into view.")
            }
            row = refreshed
        }
        XCTAssertTrue(
            row.frame.maxY <= window.frame.maxY,
            "Could not bring a whole meal row on screen; the drag below would start outside the window."
        )

        // Let the scroll finish before handing the row back.
        //
        // Without this the swipe test failed while the identical sequence
        // passed by hand, because the drag began while the ScrollView was still
        // decelerating. `gestureRecognizerShouldBegin` only claims a touch whose
        // velocity is horizontal-dominant, and a already-moving scroll view
        // keeps the vertical pan alive, so the row's own recogniser never won.
        // That is the arbitration working correctly; the test just has to stop
        // racing it.
        if attempts > 0 {
            Thread.sleep(forTimeInterval: 1.5)
        }
        return row
    }

    /// The meal row's frame as it stands right now, re-queried rather than
    /// remembered: the element the drag moved is the one whose `minX` matters.
    private func tallestRowFrame(_ app: XCUIApplication) -> CGRect? {
        app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 100 && $0.frame.width > 300 }
            .first?
            .frame
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
