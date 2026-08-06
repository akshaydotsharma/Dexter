import Foundation

/// What you are doing about a vision block (#446).
///
/// Deliberately NOT the obvious single enum of "in progress / ongoing / has a
/// deadline / done". "Has a deadline" is not a state a piece of work is in, it
/// is a fact about the calendar, and folding it in here would force a block that
/// is both Active and due Friday to pick one — so it would pick the wrong one.
/// Urgency is therefore derived separately from the block's tasks and rendered
/// in a different region of the card entirely (see `VisionUrgency`).
///
/// State is manual and set by the user; urgency is computed and cannot go stale.
/// A block says both things at once without either overwriting the other.
///
/// Backed by `String` rather than `Int` so the value stored on
/// `LocalVisionBlock.state` is legible in a sqlite dump during QA, and so
/// inserting a state later cannot renumber the existing ones.
enum BlockState: String, CaseIterable, Identifiable, Sendable {
    /// Parked. Real, not started.
    case idea
    /// Being worked on now.
    case active
    /// Continuous, no finish line. Health, reading, admin.
    case ongoing
    /// Blocked on someone or something else.
    case waiting
    /// Finished. Recedes, does not disappear.
    case done

    var id: String { rawValue }

    /// The default for a newly created block. Idea rather than Active: a block
    /// you have only just named is by definition not yet being worked on, and
    /// starting everything at Active would make the loudest state meaningless.
    static let `default`: BlockState = .idea

    var displayName: String {
        switch self {
        case .idea:    return "Idea"
        case .active:  return "Active"
        case .ongoing: return "Ongoing"
        case .waiting: return "Waiting"
        case .done:    return "Done"
        }
    }

    /// The 10pt header glyph. Five distinct SHAPES, which is what carries state
    /// once colour is taken away: Idea and Done share `Tokens.muted`, so hue
    /// alone can never tell them apart and is not asked to.
    var glyph: String {
        switch self {
        case .idea:    return "lightbulb"
        case .active:  return "circle.fill"
        case .ongoing: return "infinity"
        case .waiting: return "hourglass"
        case .done:    return "checkmark"
        }
    }

    /// Uppercase eyebrow shown beside the glyph at the large tier, where there
    /// is room for state to be written out rather than only drawn.
    var eyebrow: String { displayName.uppercased() }
}
