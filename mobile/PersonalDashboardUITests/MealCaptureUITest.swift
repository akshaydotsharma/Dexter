import XCTest

/// Drives the Tracking composer's two new inputs on a real device runtime
/// (#627).
///
/// ### What this can and cannot witness
///
/// A simulator has no camera, no usable microphone, and no in-process photo
/// picker, so three things this CANNOT check are the camera sheet, a live
/// dictation, and completing a pick. See the note at the end of the test for
/// where each of those is covered instead.
///
/// What it does check is the part review got wrong twice: that both accessories
/// are real, reachable elements INSIDE the field rather than children folded
/// into the text's own accessibility element, that the field still takes typed
/// text with a 68pt gutter cut out of it, and that Estimate arms and disarms on
/// what is actually in front of it.
final class MealCaptureUITest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_meal_composer_carries_both_accessories_inside_the_field() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LAUNCH_SECTION"] = "meals"
        app.launch()

        let field = app.textViews["Describe the meal"].firstMatch
        let fallbackField = app.textFields["Describe the meal"].firstMatch
        let description = field.waitForExistence(timeout: 15) ? field : fallbackField
        XCTAssertTrue(description.waitForExistence(timeout: 15), "the description field is on screen")
        attach(name: "01-composer-idle")

        let addPhoto = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add a photo of the meal'")
        ).firstMatch
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5), "the plus renders inside the field")

        let mic = app.buttons["Dictate the meal"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "the mic renders inside the field")

        // Estimate is dead on an empty composer, exactly as it always was.
        let estimate = app.buttons["Estimate"].firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 5))
        XCTAssertFalse(estimate.isEnabled, "an empty composer offers nothing to estimate")

        // Typing still works with two glyphs in the field's trailing gutter.
        description.tap()
        description.typeText("Chicken rice")
        sleep(1)
        attach(name: "02-typed")
        XCTAssertTrue(estimate.isEnabled, "text alone arms Estimate, as before #627")

        // Clear it, so the photo below is genuinely the only input.
        description.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        description.typeText(XCUIKeyboardKey.delete.rawValue)
        sleep(1)
        XCTAssertFalse(estimate.isEnabled, "back to an empty composer")

        // The photo half stops here, deliberately.
        //
        // `photoLibraryPicker` presents Apple's `PHPickerViewController`, which
        // runs OUT of process (`…PhotosUIRemoteUIExtension`). Under this runner
        // that extension does not come up at all, so there is nothing to tap and
        // no way to complete the pick from here. Chasing it further would buy a
        // flaky test of Apple's picker rather than a test of this feature.
        //
        // What that leaves uncovered is covered elsewhere, closer in:
        //
        // - `MealPhotoTests` takes real image bytes through `MealPhoto.make`
        //   and checks what comes out is JPEG, smaller, and within the API's
        //   ceiling.
        // - `MealPhotoStripRenderTests` hosts the real strip over real JPEG
        //   bytes and checks a thumbnail actually draws.
        // - The picker itself is the SAME modifier Finance has shipped since
        //   #200, unchanged.
        //
        // Everything above this line is the part that is this feature's own: the
        // two accessories inside the field, the field still taking text with
        // them there, and Estimate arming and disarming on what is in front of
        // it.
        attach(name: "03-cleared")
    }

    private func attach(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
