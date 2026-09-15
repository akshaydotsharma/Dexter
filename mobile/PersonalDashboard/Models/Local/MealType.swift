import Foundation

/// The four parts of an eating day (#542). Raw values are what the LLM picks
/// from in the meal-logging tool schema and what gets persisted onto
/// `LocalMeal.mealType`.
///
/// Four, not five. A drink is logged as a snack rather than getting a type of
/// its own: a fifth bucket splits the day view into a column nobody reads and
/// answers no question the four cannot. "Did I eat enough protein at lunch" is
/// a question; "was that coffee a drink or a snack" is not.
///
/// Order here is the order of an actual day, so a day view that iterates
/// `allCases` reads top to bottom without sorting. `snack` sits last because it
/// is the one that can happen at any hour.
enum MealType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case breakfast = "breakfast"
    case lunch     = "lunch"
    case dinner    = "dinner"
    case snack     = "snack"

    var id: String { rawValue }

    /// Human-readable label shown on rows, section headers and pickers.
    var displayName: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch:     return "Lunch"
        case .dinner:    return "Dinner"
        case .snack:     return "Snack"
        }
    }

    /// SF Symbol for a row or a section header.
    var sfSymbol: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch:     return "sun.max"
        case .dinner:    return "moon.stars"
        case .snack:     return "carrot"
        }
    }
}
