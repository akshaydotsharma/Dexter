import SwiftUI

/// The colour that stands for a meal type (#570).
///
/// ### Why this is not on `MealType` itself
///
/// `Models/Local/MealType.swift` imports `Foundation` and nothing else. It is
/// the enum the LLM tool schema picks from and the string persisted onto
/// `LocalMeal.mealType`, shared verbatim with the `DexterMac` target, and a
/// SwiftUI import on a model file would put a view framework behind every
/// caller that only wants the raw value. So the tint lives here, in the view
/// layer, beside the surfaces that draw it.
///
/// ### Where the colours come from
///
/// `Tokens`, never a literal at the call site, and the reasoning for the four
/// hues is written on `Tokens.mealTypeBreakfast`. The short version: hue on the
/// Meals surface means a verdict about a quantity, so an identity has to be
/// taken from a family the verdict palette never enters.
extension MealType {

    /// The one colour that means "this is a lunch" on any Meals surface.
    var tint: Color {
        switch self {
        case .breakfast: return Tokens.mealTypeBreakfast
        case .lunch:     return Tokens.mealTypeLunch
        case .dinner:    return Tokens.mealTypeDinner
        case .snack:     return Tokens.mealTypeSnack
        }
    }
}
