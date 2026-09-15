import Foundation

/// Biological sex, as the energy equations use it (#544).
///
/// In the form because Mifflin St Jeor carries a constant that differs by 166
/// kcal between the two for an otherwise identical body. Deriving without it
/// picks one of the two silently, and every verdict downstream is then wrong by
/// about that much every day. It is an input to a formula, which is why it is
/// this narrow and why the enum says nothing about identity.
///
/// Raw values are the strings `MealTargets.biologicalSex` stores and the
/// strings the prompt sends. They must not be renamed once rows exist.
enum BiologicalSex: String, CaseIterable, Identifiable, Sendable {
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .male:   return "Male"
        case .female: return "Female"
        }
    }
}

/// How much the body moves in a week (#544).
///
/// Five bands, because that is how many the activity multiplier in every
/// published energy equation has. A sixth would be a distinction the arithmetic
/// cannot express.
///
/// Raw values match the set `MealTargets.activityLevel` documents.
enum ActivityLevel: String, CaseIterable, Identifiable, Sendable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive = "very_active"

    var id: String { rawValue }

    /// The label on the option row.
    var displayName: String {
        switch self {
        case .sedentary:  return "Sedentary"
        case .light:      return "Lightly active"
        case .moderate:   return "Moderately active"
        case .active:     return "Very active"
        case .veryActive: return "Athlete"
        }
    }

    /// What the band means in a week, so the choice is made against something
    /// checkable rather than against a word that means five things to five
    /// people.
    var detail: String {
        switch self {
        case .sedentary:  return "Desk work, little deliberate exercise"
        case .light:      return "Light exercise one to three days a week"
        case .moderate:   return "Moderate exercise three to five days a week"
        case .active:     return "Hard exercise six or seven days a week"
        case .veryActive: return "Training twice a day, or a physical job on top of it"
        }
    }
}

/// What the targets are for (#544).
///
/// Four rather than the three `MealTargets` first listed: gaining muscle and
/// gaining weight want the same energy direction and very different protein, so
/// collapsing them loses the one number the distinction exists to change.
///
/// Raw values are stored in `MealTargets.goal`, which is a `String` column, so
/// the fourth costs no migration.
enum MealGoal: String, CaseIterable, Identifiable, Sendable {
    case lose
    case maintain
    case gainMuscle = "gain_muscle"
    case gain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lose:       return "Lose weight"
        case .maintain:   return "Maintain"
        case .gainMuscle: return "Gain muscle"
        case .gain:       return "Gain weight"
        }
    }
}

/// The six things a derivation is made from (#544).
///
/// Metric only. The app is Singapore-based and SGD-native, and an imperial
/// toggle is a second unit system, a second parser and a second rounding rule
/// for a user who does not exist.
///
/// Stored on `MealTargets` beside the eight numbers they produced, which is
/// what makes a re-derivation after a weight change one tap with the form
/// already filled in.
struct MealTargetInputs: Equatable, Sendable {
    var ageYears: Int
    var biologicalSex: BiologicalSex
    var heightCm: Double
    var weightKg: Double
    var activityLevel: ActivityLevel
    var goal: MealGoal

    init(
        ageYears: Int = 0,
        biologicalSex: BiologicalSex = .male,
        heightCm: Double = 0,
        weightKg: Double = 0,
        activityLevel: ActivityLevel = .moderate,
        goal: MealGoal = .maintain
    ) {
        self.ageYears = ageYears
        self.biologicalSex = biologicalSex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.activityLevel = activityLevel
        self.goal = goal
    }

    /// Read the six back off a stored record.
    ///
    /// An unrecognised stored string falls back to the form's own default
    /// rather than failing: the six are re-shown in a form the user is about to
    /// confirm, so a wrong default is visible and correctable, and refusing to
    /// open the form at all is not.
    init(stored: MealTargets) {
        self.init(
            ageYears: stored.ageYears,
            biologicalSex: BiologicalSex(rawValue: stored.biologicalSex) ?? .male,
            heightCm: stored.heightCm,
            weightKg: stored.weightKg,
            activityLevel: ActivityLevel(rawValue: stored.activityLevel) ?? .moderate,
            goal: MealGoal(rawValue: stored.goal) ?? .maintain
        )
    }

    /// Bounds a derivation can be made inside.
    ///
    /// Wide on purpose. These are not a health opinion; they are the range
    /// outside which the equations stop describing a person and a typo is the
    /// likelier explanation. The form refuses rather than sending a call that
    /// would return numbers nobody should eat to.
    static let ageRange = 12...100
    static let heightRange = 100.0...250.0
    static let weightRange = 25.0...300.0

    var isComplete: Bool {
        Self.ageRange.contains(ageYears)
            && Self.heightRange.contains(heightCm)
            && Self.weightRange.contains(weightKg)
    }

    /// What is wrong, for the line under the Derive button. Nil when the form
    /// is ready. One message rather than per-field errors: there are three
    /// numeric fields and naming the first bad one is enough to fix it.
    var problem: String? {
        if !Self.ageRange.contains(ageYears) {
            return "Age has to be between \(Self.ageRange.lowerBound) and \(Self.ageRange.upperBound)."
        }
        if !Self.heightRange.contains(heightCm) {
            return "Height has to be between \(Int(Self.heightRange.lowerBound)) and \(Int(Self.heightRange.upperBound)) cm."
        }
        if !Self.weightRange.contains(weightKg) {
            return "Weight has to be between \(Int(Self.weightRange.lowerBound)) and \(Int(Self.weightRange.upperBound)) kg."
        }
        return nil
    }
}
