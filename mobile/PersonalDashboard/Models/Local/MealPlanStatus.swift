import Foundation

/// Where a planned meal got to (#599).
///
/// Three states, not two. Skip on its own would be a state machine you can only
/// push in the negative direction: a plan you followed and a plan you have not
/// reached yet would look identical, so the day panel could never say how much
/// of the day is still ahead of you.
///
/// ### `eaten` DOES write a meal now (#612)
///
/// It did not until #612, and the reason it did not was sound as far as it
/// went: the plan records intent and the log records nutrition, so collapsing
/// them would put a meal in the day's totals that nobody estimated.
///
/// What that missed is that somebody DID estimate it. A block carries the eight
/// totals, the per-dish breakdown, the day and the meal type, all worked out
/// when it was written. Re-typing it into the composer buys a second estimate
/// of the same dish, at the price of a call, a few seconds, and two sets of
/// numbers for one dinner that can disagree with each other.
///
/// So ticking a block copies it into a `LocalMeal` and records which one on
/// `LocalMealPlanEntry.loggedMealUUID`. The two tables stay separate and the
/// block stays where it is — see `MealPlanService.logAsMeal`. Unticking deletes
/// the meal the block itself wrote, and nothing else.
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
