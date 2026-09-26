import XCTest

/// A cold launch lands on Today, and today's trend mark is the check (#665).
///
/// Runs against a COPY of a store with habits, named by
/// `TEST_RUNNER_HABIT_QA_STORE`, through the DEBUG `DEXTER_STORE_PATH`
/// override. With no store it skips. It sets NO `LAUNCH_SECTION`, because the
/// default landing is the thing under test.
final class TodayLandingUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_cold_launch_lands_on_today_and_the_today_mark_toggles() throws {
        let env = ProcessInfo.processInfo.environment
        guard let store = env["HABIT_QA_STORE"], !store.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HABIT_QA_STORE to a copy of a store that holds habits")
        }
        let habit = env["HABIT_QA_TODAY_HABIT"] ?? "Cardio"

        let app = XCUIApplication()
        app.launchEnvironment["DEXTER_STORE_PATH"] = store
        app.launchEnvironment["DEXTER_STORE_PATH_ACK"] = "1"
        app.launchEnvironment["DEXTER_SYNC_FOLDER"] = (store as NSString).deletingLastPathComponent + "/sync"
        app.launch()
        sleep(2)
        attach(name: "30-cold-launch")

        // Today, not Chat: the Habits section heading is on screen, and the
        // chat composer is not.
        XCTAssertTrue(
            app.staticTexts["Habits"].waitForExistence(timeout: 10),
            "A cold launch did not open on Today"
        )

        // Today shows once per habit: as the last trend mark, which is a Button.
        let notDone = app.buttons["Today, \(habit), not done"]
        let done = app.buttons["Today, \(habit), done"]
        XCTAssertTrue(notDone.waitForExistence(timeout: 5), "No today mark for \(habit)")
        XCTAssertFalse(
            app.buttons["Mark \(habit) done"].exists,
            "The old check button beside the streak is still there"
        )

        notDone.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Tapping today did not check it")
        attach(name: "31-today-checked")

        done.tap()
        XCTAssertTrue(notDone.waitForExistence(timeout: 5), "A second tap did not uncheck it")
        attach(name: "32-today-unchecked")

        // The other section headings, for review.
        app.swipeUp(velocity: .slow)
        attach(name: "33-today-lower")
        app.swipeUp(velocity: .slow)
        attach(name: "34-today-lowest")
    }

    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
