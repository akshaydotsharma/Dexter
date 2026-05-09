import AppIntents

/// Registers our App Intents with iOS so they appear automatically in:
///   - the Shortcuts app under "Dexter"
///   - the Action Button picker (Settings -> Action Button -> Shortcut)
///   - Spotlight / Siri voice triggers via the listed phrases
///
/// The intended runtime path is a user-built 3-step Shortcut:
///   1. Dictate Text (after short pause)
///   2. Capture to Dexter (input = Dictated Text)
///   3. Show Notification (text = Result of the previous step)
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
    }
}
