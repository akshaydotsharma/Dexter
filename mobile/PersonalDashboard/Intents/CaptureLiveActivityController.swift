import Foundation
import ActivityKit

/// Tiny wrapper around `Activity<CaptureActivityAttributes>` so the App
/// Intent body stays readable.
///
/// Why a wrapper:
///   - `Activity.request(...)` throws and may also fail when the user has
///     Live Activities turned off in Settings. The Intent must still
///     run in that case, so all calls swallow errors instead of
///     propagating them. The pipeline outcome is the source of truth for
///     the user-facing dialog; the Live Activity is a visual nicety.
///   - We hold onto the `Activity` reference so `update` and `end` target
///     the right instance instead of needing to look it up by id.
///   - `end(...)` is fire-and-forget but uses an `.after` dismissal so
///     the user gets a beat to see the final state before it disappears.
///
/// Lifecycle is intent-scoped: one controller per `perform()` call.
actor CaptureLiveActivityController {
    private var activity: Activity<CaptureActivityAttributes>?

    /// Starts the activity in `.processing`. Safe to call when Live
    /// Activities are disabled — silently no-ops in that case.
    func start() async {
        // Guard against the user disabling Live Activities at the system
        // level. Without this check, `request(...)` throws every time
        // and we'd burn cycles re-checking on every capture.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        let attributes = CaptureActivityAttributes()
        let initialState = CaptureActivityAttributes.State.processing
        do {
            // `staleDate` keeps the system from leaving a zombie activity
            // pinned to the island if the App Intent is killed mid-run.
            // 30 s is comfortably above CaptureService.timeoutSeconds (22).
            let content = ActivityContent(
                state: initialState,
                staleDate: Date().addingTimeInterval(30)
            )
            activity = try Activity<CaptureActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Falling through silently is intentional — see comment above.
            activity = nil
        }
    }

    /// Update to a new state without dismissing. Used between phases on
    /// long captures (today only `.processing`, but the surface is here
    /// if we ever want to flip statusText mid-run).
    func update(state: CaptureActivityAttributes.State) async {
        guard let activity else { return }
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(30)
        )
        await activity.update(content)
    }

    /// Settles into the final state and schedules dismissal.
    /// `linger` controls how long the user can read the final state
    /// before iOS clears the island.
    func end(state: CaptureActivityAttributes.State, linger: TimeInterval = 2.0) async {
        guard let activity else { return }
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(linger + 5)
        )
        await activity.end(content, dismissalPolicy: .after(.now + linger))
        self.activity = nil
    }
}
