import SwiftUI

/// The colours a habit can wear (#661).
///
/// Every value is an EXISTING section accent, so habits add no new hues to the
/// app. The raw value is what `LocalHabit.colorKey` stores; an unknown key
/// (from a newer peer) resolves to `.gold` rather than trapping.
///
/// Red and green are deliberately absent. On a habit grid red already means
/// "missed" (`Tokens.danger`), and a green habit would read as a verdict.
enum HabitColor: String, CaseIterable, Identifiable {
    case gold
    case amber
    case teal
    case azure
    case indigo
    case violet
    case magenta
    case plum

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .gold:    return Tokens.accentHabits
        case .amber:   return Tokens.accentNotes
        case .teal:    return Tokens.accentLists
        case .azure:   return Tokens.accentMeals
        case .indigo:  return Tokens.accentTasks
        case .violet:  return Tokens.accentItineraries
        case .magenta: return Tokens.accentWallet
        case .plum:    return Tokens.accentActivity
        }
    }

    var label: String { rawValue.capitalized }

    static func resolve(_ key: String) -> HabitColor {
        HabitColor(rawValue: key) ?? .gold
    }
}

extension LocalHabit {
    var tint: Color { HabitColor.resolve(colorKey).color }
}
