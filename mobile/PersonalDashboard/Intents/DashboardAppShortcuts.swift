import AppIntents

/// Registers our App Intents with iOS so they appear automatically in:
///   - the Shortcuts app under "Deks"
///   - the Action Button picker (Settings -> Action Button -> Shortcut)
///   - Spotlight / Siri voice triggers via the listed phrases
///
/// The intended runtime path is a user-built 4-step Shortcut:
///   1. Start Capture Indicator       (preflight — paints the Dynamic Island
///                                      with our animated three-line motif so
///                                      iOS doesn't show its default AppIcon
///                                      thumbnail during Dictate Text)
///   2. Dictate Text (after short pause)
///   3. Capture to Deks (input = Dictated Text)
///   4. Show Notification (text = Result of the previous step)
///
/// Step 1 is optional — if the user skips it, step 3 still spawns the
/// Live Activity (the controller is idempotent), they just won't see it
/// during the Dictate Text window.
///
/// Bound to the Action Button (or back-tap, or a Lock Screen control)
/// it gives us a one-press voice capture without opening the app.
struct DashboardAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToDashboardIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Add to \(.applicationName)",
                "Quick capture in \(.applicationName)"
            ],
            shortTitle: "Capture",
            systemImageName: "mic.circle.fill"
        )
        AppShortcut(
            intent: StartCaptureLiveActivityIntent(),
            phrases: [
                "Start \(.applicationName) capture indicator",
                "Show \(.applicationName) capture island"
            ],
            shortTitle: "Start Capture Indicator",
            systemImageName: "waveform"
        )
    }
}
