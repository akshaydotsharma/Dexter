import SwiftUI

/// What the selected day needs from a shop (#599).
///
/// ### Deliberately not a shopping list
///
/// The ask was the ingredients needed, roughly, and not the whole list. So there
/// are no quantities, no units, no aisle and no tick boxes. Each of those turns
/// a strip you glance at into a document you have to maintain, and none of them
/// is knowable from a block that says "chicken rice" anyway.
///
/// A number beside a name is a count of MEALS, never an amount of food, which is
/// why it is spoken as "in 2 meals". It is there because "chicken thigh, in two
/// meals" is a shopping decision and "chicken thigh" on its own is not.
///
/// Lists already exist in this app, and a user who wants a real shopping list
/// with tick boxes has a better one there. This answers "what is this day made
/// of".
///
/// ### Where the names come from
///
/// The estimate, not the user. A block is typed as a dish — "chicken rice" — and
/// the model breaks it into what has to be bought. So this card fills itself in
/// as the day is planned, and a block that was never estimated contributes
/// nothing to it, which is the prompt to go and estimate it.
struct MealPlanNeedsCard: View {

    let ingredients: [MealPlanIngredient]
    /// True when the day holds blocks that carry no ingredients at all, so the
    /// card can say the list is short because the plan is, rather than letting
    /// the user read it as complete.
    let blocksWithoutIngredients: Int

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
                    Text("What you'll need").eyebrow()
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

                Text(caption)
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

    /// The caption names the gap when there is one. A list that is short because
    /// two blocks were never estimated looks exactly like a complete list, and
    /// only one of those is safe to shop from.
    private var caption: String {
        let base = "The key ingredients for this day's meals. Skipped meals are left out."
        guard blocksWithoutIngredients > 0 else { return base }
        let noun = blocksWithoutIngredients == 1 ? "meal has" : "meals have"
        return base + " \(blocksWithoutIngredients) planned \(noun) no ingredients yet."
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
