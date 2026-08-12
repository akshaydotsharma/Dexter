import XCTest

/// The note editor must not lose writing when the app dies (#455).
///
/// The bug in one sentence: the only save was `persistIfChanged()` on leaving
/// the view, and leaving the view is exactly what a crash, a background memory
/// reclaim, or a swipe-away from the app switcher never does.
///
/// This is a UI test rather than a logic test because the defect lives in when
/// the write happens, not in what is written. Nothing below reaches into the
/// store: it types into a note, kills the app WITHOUT closing the note, and
/// then asks the relaunched app whether the text is still there. That is the
/// same question the user asked.
final class NoteAutosaveUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_typed_text_survives_the_app_dying_before_the_note_is_closed() throws {
        // Unique per run, and it has to be: the simulator keeps its store
        // between runs, so a fixed marker matches the note an EARLIER run left
        // behind and the test passes without saving anything this time.
        let marker = "Autosave check 455 \(UUID().uuidString.prefix(8))"

        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "notes"
        // Open a note straight into the editor with the keyboard up, rather
        // than tapping the pencil (#395's hook).
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
        editor.typeText(marker)
        attach(name: "01-typed-in-editor")

        // Long enough for the idle debounce, and well short of anything that
        // would let a passing result come from a timeout rather than a save.
        sleep(4)

        // The whole point: kill it with the note still open. No Done, no back.
        //
        // Background it FIRST, then kill. Terminating a frontmost app tears the
        // scene down gracefully and `.onDisappear` fires, so that path passes
        // even with the defect present — verified by running this test against
        // the unfixed editor. Backgrounding is what really happens: the app is
        // already in the background by the time you swipe it away in the app
        // switcher, or by the time iOS reclaims its memory, and neither one
        // ever unmounts the view.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()

        app.launchEnvironment["LAUNCH_NOTE_MODE"] = nil
        app.launch()

        // The notes index draws a snippet of each note's body, so the row
        // itself is the evidence.
        let survived = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", marker)
        ).firstMatch
        XCTAssertTrue(
            survived.waitForExistence(timeout: 15),
            "The note was lost: text typed before the app died is not in the notes list"
        )
        attach(name: "02-after-relaunch")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
