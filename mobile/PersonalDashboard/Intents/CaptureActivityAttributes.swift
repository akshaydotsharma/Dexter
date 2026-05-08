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

        public init(phase: Phase, statusText: String, startedAt: Date = Date()) {
            self.phase = phase
            self.statusText = statusText
            self.startedAt = startedAt
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
    static var processing: Self {
        .init(phase: .processing, statusText: "Capturing")
    }

    static func complete(summary: String) -> Self {
        .init(phase: .complete, statusText: summary)
    }

    static func failed(message: String) -> Self {
        .init(phase: .failed, statusText: message)
    }
}
