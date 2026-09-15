import Foundation

/// The eight numbers on the review screen, before anything is written (#544).
///
/// ### Why this is a value type and not `@State` on the sheet
///
/// It answers one question that is genuinely hard and that the view cannot be
/// trusted with: **which of these eight did the user decide, and which did the
/// derivation?** A later re-derivation has to refresh the seven it may refresh
/// and leave the one the user chose alone, and getting that wrong is invisible
/// — the number simply changes back one day and nobody can say why.
///
/// So hand-edited is COMPUTED, never a flag someone remembers to set:
///
/// - A nutrient the last derivation proposed a figure for is hand-edited when
///   the field no longer holds that figure.
/// - A nutrient with no proposal (the form was opened on a stored record and
///   nothing was re-derived) is hand-edited when it was already flagged in
///   storage, or when the field no longer holds what it opened with.
///
/// Typing a suggestion back in therefore clears the flag, which is correct: the
/// derivation and the user now agree, and there is nothing left to protect.
struct MealTargetDraft: Equatable, Sendable {

    /// What the eight fields hold right now.
    private(set) var values: MealNutrients

    /// What the last derivation proposed, per nutrient. Empty until one runs.
    /// Kept separately from `values` so the review screen can say what it
    /// would have suggested beside a figure the user overrode.
    private(set) var suggested: [Nutrient: Double]

    /// What the fields held when the sheet opened.
    private let initial: MealNutrients

    /// The flags the stored record carried in. Only consulted for a nutrient
    /// the current session has no proposal for.
    private let storedHandEdited: Set<Nutrient>

    /// The paragraph shown under the eight. Replaced by each derivation, and
    /// editable by nobody: it explains numbers, and a rationale the user can
    /// rewrite stops being evidence of anything.
    private(set) var rationale: String

    // MARK: - Construction

    /// A blank draft, or one pre-filled from the record already in force.
    init(stored: MealTargets?) {
        let existing = stored?.targets ?? .zero
        values = existing
        initial = existing
        suggested = [:]
        storedHandEdited = stored?.handEdited ?? []
        rationale = stored?.rationale ?? ""
    }

    /// Explicit init, for tests and for reconstructing a draft mid-flight.
    init(
        values: MealNutrients = .zero,
        suggested: [Nutrient: Double] = [:],
        initial: MealNutrients = .zero,
        storedHandEdited: Set<Nutrient> = [],
        rationale: String = ""
    ) {
        self.values = values
        self.suggested = suggested
        self.initial = initial
        self.storedHandEdited = storedHandEdited
        self.rationale = rationale
    }

    // MARK: - Mutation

    /// Fold a derivation's answer in.
    ///
    /// Every nutrient the model returned a figure for gets that figure recorded
    /// as the suggestion. The FIELD only takes it when the user had not already
    /// overridden that nutrient — which is the whole contract: a re-derivation
    /// shows what it would have suggested without silently overwriting a
    /// deliberate choice.
    ///
    /// A nutrient the model omitted is left entirely alone, suggestion
    /// included. A missing figure is not a proposal of zero.
    mutating func apply(_ derived: DerivedMealTargets) {
        // Snapshot BEFORE `suggested` moves: `handEdited` reads it, so
        // computing it afterwards would ask the question against the answer.
        let alreadyEdited = handEdited

        for nutrient in Nutrient.allCases {
            guard let proposed = derived.value(for: nutrient), proposed >= 0 else { continue }
            let rounded = Self.rounded(proposed, for: nutrient)
            suggested[nutrient] = rounded
            if !alreadyEdited.contains(nutrient) {
                values[nutrient] = rounded
            }
        }

        let text = (derived.rationale ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { rationale = text }
    }

    /// The user typed a figure. Negatives are clamped rather than refused: a
    /// half-typed "-" must not put the field into an error state mid-keystroke.
    mutating func set(_ value: Double, for nutrient: Nutrient) {
        values[nutrient] = max(0, value)
    }

    // MARK: - Reading

    /// The nutrients the user decided, computed rather than remembered. This is
    /// what `MealService.saveTargets(handEdited:)` is given.
    var handEdited: Set<Nutrient> {
        Set(Nutrient.allCases.filter { nutrient in
            if let proposal = suggested[nutrient] {
                return !Self.same(values[nutrient], proposal)
            }
            return storedHandEdited.contains(nutrient)
                || !Self.same(values[nutrient], initial[nutrient])
        })
    }

    /// What the derivation proposed for this nutrient, when the field no longer
    /// holds it. Nil when nothing was proposed or when the two agree, so the
    /// review screen can show the line only where it says something.
    func overriddenSuggestion(for nutrient: Nutrient) -> Double? {
        guard let proposal = suggested[nutrient] else { return nil }
        return Self.same(values[nutrient], proposal) ? nil : proposal
    }

    /// True once there is something worth storing. Saving eight zeroes would
    /// write a record every reader treats as "targets exist", and then every
    /// bar would read against zero.
    var hasAnyTarget: Bool {
        Nutrient.allCases.contains { values[$0] > 0 }
    }

    /// True once a derivation has answered. The review block only exists after
    /// this, and on a stored record it is true from the start because the
    /// stored numbers ARE a past derivation's answer.
    var isReviewable: Bool {
        !suggested.isEmpty || hasAnyTarget
    }

    // MARK: - Arithmetic

    /// Two figures the user cannot tell apart in a whole-number field.
    ///
    /// The fields are whole numbers, so anything under half a unit is the same
    /// figure typed twice. Without the tolerance a derivation returning 137.4
    /// and a field reading 137 would flag protein as hand-edited on a screen
    /// nobody had touched.
    static func same(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    /// Round a proposed figure to the precision its field claims.
    ///
    /// Calories to the nearest 10, everything else to the unit, for the reason
    /// `MealFormat` rounds the same way: a target of 2,147 kcal claims the
    /// derivation could tell it from 2,150, and it cannot.
    static func rounded(_ value: Double, for nutrient: Nutrient) -> Double {
        switch nutrient {
        case .calories: return (value / 10).rounded() * 10
        default:        return value.rounded()
        }
    }
}
