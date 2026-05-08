import Foundation
import ActivityKit
import os.log

/// Singleton wrapper around `Activity<CaptureActivityAttributes>` so the
/// preflight intent (`StartCaptureLiveActivityIntent`) and the main intent
/// (`CaptureToDashboardIntent`) can target the SAME activity.
///
/// Why a shared singleton instead of intent-scoped instances:
///   - The user wires two App Intents into a single Shortcut: the preflight
///     intent kicks off the activity BEFORE Dictate Text takes over the
///     screen, then Dictate Text runs (iOS owns the island during this),
///     then the main intent runs the AI pipeline and updates the existing
///     activity. Both intents run inside the same app process when
///     `openAppWhenRun: false`, so they share this controller's state.
///   - If the controller were per-intent, the main intent would never see
///     the activity the preflight intent started, and we'd spawn a fresh
///     duplicate every time. The activity id would change mid-flow and the
///     user would see the system glitch the island state.
///
/// Why an actor:
///   - Two App Intents firing back-to-back can race on `currentActivity`.
///     Actor isolation serialises start / update / end so we never end up
///     with two live activities at once.
///
/// Why we keep `Activity.activities` lookup as a fallback:
///   - Defensive: if the system kept an activity alive across a process
///     restart (rare for App Intents but possible), we want the next call
///     to find it instead of orphaning it and starting another.
actor CaptureLiveActivityController {
    /// The shared instance both intents target.
    static let shared = CaptureLiveActivityController()

    private var activity: Activity<CaptureActivityAttributes>?

    private static let log = Logger(
        subsystem: "com.akshaysharma.personaldashboard.capture",
        category: "liveactivity"
    )

    /// Starts the activity in `.processing`. Idempotent — if a non-terminal
    /// activity already exists (because the preflight intent fired, or a
    /// previous run hasn't fully dismissed), this no-ops instead of
    /// spawning a duplicate.
    func start() async {
        // Reattach to any existing live activity in case the controller
        // singleton lost its reference but the system kept the activity
        // alive (process restart, etc.).
        if activity == nil {
            activity = Activity<CaptureActivityAttributes>.activities.first { existing in
                existing.activityState == .active || existing.activityState == .stale
            }
            if let reattached = activity {
                Self.log.info("reattached to existing activity id=\(reattached.id, privacy: .public)")
            }
        }

        // If we have a non-terminal activity already, no-op. The preflight
        // intent firing twice (or preflight + main both calling start) must
        // never end up with two activities pinned to the island.
        if let existing = activity, existing.activityState != .ended && existing.activityState != .dismissed {
            Self.log.info("start() no-op, existing activity id=\(existing.id, privacy: .public) state=\(String(describing: existing.activityState), privacy: .public)")
            return
        }

        // Guard against the user disabling Live Activities at the system
        // level. Without this check, `request(...)` throws every time.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.info("start() skipped, areActivitiesEnabled=false")
            return
        }

        let attributes = CaptureActivityAttributes()
        let initialState = CaptureActivityAttributes.State.processing
        do {
            // `staleDate` keeps the system from leaving a zombie activity
            // pinned to the island if the App Intent is killed mid-run.
            // 30 s is comfortably above CaptureService.timeoutSeconds (22)
            // PLUS the preflight + Dictate Text window before the main
            // intent even starts.
            let content = ActivityContent(
                state: initialState,
                staleDate: Date().addingTimeInterval(60)
            )
            let started = try Activity<CaptureActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activity = started
            Self.log.info("start() activity id=\(started.id, privacy: .public)")
        } catch {
            // Falling through silently is intentional — the pipeline
            // outcome is the source of truth for the user-facing dialog.
            Self.log.error("start() failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
        }
    }

    /// Update to a new state without dismissing. Used between phases on
    /// long captures (today only `.processing`, but the surface is here
    /// if we ever want to flip statusText mid-run).
    func update(state: CaptureActivityAttributes.State) async {
        guard let activity else {
            Self.log.info("update() no-op, no activity")
            return
        }
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(30)
        )
        await activity.update(content)
        Self.log.info("update() activity id=\(activity.id, privacy: .public) phase=\(state.phase.rawValue, privacy: .public)")
    }

    /// Settles into the final state and schedules dismissal.
    /// `linger` controls how long the user can read the final state
    /// before iOS clears the island.
    func end(state: CaptureActivityAttributes.State, linger: TimeInterval = 4.0) async {
        guard let activity else {
            Self.log.info("end() no-op, no activity")
            return
        }
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(linger + 5)
        )
        await activity.end(content, dismissalPolicy: .after(.now + linger))
        Self.log.info("end() activity id=\(activity.id, privacy: .public) phase=\(state.phase.rawValue, privacy: .public) linger=\(linger, privacy: .public)s")
        self.activity = nil
    }
}
