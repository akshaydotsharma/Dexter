import XCTest

/// The iPhone's only route to a sub-bullet (#459).
///
/// The software keyboard has no Tab key, so on iOS nesting exists only if the
/// format toolbar carries it. That makes the two buttons the feature itself
/// rather than a convenience, and a logic test on `MarkdownListSyntax` cannot
/// tell whether they are wired to it — which is why this drives the real
/// toolbar and reads the text back out of the editor.
final class NoteIndentToolbarUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_the_toolbar_indents_and_outdents_a_bullet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "notes"
        app.launchEnvironment["LAUNCH_NOTE_MODE"] = "edit"
        app.launch()

        let newNote = app.buttons["plus"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 15), "New-note button not found in Notes")
        newNote.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Note body editor did not appear")
        // The editor takes focus 0.5s after appearing, deliberately: at
        // `onAppear` the text view is not in a window yet.
        sleep(2)
        editor.tap()

        let bullet = app.buttons["bullet"]
        let indent = app.buttons["indent"]
        let outdent = app.buttons["outdent"]
        XCTAssertTrue(bullet.waitForExistence(timeout: 5), "Format toolbar not present")
        XCTAssertTrue(indent.exists, "No indent button in the format toolbar")
        XCTAssertTrue(outdent.exists, "No outdent button in the format toolbar")

        editor.typeText("Clothes")
        bullet.tap()
        editor.typeText("\n")
        editor.typeText("Warm layers")
        attach(name: "01-flat-list")

        indent.tap()
        XCTAssertEqual(
            editor.value as? String, "- Clothes\n  - Warm layers",
            "Indent did not nest the second bullet"
        )
        attach(name: "02-indented")

        // And back out again, so the level is a place you can leave.
        outdent.tap()
        XCTAssertEqual(editor.value as? String, "- Clothes\n- Warm layers")
    }

    private func attach(name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
