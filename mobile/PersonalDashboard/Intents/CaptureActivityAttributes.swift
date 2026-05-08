import Foundation
import ActivityKit

/// Shared between the main app target and the `DeksWidgets` extension.
///
/// Backs the Live Activity that takes over the Dynamic Island while the
/// Capture-to-Deks App Intent is processing dictated input. The activity
/// starts after the Dictate Text step finishes and ends shortly after the
/// pipeline reports outcome (success or failure). The system Dictate Text
/// sheet is untouched — only the Dynamic Island region we're claiming.
///
/// `ContentState` carries the live, mutable bits. `Phase` is the discrete
/// state machine we render against: while it's `.processing`, the icon
/// lines dance; on `.complete`/`.failed`, the lines settle and a status
/// pip flips to the appropriate accent before the activity dismisses.
struct CaptureActivityAttributes: ActivityAttributes {
    public typealias ContentState = State

    /// Static metadata fixed when the activity starts. Empty today (the
    /// flow doesn't need any per-instance config), but the type is here
    /// so we can extend later (e.g. to surface a session id) without
    /// breaking on-device clients that have older activities pinned.
    public init() {}

    public struct State: Codable, Hashable {
        public var phase: Phase
        public var statusText: String
        public var startedAt: Date
        /// Animation phase used by the compact view to oscillate the
        /// three logo lines. iOS does NOT redraw `TimelineView(.animation)`
        /// in the compact Dynamic Island slot — the only mechanism we have
        /// for compact-view motion is `activity.update(...)`, which forces
        /// a redraw on every state change. The controller ticks this
        /// field every ~500 ms so the compact pill animates while
        /// processing. Settled phases keep this at the last value (no
        /// further updates fire after `.complete` / `.failed`).
        public var animationPhase: Double

        public init(
            phase: Phase,
            statusText: String,
            startedAt: Date = Date(),
            animationPhase: Double = 0
        ) {
            self.phase = phase
            self.statusText = statusText
            self.startedAt = startedAt
            self.animationPhase = animationPhase
        }
    }

    public enum Phase: String, Codable, Hashable {
        case processing
        case complete
        case failed
    }
}

extension CaptureActivityAttributes.State {
    /// Convenience factory for the initial "we just kicked off the
    /// pipeline" state. Keeps the call site in `CaptureToDashboardIntent`
    /// readable without leaking literal strings into the intent file.
    /// Defaults `animationPhase` to 0; the controller's ticker takes
    /// over from there.
    static func processing(animationPhase: Double = 0) -> Self {
        .init(phase: .processing, statusText: "Capturing", animationPhase: animationPhase)
    }

    static func complete(summary: String, animationPhase: Double = 0) -> Self {
        .init(phase: .complete, statusText: summary, animationPhase: animationPhase)
    }

    static func failed(message: String, animationPhase: Double = 0) -> Self {
        .init(phase: .failed, statusText: message, animationPhase: animationPhase)
    }
}
