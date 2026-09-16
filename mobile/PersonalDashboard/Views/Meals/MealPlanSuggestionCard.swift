import SwiftUI

/// One suggestion the plan chat has put forward (#599).
///
/// ### Why it is a card and not a line of prose
///
/// Everything on it is actionable in a way a sentence is not: the meal type
/// decides which slot it lands in, the ingredients are what gets carried onto
/// the block, the numbers are what makes the planned day add up, and the button
/// is the whole point. Prose carrying the same four things would have to be
/// parsed by the reader before it could be used.
///
/// ### The Add button says which day
///
/// Because the sheet can be open over a calendar showing a different one, and a
/// suggestion silently landing on the wrong day corrupts two days at once while
/// neither one looks wrong. The same reasoning `MealChatCard` applies to a meal
/// logged onto a day that is not today.
struct MealPlanSuggestionCard: View {
    let suggestion: MealPlanSuggestion
    /// The day the Add button will write to, already named for the button.
    let dayLabel: String
    /// True once it has been added, which swaps the button for a confirmation.
    let wasAdded: Bool
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            if let why = suggestion.why {
                Text(why)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestion.ingredients.isEmpty { ingredientChips }

            if let nutrients = suggestion.nutrients {
                macroRow(nutrients)
            } else {
                Text("No numbers for this one.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }

            if let prep = suggestion.prepNote {
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .regular))
                    Text(prep)
                        .font(.edCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.muted)
            }

            bottomRow
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(suggestion.mealType.tint)
                    .frame(width: 6, height: 6)
                Text(suggestion.mealType.displayName)
                    .eyebrow()
                Spacer(minLength: 0)
            }
            Text(suggestion.title)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var ingredientChips: some View {
        ChipFlowLayout(spacing: Space.xs) {
            ForEach(suggestion.ingredients, id: \.self) { ingredient in
                Text(ingredient)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Tokens.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ingredients: \(suggestion.ingredients.joined(separator: ", "))")
    }

    /// Calories, then the four the day is steered by, in the fixed order every
    /// Meals surface prints them. Never sorted by value: position is how a
    /// nutrient is identified once colour has been spent elsewhere.
    ///
    /// Neutral, never a verdict. These figures describe a meal nobody has eaten,
    /// so there is no day for them to be good or bad against yet.
    private func macroRow(_ nutrients: MealNutrients) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(nutrients.calories))
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                Text("kcal, roughly")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.sm) {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(nutrients[nutrient], for: nutrient),
                        variant: .neutral,
                        fillsWidth: true
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomRow: some View {
        if wasAdded {
            SuccessRow(label: "Added to \(dayLabel)")
        } else {
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                Button(action: onAdd) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Add to \(dayLabel)")
                    }
                }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                .accessibilityLabel("Add \(suggestion.title) to \(dayLabel)")
            }
        }
    }
}
