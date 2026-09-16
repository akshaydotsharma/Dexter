import SwiftUI

/// What the week or the month on screen needs from a shop (#599).
///
/// ### Deliberately not a shopping list
///
/// The user asked for the ingredients they will need, roughly — "not the whole
/// list, just maybe the main ingredients". So there are no quantities, no units,
/// no tick boxes and no aisle. Each of those turns a strip you glance at into a
/// document you have to maintain, and none of them is knowable from a block that
/// says "chicken rice" anyway.
///
/// The number beside a name is a count of MEALS, never an amount of food, which
/// is why it is spoken as "in 4 meals". It is there because "chicken thigh, in
/// four meals" is a shopping decision and "chicken thigh" on its own is not.
///
/// Lists already exist in this app, and a user who wants a real shopping list
/// with tick boxes has a better one there. This is the answer to "what is this
/// week made of".
struct MealPlanIngredientsCard: View {

    let ingredients: [MealPlanIngredient]
    /// What the roll-up covers, for the caption: "this week", "September".
    let scopeLabel: String

    /// How many names are shown before the card folds.
    ///
    /// Twelve is about four lines of chips at phone width, which is as much as
    /// can be taken in without reading. Past that the card would be the tallest
    /// thing on the tab and would say less per inch than the plan it came from.
    private let ceiling = 12

    @State private var expanded = false

    private var visible: [MealPlanIngredient] {
        expanded ? ingredients : Array(ingredients.prefix(ceiling))
    }

    private var hidden: Int {
        max(ingredients.count - ceiling, 0)
    }

    var body: some View {
        if ingredients.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Text("Ingredients \(scopeLabel)").eyebrow()
                    Spacer(minLength: 0)
                    Text("\(ingredients.count)")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .monospacedDigit()
                }

                ChipFlowLayout(spacing: Space.xs) {
                    ForEach(visible) { ingredient in
                        chip(ingredient)
                    }
                }

                if hidden > 0 && !expanded {
                    Button("Show \(hidden) more") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = true }
                    }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                } else if expanded && ingredients.count > ceiling {
                    Button("Show fewer") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = false }
                    }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }

                Text("From the meals planned \(scopeLabel). Skipped meals are left out.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
        }
    }

    /// The count rides INSIDE the chip rather than on a second line, and it is
    /// drawn only when it is greater than one. A "1" beside every name would be
    /// noise on the majority of chips and would make the few that matter harder
    /// to find, which is the opposite of what the count is for.
    private func chip(_ ingredient: MealPlanIngredient) -> some View {
        HStack(spacing: Space.xs) {
            Text(ingredient.name)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
            if ingredient.blocks > 1 {
                Text("\(ingredient.blocks)")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, 5)
        .background(Tokens.surface2, in: Capsule())
        .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ingredient.blocks > 1
                ? "\(ingredient.name), in \(ingredient.blocks) meals"
                : ingredient.name
        )
    }
}
