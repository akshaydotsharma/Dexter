import SwiftUI

/// How one nutrient's day is going against its target (#543).
///
/// Three states rather than a percentage, because a bar already carries the
/// percentage and a verdict has to survive being read at a glance. The meaning
/// of each depends on `Nutrient.goalKind`: a floor wants to be reached, a
/// ceiling wants not to be, and a range wants to be landed in.
enum MealVerdict: Equatable, Sendable {
    /// Short of a floor, or below a range.
    case under
    /// Inside a range, at or above a floor, at or under a ceiling.
    case onTrack
    /// Past a ceiling, or above a range.
    case over

    var tint: Color {
        switch self {
        case .under:   return Tokens.warning
        case .onTrack: return Tokens.success
        case .over:    return Tokens.danger
        }
    }

    /// The word shown next to the bar. Kept to one word: the number beside it
    /// already says how far.
    var label: String {
        switch self {
        case .under:   return "Under"
        case .onTrack: return "On track"
        case .over:    return "Over"
        }
    }
}

extension Nutrient {

    /// Read a day's value against its target.
    ///
    /// The tolerance on a range is deliberately wide. Calories, carbs and fat
    /// are the three the estimate is least sure about — they carry the portion
    /// error — so a verdict that flipped at a one-percent miss would be
    /// reporting on the estimate rather than on the day.
    func verdict(value: Double, target: Double) -> MealVerdict? {
        guard target > 0 else { return nil }
        let ratio = value / target
        switch goalKind {
        case .floor:
            return ratio >= 1 ? .onTrack : .under
        case .ceiling:
            return ratio > 1 ? .over : .onTrack
        case .range:
            if ratio < 0.85 { return .under }
            if ratio > 1.10 { return .over }
            return .onTrack
        }
    }
}

/// One day of meals, totalled (#543).
///
/// ### What is left out of a total, and why
///
/// A suspect meal is excluded from every total and average. Its numbers are
/// known to be wrong — that is what suspect means — and a day total that quietly
/// folds in a provably wrong number is worse than one that says it is
/// incomplete, because nothing on screen would show which of the two it was.
///
/// A needs-detail meal is excluded for the opposite reason: it has no numbers at
/// all. Adding its zeros would not change the total, but counting it as a logged
/// meal would make "3 meals, 900 kcal" read as a light day rather than as a day
/// with a question outstanding.
///
/// Both stay visible, pinned at the top of the day.
struct MealDaySummary {
    /// Every meal on the day, in the order they were logged.
    let all: [LocalMeal]

    /// Meals whose numbers count.
    let counted: [LocalMeal]

    /// Meals held out of the totals: suspect, needing detail, or both.
    let excluded: [LocalMeal]

    /// Sum over `counted` only.
    let totals: MealNutrients

    /// Nothing at all was logged on this day.
    ///
    /// Distinct from a day whose meals all totalled very little. A blank day
    /// means the log was not kept; a low day means it was, and the difference
    /// is the whole value of keeping one.
    var isUnlogged: Bool { all.isEmpty }

    init(meals: [LocalMeal]) {
        all = meals
        var counted: [LocalMeal] = []
        var excluded: [LocalMeal] = []
        for meal in meals {
            if meal.isSuspect || meal.needsDetail {
                excluded.append(meal)
            } else {
                counted.append(meal)
            }
        }
        self.counted = counted
        self.excluded = excluded
        self.totals = counted.reduce(MealNutrients.zero) { $0 + $1.nutrients }
    }

    /// The day's meals in reading order: everything that needs attention first,
    /// then the rest grouped by meal type and chronological within it.
    ///
    /// Attention first because those rows are the only ones with an action
    /// attached. A suspect meal sitting in its meal-type group is a warning
    /// nobody scrolls to.
    func orderedRows(flaggedAsDuplicate: Set<String>) -> [LocalMeal] {
        let pinned = all.filter {
            $0.isSuspect || $0.needsDetail || flaggedAsDuplicate.contains($0.clientUUID)
        }
        let pinnedIDs = Set(pinned.map(\.clientUUID))
        let rest = all.filter { !pinnedIDs.contains($0.clientUUID) }
        let order: [MealType] = [.breakfast, .lunch, .dinner, .snack]
        let grouped = order.flatMap { type in
            rest.filter { $0.mealTypeEnum == type }
                .sorted { $0.loggedAt < $1.loggedAt }
        }
        return pinned.sorted { $0.loggedAt < $1.loggedAt } + grouped
    }

    /// The meal types present in `rest`, in serving order, for the group headers.
    static let typeOrder: [MealType] = [.breakfast, .lunch, .dinner, .snack]
}

/// Number formatting shared by every Meals surface (#543).
///
/// ### Rounding is a claim about precision
///
/// Calories round to the nearest 10 and macros to the gram. Not because those
/// are pretty numbers, but because they are the honest ones: an estimate
/// derived from "two eggs on toast" cannot distinguish 343 kcal from 347, and
/// printing 343 claims it can. False precision is the fastest way to stop
/// trusting a tool that is approximate by construction.
///
/// Typed totals are the exception and are printed as given — see
/// `MealSource.user`. A number the user knows is not an estimate.
enum MealFormat {

    /// Calories, to the nearest 10.
    static func calories(_ value: Double) -> String {
        let rounded = (value / 10).rounded() * 10
        return String(format: "%.0f", rounded)
    }

    /// Grams or milligrams, to the whole unit.
    static func grams(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    /// One nutrient's value with its unit, e.g. "72 g" or "1,900 mg".
    static func value(_ value: Double, for nutrient: Nutrient) -> String {
        switch nutrient {
        case .calories: return "\(calories(value)) kcal"
        default:        return "\(grams(value)) \(nutrient.unit)"
        }
    }

    /// A meal's confidence as the band it was stored from.
    static func confidenceBand(_ confidence: Double) -> String {
        switch confidence {
        case 1:          return "Exact"
        case 0.75...:    return "High confidence"
        case 0.45..<0.75: return "Medium confidence"
        default:         return "Low confidence"
        }
    }
}
