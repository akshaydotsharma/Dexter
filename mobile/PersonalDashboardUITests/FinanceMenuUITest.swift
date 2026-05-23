import XCTest

final class FinanceMenuUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_finance_plus_button_shows_capture_menu() throws {
        let app = XCUIApplication()
        app.launch()

        sleep(2)
        attach(name: "01-landing")

        let hamburger = app.buttons["Open navigation"]
        XCTAssertTrue(hamburger.waitForExistence(timeout: 10), "Hamburger menu not found")
        hamburger.tap()
        sleep(1)
        attach(name: "02-drawer-open")

        let financeRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Finance'")).firstMatch
        XCTAssertTrue(financeRow.waitForExistence(timeout: 5), "Finance row not found in drawer")
        financeRow.tap()
        sleep(1)
        attach(name: "03-finance-page")

        let addExpense = app.buttons["Add expense"]
        XCTAssertTrue(addExpense.waitForExistence(timeout: 5), "Add expense (+) FAB not found")
        addExpense.tap()
        sleep(1)
        attach(name: "04-menu-open")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
