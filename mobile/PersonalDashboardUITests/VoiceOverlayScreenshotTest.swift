import XCTest

/// Opens the full-screen voice overlay and captures it, so the waveform's
/// proportions can be reviewed on a real screen size instead of guessed at from
/// a browser prototype drawn in a differently-shaped frame (#429).
///
/// Not an assertion test. It exists because several rounds of size and colour
/// tuning were done without anyone looking at the rendered result, and the bars
/// ended up narrower and taller than the design they were meant to match.
///
/// Requires microphone and speech permission to be pre-granted on the
/// simulator, otherwise the system alert covers the surface:
///
///   xcrun simctl privacy booted grant microphone com.akshaysharma.personaldashboard
///   xcrun simctl privacy booted grant speech-recognition com.akshaysharma.personaldashboard
final class VoiceOverlayScreenshotTest: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_capture_voice_overlay() throws {
        let app = XCUIApplication()
        // In the app the overlay opens on a 0.6s long press of the chat nav
        // button, but XCUITest's synthetic `press(forDuration:)` resolves to the
        // button's `.onTapGesture` instead and simply navigates to Chat. The
        // launch argument is a DEBUG-only door to the same presentation.
        app.launchArguments += ["-uiTestShowVoiceOverlay", "-uiTestVoiceDemoLevels"]
        app.launch()

        // The mic / speech permission alerts belong to SpringBoard and sit on
        // top of the overlay. `simctl privacy grant` is refused on this runtime,
        // so dismiss them directly.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 4) {
                allow.tap()
                sleep(1)
            }
        }

        // Let the overlay settle and the waveform's timeline start ticking.
        sleep(4)
        attach(name: "voice-overlay")

        // A second frame a moment later, so the at-rest shimmer is visible as
        // motion between the two rather than as a single ambiguous still.
        sleep(1)
        attach(name: "voice-overlay-later")
    }

    private func attach(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
