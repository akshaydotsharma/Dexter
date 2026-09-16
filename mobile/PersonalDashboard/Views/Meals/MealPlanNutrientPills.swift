import SwiftUI

/// The numbers on a planned meal, as pills (#599).
///
/// ### What was wrong with the line it replaces
///
/// The macros were one string: "46 P · 80 C · 7 F · 8 Fib". That is four facts
/// wearing one coat. Nothing separates them except a middle dot, the unit is
/// implied, and the nutrient is named by an initial the reader has to decode —
/// and "F" appears twice, once for fat and once inside "Fib". A figure you have
/// to parse is a figure nobody reads, which on a plan means the numbers were
/// there and doing no work at all.
///
/// ### The shape
///
/// One pill per macro: a hue dot, the nutrient's name in words, the value with
/// its unit. Four objects instead of one line, each one scannable on its own,
/// wrapping to the next row when the card is narrow.
///
/// Colour is identity here, never a verdict — see `Tokens.nutrientTint(for:)`
/// for why a plan can afford that and Tracking cannot. It rides on a dot and a
/// hairline rather than a fill, because the block already carries a meal-type
/// rail and four coloured blocks beside it would be five colours in one card.
struct MealPlanNutrientPills: View {
    let nutrients: MealNutrients
    /// Drawn smaller inside a block than on the sheet, where there is room.
    var compact: Bool = true

    var body: some View {
        ChipFlowLayout(spacing: Space.xs) {
            ForEach(Nutrient.macrosInOrder) { nutrient in
                pill(for: nutrient)
            }
        }
        .accessibilityHidden(true)
    }

    private func pill(for nutrient: Nutrient) -> some View {
        let tint = Tokens.nutrientTint(for: nutrient)
        return HStack(spacing: Space.xs) {
            Circle()
                .fill(tint)
                .frame(width: MealPlanNutrientMetrics.dot, height: MealPlanNutrientMetrics.dot)
            Text(nutrient.displayName)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Text(MealFormat.value(nutrients[nutrient], for: nutrient))
                .font(.edFootnoteStrong)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, compact ? 3 : 5)
        .background(Tokens.surface, in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.75))
    }
}

/// The energy figure, as the one headline on a planned meal.
///
/// Exactly one per block, and the only figure on it drawn at size. Calories are
/// what a plan is checked against first — the macros qualify the answer, they
/// are not the answer — and a row of four equal pills with no head to it makes
/// the reader do the ranking themselves every time.
///
/// It takes the meal type's own hue rather than a nutrient hue. The energy of a
/// planned meal is not a nutrient identity, it is the block's headline, and
/// tying it to the rail is what makes the pill read as belonging to THIS meal
/// rather than as a fifth macro.
struct MealPlanCaloriePill: View {
    let calories: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Text(MealFormat.calories(calories))
                .font(.edFootnoteStrong)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
            Text("kcal")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 0.75))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

enum MealPlanNutrientMetrics {
    /// The hue dot on a nutrient pill.
    static let dot: CGFloat = 6
}
