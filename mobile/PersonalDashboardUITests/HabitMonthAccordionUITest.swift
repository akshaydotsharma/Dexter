import XCTest

/// Opens the month view on every habit in turn, with real taps (#664).
///
/// ### Why a UI test
///
/// The accordion is one `@State` on the section and a Button per card, and
/// every line of it reads correctly. The defect only showed on a real runtime,
/// on some habits and not others, so a unit test cannot witness it.
///
/// ### The store
///
/// The run needs habits. It opens whatever store `HABIT_QA_STORE` names (a
/// COPY, never the live one) through the DEBUG `DEXTER_STORE_PATH` override.
/// Pass it as `TEST_RUNNER_HABIT_QA_STORE=<path>` to xcodebuild. With no store
/// the test skips instead of failing, because the simulator's own store may
/// hold no habits at all.
///
/// ### What it checks
///
/// For each habit card, top to bottom: tapping its month control opens a
/// month grid INSIDE that card, exactly one grid is on screen, and the card
/// that was open before is closed again.
final class HabitMonthAccordionUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_each_habit_opens_its_month_and_closes_the_previous_one() throws {
        let env = ProcessInfo.processInfo.environment
        guard let store = env["HABIT_QA_STORE"], !store.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HABIT_QA_STORE to a copy of a store that holds habits")
        }
        let names = (env["HABIT_QA_NAMES"] ?? "Strength Training,Cardio,Alcohol,Cook food")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "habits"
        app.launchEnvironment["DEXTER_STORE_PATH"] = store
        app.launchEnvironment["DEXTER_STORE_PATH_ACK"] = "1"
        app.launchEnvironment["DEXTER_SYNC_FOLDER"] = (store as NSString).deletingLastPathComponent + "/sync"
        app.launch()
        sleep(2)
        attach(name: "00-habits-closed")

        XCTAssertEqual(
            app.buttons.matching(identifier: "Previous month").count, 0,
            "A month view was open before any tap"
        )

        var previous: String?
        for (index, name) in names.enumerated() {
            let header = app.buttons[name].firstMatch
            scrollIntoView(header, in: app)
            XCTAssertTrue(header.waitForExistence(timeout: 5), "No card for \(name)")

            let toggle = monthToggle(below: header, in: app)
            XCTAssertNotNil(toggle, "No month control under \(name)")
            guard let toggle else { return }
            scrollIntoView(toggle, in: app)
            toggle.tap()
            sleep(1)
            attach(name: String(format: "%02d-open-%@", index + 1, name))

            let grids = app.buttons.matching(identifier: "Previous month")
            XCTAssertEqual(
                grids.count, 1,
                "After tapping \(name)'s month control, \(grids.count) month views are on screen"
                    + (previous.map { " (\($0) should have closed)" } ?? "")
            )
            // The one grid on screen belongs to THIS card: it sits under this
            // card's header and above the next card's header.
            let header2 = app.buttons[name].firstMatch
            let grid = grids.firstMatch
            XCTAssertTrue(grid.exists, "\(name)'s month view did not open")
            XCTAssertGreaterThan(
                grid.frame.minY, header2.frame.maxY,
                "The open month view is not under \(name)"
            )
            // The header of the card laid out next, whichever habit it is.
            let below = names
                .filter { $0 != name }
                .map { app.buttons[$0].firstMatch }
                .filter { $0.exists && $0.frame.minY > header2.frame.maxY }
                .min { $0.frame.minY < $1.frame.minY }
            if let below {
                XCTAssertLessThan(
                    grid.frame.minY, below.frame.minY,
                    "The open month view is under \(below.label), not \(name)"
                )
            }
            previous = name
        }
    }

    /// The Today card's trend shares `HabitDayMark` with the Habits page, so
    /// its look changes with it. This photographs it for review; it asserts
    /// only that the card is there.
    func test_today_card_trend_screenshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let store = env["HABIT_QA_STORE"], !store.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HABIT_QA_STORE to a copy of a store that holds habits")
        }
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "today"
        app.launchEnvironment["DEXTER_STORE_PATH"] = store
        app.launchEnvironment["DEXTER_STORE_PATH_ACK"] = "1"
        app.launchEnvironment["DEXTER_SYNC_FOLDER"] = (store as NSString).deletingLastPathComponent + "/sync"
        app.launch()
        sleep(2)
        let trend = app.otherElements["Last 7 days"].firstMatch
        for _ in 0..<6 where !(trend.exists && trend.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        attach(name: "20-today-card")
        XCTAssertTrue(trend.exists, "No habit trend on the Today card")
    }

    // MARK: - Helpers

    /// The month control of the card whose header is `header`: the first
    /// month control laid out below that header.
    private func monthToggle(below header: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(
            format: "label BEGINSWITH[c] 'Show month' OR label BEGINSWITH[c] 'Hide month' OR label BEGINSWITH[c] 'View month'"
        )
        let top = header.frame.maxY
        let candidates = app.buttons.matching(predicate).allElementsBoundByIndex
            .filter { $0.frame.minY > top }
            .sorted { $0.frame.minY < $1.frame.minY }
        return candidates.first
    }

    /// Swipe the list until `element` is fully on screen.
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        for _ in 0..<8 {
            if element.exists, element.isHittable,
               element.frame.minY > window.minY + 100, element.frame.maxY < window.maxY - 120 {
                return
            }
            if element.exists, element.frame.minY < window.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
