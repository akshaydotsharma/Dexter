import Foundation

/// Which direction a target is good in (#542).
///
/// This is the whole reason `Nutrient` exists as a type rather than as eight
/// loose `Double` columns with eight loose labels. "Am I doing well on this"
/// has three different answers depending on the nutrient, and the answer is a
/// property of the nutrient itself, not of the screen showing it:
///
/// - `floor`: more is better up to the target, and past it is fine. Protein.
/// - `ceiling`: less is better, and past the target is the bad direction. Sugar.
/// - `range`: the target is the middle of a band, and both sides are wrong.
///   Calories.
///
/// Every bar colour, verdict line and callout in the feature reads
/// `Nutrient.goalKind` rather than re-deciding, so a view cannot paint a
/// protein bar red for being over.
enum NutrientGoalKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// Hit the target or beat it. Over is fine.
    case floor
    /// Stay at or under the target. Over is the failure.
    case ceiling
    /// Land near the target. Both far under and far over are wrong.
    case range
}

/// The eight tracked nutrients (#542).
///
/// A closed set on purpose. These are the eight an estimate can be made for
/// from a plain description of a meal with any honesty, and the eight a target
/// can be derived for from age, sex, height, weight, activity and goal. Adding
/// a ninth means adding a column to `LocalMeal`, a field to `MealTargets`, a
/// key to the item payload and an entry to every extraction prompt, so the set
/// is deliberately small.
///
/// Raw values are the stable wire form used in `MealTargets.handEditedData` and
/// in any tool schema, so they are snake_case strings rather than the Swift
/// case names, and they must not be renamed once rows exist.
enum Nutrient: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case calories     = "calories"
    case protein      = "protein"
    case carbs        = "carbs"
    case fat          = "fat"
    case fibre        = "fibre"
    case sugar        = "sugar"
    case sodium       = "sodium"
    case saturatedFat = "saturated_fat"

    var id: String { rawValue }

    /// Human-readable label. Used on bars, legends and verdict lines.
    var displayName: String {
        switch self {
        case .calories:     return "Calories"
        case .protein:      return "Protein"
        case .carbs:        return "Carbs"
        case .fat:          return "Fat"
        case .fibre:        return "Fibre"
        case .sugar:        return "Sugar"
        case .sodium:       return "Sodium"
        case .saturatedFat: return "Saturated fat"
        }
    }

    /// The name for a narrow box (#610).
    ///
    /// Identical to `displayName` for seven of the eight. "Saturated fat" is
    /// the one that does not fit: a pill sized to it is 123pt, and an even
    /// three-across share of a phone-width card is 103pt, so for two releases
    /// the Watch row was drawn at RAGGED widths to stop the label truncating
    /// (#561). That treated the layout as the problem when the label was.
    ///
    /// "Sat fat" is how a nutrition panel abbreviates it, it fits an even
    /// share at every width the app runs at, and the full name is still what
    /// `displayName` gives every surface with room for it — including the
    /// spoken label, so a reader never hears the abbreviation.
    var shortLabel: String {
        switch self {
        case .saturatedFat: return "Sat fat"
        default:            return displayName
        }
    }

    /// The unit every stored value for this nutrient is in. Storage carries a
    /// bare `Double`, so this is the only place that says what the number
    /// means: grams for the macros, milligrams for sodium, kcal for energy.
    var unit: String {
        switch self {
        case .calories: return "kcal"
        case .sodium:   return "mg"
        case .protein, .carbs, .fat, .fibre, .sugar, .saturatedFat: return "g"
        }
    }

    /// Which direction this nutrient's target is good in.
    ///
    /// - Protein and fibre are floors: the target is a minimum to reach.
    /// - Sugar, sodium and saturated fat are ceilings: the target is a limit.
    /// - Calories, carbs and fat are ranges: a day far under is as much a miss
    ///   as a day far over, because they carry the energy the other two kinds
    ///   are measured against.
    var goalKind: NutrientGoalKind {
        switch self {
        case .protein, .fibre:
            return .floor
        case .sugar, .sodium, .saturatedFat:
            return .ceiling
        case .calories, .carbs, .fat:
            return .range
        }
    }
}
