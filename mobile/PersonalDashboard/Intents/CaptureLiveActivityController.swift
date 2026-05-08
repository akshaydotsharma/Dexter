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
///
/// Why a phase ticker:
///   - iOS does NOT redraw `TimelineView(.animation)` inside the *compact*
///     Dynamic Island slot — compact is rendered as a static snapshot. The
///     only mechanism we have to animate the compact pill is to mutate the
///     activity state via `activity.update(...)`, which forces a redraw.
///     The ticker bumps `state.animationPhase` every ~500 ms while the
///     activity is in `.processing`, and the compact view recomputes the
///     three-line widths from the new phase.
///   - Best-effort. If iOS throttles `activity.update` we DON'T retry
///     harder; the user gets whatever cadence iOS allows.
actor CaptureLiveActivityController {
    /// The shared instance both intents target.
    static let shared = CaptureLiveActivityController()

    private var activity: Activity<CaptureActivityAttributes>?
    /// Background task that ticks the activity's `animationPhase` so the
    /// compact view actually animates. Only runs while `.processing`.
    private var tickerTask: Task<Void, Never>?
    /// Latest known phase value. The ticker reads + bumps this so the
    /// compact view redraws against a moving sine wave.
    private var animationPhase: Double = 0

    /// Tick cadence. ~500 ms is a balance: faster looks smoother but iOS
    /// throttles aggressively; slower looks like a slideshow. Tunable.
    private static let tickInterval: TimeInterval = 0.5
    /// How much we advance the phase each tick. 0.5 rad/tick at 0.5 s/tick
    /// works out to a full sine cycle every ~12.6 s, which reads as a calm
    /// drift rather than a frantic loader.
    private static let phaseStep: Double = 0.5

    private static let log = Logger(
        subsystem: "com.akshaysharma.personaldashboard.capture",
        category: "liveactivity"
    )

    /// Starts the activity in `.processing`. Idempotent — if a non-terminal
    /// activity already exists (because the preflight intent fired, or a
    /// previous run hasn't fully dismissed), this no-ops instead of
    /// spawning a duplicate.
    func start() async {
        // Cancel any previous ticker before we spin up a fresh activity.
        // Idempotency: re-firing start() must not stack tickers.
        cancelTicker()

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

        // If we have a non-terminal activity already, no-op on the spawn
        // path BUT still kick off the ticker — the preflight intent may
        // have started the activity before this call and we want the
        // compact view animating regardless of which path got us here.
        if let existing = activity, existing.activityState != .ended && existing.activityState != .dismissed {
            Self.log.info("start() reusing existing activity id=\(existing.id, privacy: .public) state=\(String(describing: existing.activityState), privacy: .public)")
            startTicker()
            return
        }

        // Guard against the user disabling Live Activities at the system
        // level. Without this check, `request(...)` throws every time.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.info("start() skipped, areActivitiesEnabled=false")
            return
        }

        let attributes = CaptureActivityAttributes()
        animationPhase = 0
        let initialState = CaptureActivityAttributes.State.processing(animationPhase: animationPhase)
        do {
            // `staleDate` keeps the system from leaving a zombie activity
            // pinned to the island if the App Intent is killed mid-run.
            // 60 s is comfortably above CaptureService.timeoutSeconds (22)
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
            startTicker()
        } catch {
            // Falling through silently is intentional — the pipeline
            // outcome is the source of truth for the user-facing dialog.
            Self.log.error("start() failed: \(error.localizedDescription, privacy: .public)")
            activity = nil
        }
    }

    /// Update to a new state without dismissing. Used between phases on
    /// long captures (today only `.processing`, but the surface is here
    /// if we ever want to flip statusText mid-run). Stops the ticker —
    /// any non-processing state is terminal animation-wise.
    func update(state: CaptureActivityAttributes.State) async {
        guard let activity else {
            Self.log.info("update() no-op, no activity")
            return
        }
        if state.phase != .processing {
            cancelTicker()
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
        // End is always terminal — kill the ticker before we touch the
        // activity so a stray tick can't race the .ended transition.
        cancelTicker()
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

    // MARK: - Phase ticker

    /// Spins up the background tick loop. Cancels any existing loop first
    /// so re-entrant calls don't stack.
    ///
    /// `Task.detached` — we don't want to inherit the cancellation tree of
    /// whatever called `start()`. App Intents have a short
    /// `perform()` lifecycle; if `perform()` returns and that cancels its
    /// child tasks, the ticker would die mid-capture and the compact view
    /// would freeze.
    private func startTicker() {
        cancelTicker()
        let interval = Self.tickInterval
        let step = Self.phaseStep
        tickerTask = Task.detached { [weak self] in
            while true {
                // Sleep first so the initial state we already pushed in
                // start() gets to render before the first phase bump.
                let nanos = UInt64(interval * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanos)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let self else { return }
                await self.tick(advanceBy: step)
            }
        }
    }

    /// One animation step: bump `animationPhase`, push a fresh state to
    /// the activity, log on failure but don't retry. iOS may throttle and
    /// silently drop updates — that's fine, we just lose a frame.
    private func tick(advanceBy step: Double) async {
        guard let activity else { return }
        // Only animate while processing. If the activity flipped to a
        // settled phase, stop ticking and let `update`/`end` take over.
        // `content.state` is the iOS 16.2+/17 accessor (the older
        // `contentState` is deprecated on iOS 17).
        let snapshot = activity.content.state
        guard snapshot.phase == .processing else {
            cancelTicker()
            return
        }
        animationPhase += step
        let nextState = CaptureActivityAttributes.State(
            phase: .processing,
            statusText: snapshot.statusText,
            startedAt: snapshot.startedAt,
            animationPhase: animationPhase
        )
        let content = ActivityContent(
            state: nextState,
            staleDate: Date().addingTimeInterval(30)
        )
        await activity.update(content)
    }

    /// Idempotent ticker shutdown. Safe to call from any path.
    private func cancelTicker() {
        tickerTask?.cancel()
        tickerTask = nil
    }
}
