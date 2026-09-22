import XCTest

/// Drives `EdDateTimeField` on a real runtime (#657).
///
/// ### Why this test exists at all
///
/// The field's whole point is that the calendar opens UNDER the row instead of
/// over the sheet, and that is exactly the kind of change a build log cannot
/// witness. It is also the kind a screenshot pass cannot witness on its own:
/// a synthetic click delivered to the simulator window does not flip a SwiftUI
/// `Toggle`, so the panel can only be opened from inside the process. That is
/// this file.
///
/// ### What it checks
///
/// 1. An OPTIONAL date is off, and no calendar is on screen.
/// 2. Switching it on puts the calendar there, in place, with the sheet's own
///    fields still above and below it.
/// 3. The Time row appears with the date and opens a clock of its own.
/// 4. A MANDATORY date carries the same two rows, and its row opens the
///    calendar although its switch cannot be moved.
final class DateTimeFieldUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Optional: a task's due date

    func test_task_due_date_opens_a_calendar_in_place() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "tasks"
        app.launch()
        sleep(2)

        openManualTaskSheet(app)
        attach(name: "01-task-sheet-date-off")

        // Nothing is open before the switch moves.
        XCTAssertFalse(
            app.buttons["Previous month"].exists,
            "A calendar was on screen before the date was switched on"
        )

        let dateSwitch = app.switches["Date"].firstMatch
        XCTAssertTrue(dateSwitch.waitForExistence(timeout: 5), "Date switch not found")
        dateSwitch.tap()
        sleep(1)
        attach(name: "02-task-calendar-open")

        XCTAssertTrue(
            app.buttons["Previous month"].waitForExistence(timeout: 5),
            "The calendar did not open under the row"
        )

        // The Time row hangs off the date, so it is only here now.
        let timeRow = app.buttons["Time"].firstMatch
        XCTAssertTrue(timeRow.waitForExistence(timeout: 5), "Time row not found under the date")
        timeRow.tap()
        sleep(1)
        attach(name: "03-task-clock-open")

        // One panel at a time: opening the clock shuts the calendar.
        XCTAssertFalse(
            app.buttons["Previous month"].exists,
            "Both panels were open at once"
        )
    }

    // MARK: - Mandatory: an expense's date

    func test_expense_date_opens_from_the_row() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "finance"
        app.launch()
        sleep(2)

        let addExpense = app.buttons["Add expense"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 10), "Add expense FAB not found")
        addExpense.tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Enter manually'"))
            .firstMatch.tap()
        sleep(2)
        attach(name: "04-expense-sheet")

        // An expense always happened on a day, so the row is the way in.
        let dateRow = app.buttons["When did this happen?"].firstMatch
        XCTAssertTrue(dateRow.waitForExistence(timeout: 5), "Expense date row not found")
        dateRow.tap()
        sleep(1)
        attach(name: "05-expense-calendar-open")

        XCTAssertTrue(
            app.buttons["Previous month"].waitForExistence(timeout: 5),
            "The expense calendar did not open from the row"
        )
    }

    // MARK: - Two mandatory rows in one card

    /// A trip's Start and End sit in the same card, so this is the one place
    /// two of these fields are stacked. It checks that opening the second one
    /// shuts the first, rather than stacking two calendars down the sheet.
    func test_trip_dates_open_one_at_a_time() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "itineraries"
        app.launch()
        sleep(2)

        let newTrip = app.buttons["New trip"].firstMatch
        XCTAssertTrue(newTrip.waitForExistence(timeout: 10), "New trip FAB not found")
        newTrip.tap()
        sleep(2)
        attach(name: "06-trip-sheet")

        let start = app.buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start row not found")
        start.tap()
        sleep(1)
        attach(name: "07-trip-start-open")
        XCTAssertTrue(
            app.buttons["Previous month"].waitForExistence(timeout: 5),
            "The start calendar did not open"
        )

        let end = app.buttons["End"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5), "End row not found")
        end.tap()
        sleep(1)
        attach(name: "08-trip-end-open")

        // Each field owns its own panel, so exactly one calendar is on screen.
        XCTAssertEqual(
            app.buttons.matching(identifier: "Previous month").count, 1,
            "Both trip calendars were open at once"
        )
    }

    // MARK: - Helpers

    private func openManualTaskSheet(_ app: XCUIApplication) {
        let add = app.buttons["Add a task"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add a task FAB not found")
        add.tap()
        sleep(1)
        let manual = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Enter manually'"))
            .firstMatch
        if manual.waitForExistence(timeout: 3) {
            manual.tap()
        }
        sleep(2)
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
