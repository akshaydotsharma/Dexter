import Foundation

/// Where a planned meal got to (#599).
///
/// Three states, not two. Skip on its own would be a state machine you can only
/// push in the negative direction: a plan you followed and a plan you have not
/// reached yet would look identical, so the day panel could never say how much
/// of the day is still ahead of you.
///
/// ### Why `eaten` is not "logged"
///
/// Ticking a block says you ate what you planned. It does NOT write a
/// `LocalMeal`, and it must not be read as if it had. The plan records intent
/// and the log records nutrition, and the two answer different questions: "did
/// I do what I said" against "what did that cost me". Collapsing them would put
/// a meal in the day's totals that nobody estimated.
///
/// Logging a planned meal for real is the composer's job on the Tracking tab,
/// and it stays that way.
enum MealPlanStatus: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// Written down, not yet resolved. Every block starts here.
    case planned
    /// The user says they ate it.
    case eaten
    /// The user says they did not, and does not intend to.
    case skipped

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .eaten:   return "Eaten"
        case .skipped: return "Skipped"
        }
    }

    /// SF Symbol for the block's state control.
    var sfSymbol: String {
        switch self {
        case .planned: return "circle"
        case .eaten:   return "checkmark.circle.fill"
        case .skipped: return "slash.circle"
        }
    }

    /// True when this block still counts towards what the day intends to eat.
    ///
    /// The ONE test the totals, the verdicts and the ingredient roll-up all
    /// read, so none of the three can decide on its own that a skipped block
    /// half counts. A skipped block is a meal that is not happening: its
    /// calories are not coming and its ingredients are not needed.
    ///
    /// An eaten block still counts. It was the plan and it happened.
    var countsTowardsPlan: Bool {
        self != .skipped
    }
}
