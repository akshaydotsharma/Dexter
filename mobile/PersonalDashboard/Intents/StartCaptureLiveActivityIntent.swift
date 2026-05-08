import AppIntents
import Foundation

/// Preflight App Intent the user adds to their Capture shortcut **before**
/// the Dictate Text step. Starts the Capture Live Activity so the Dynamic
/// Island shows our animated three-line motif (instead of the iOS-default
/// AppIcon thumbnail) while Dictate Text takes over the screen.
///
/// Why this exists:
///   - When iOS runs a Shortcut that contains Dictate Text, the system
///     plants its own "Shortcut running" indicator in the Dynamic Island
///     using the host app's icon. There's no API to suppress that — the
///     only way to replace it is to have a Live Activity already running
///     before Dictate Text starts. Live Activities outrank the system
///     indicator in the island.
///   - The main `CaptureToDashboardIntent` only runs AFTER Dictate Text
///     finishes, which is too late: by then the user has already seen the
///     unwanted AppIcon-thumbnail treatment for the entire dictation
///     window. This preflight intent fills the gap.
///
/// Wiring:
///   The user opens their "Capture to Deks" shortcut, drops this action
///   ("Start Capture Indicator") at the very top, leaves Dictate Text and
///   Capture to Deks in place after it. From then on the island shows the
///   animated lines from the moment they hit the Action Button until the
///   on-device pipeline finishes (and then for `linger` seconds on the
///   final state).
///
/// Performance note:
///   `perform()` is intentionally minimal — every millisecond added here
///   delays Dictate Text. The controller's `start()` is O(1) when the
///   activity is already running (idempotent) and O(1) on the spawn path.
struct StartCaptureLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Capture Indicator"
    static var description = IntentDescription(
        "Start the Dynamic Island indicator before Dictate Text. Add this just before Dictate Text in your Capture shortcut."
    )

    /// Must NOT open the app — that would foreground Deks and tank the
    /// dictation flow, defeating the whole point of the preflight step.
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Start Deks capture indicator")
    }

    func perform() async throws -> some IntentResult {
        // Idempotent: if the user accidentally chains this intent twice,
        // the second call no-ops. If a previous run hasn't fully dismissed,
        // the controller reattaches to that activity instead of spawning
        // a duplicate.
        await CaptureLiveActivityController.shared.start()
        return .result()
    }
}
