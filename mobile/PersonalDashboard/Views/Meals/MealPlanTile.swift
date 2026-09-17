import SwiftUI

/// Fixed metrics for the plan board (#599).
///
/// Held here rather than as literals inside the tile for the reason every other
/// metrics table in this app gives: the rail width and the row's corner radius
/// are read together — the rail has to look like part of the block, not a line
/// beside it — and a change to one that is not a change to the other is the kind
/// of drift nobody notices until a corner clips.
enum MealPlanBoardMetrics {
    /// Gap between tiles. They stack vertically, so this is the day's rhythm.
    static let gutter: CGFloat = Space.md

    /// How many blocks a tile lists before it folds into a count.
    ///
    /// Six, raised from four when the tiles went full width: a stacked tile has
    /// the room, and the cap exists to stop a day of snacks pushing the rest of
    /// the day off the screen, not to ration a surface that can afford them.
    static let visibleRowCap = 6

    /// The meal-type dot on a tile header.
    static let dot: CGFloat = 7

    /// Width of the colour rail down the leading edge of a block.
    ///
    /// The rail IS the identity. It replaced a tick and a radio glyph, which
    /// were controls occupying the place the eye lands first on a row whose job
    /// is to be read rather than operated.
    static let rail: CGFloat = 3

    /// Corner radius of one block. Smaller than a card, so a block reads as an
    /// entry inside the tile rather than as a card floating on another card.
    static let blockRadius: CGFloat = Radius.sm

    /// How much of the meal type's hue the block's fill carries.
    ///
    /// Low, and it has to stay low. Hue on every other Meals surface means a
    /// VERDICT about a quantity, and the meal-type family exists precisely so
    /// identity can be shown without entering that palette. A wash strong enough
    /// to read as "this is coloured in" would start competing with the red and
    /// amber the Tracking tab spends on readings.
    static let blockFill: Double = 0.07
    static let blockStroke: Double = 0.22
}

/// One meal type's blocks on the selected day (#599).
///
/// ### Why the tiles stack rather than sit in a grid
///
/// They were a two-column adaptive grid, which put breakfast beside lunch and
/// wasted the width on a Mac to save a scroll on a phone. Stacked, each tile
/// gets the full pane, which is what the blocks inside need: a dish name, four
/// figures and a row of ingredient pills do not fit across half a window without
/// truncating one of the three.
///
/// It also restores the order of an actual day as a vertical reading, which is
/// how a day is read.
struct MealPlanTile: View {
    let slot: MealPlanSlot
    var onAdd: () -> Void
    var onOpen: (LocalMealPlanEntry) -> Void

    private var visible: [LocalMealPlanEntry] {
        Array(slot.entries.prefix(MealPlanBoardMetrics.visibleRowCap))
    }

    private var hidden: Int {
        max(slot.entries.count - MealPlanBoardMetrics.visibleRowCap, 0)
    }

    /// The tile's own totals, over the blocks that count and carry numbers. Nil
    /// when nothing in the tile has any, which is when the figure is withheld
    /// rather than drawn as a zero.
    private var totals: MealNutrients? {
        let counted = slot.counted.compactMap(\.plannedNutrients)
        guard !counted.isEmpty else { return nil }
        return counted.reduce(MealNutrients.zero, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header

            // The one mark between the title line and the meals under it.
            //
            // The dashed ghost row used to do this job as a side effect of
            // being a control, which is a lot of ink for a separation: a
            // hairline says the same thing and says nothing else.
            Rectangle()
                .fill(Tokens.border)
                .frame(height: 1)

            if slot.isEmpty {
                emptyBody
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(visible, id: \.clientUUID) { entry in
                        MealPlanBlock(entry: entry, onOpen: { onOpen(entry) })
                    }
                }
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Header

    /// The title line: which meal, what it costs so far, and the add.
    ///
    /// The plus takes the trailing edge, which is where a section's own action
    /// sits everywhere else in this app, and the calorie figure moves in beside
    /// it. Both are trailing because both are about the tile as a whole, and the
    /// leading cluster is left to say only what the tile IS.
    private var header: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(slot.mealType.tint)
                .frame(width: MealPlanBoardMetrics.dot, height: MealPlanBoardMetrics.dot)
            Text(slot.mealType.displayName)
                .eyebrow()

            Spacer(minLength: Space.sm)

            if let totals {
                Text("\(MealFormat.calories(totals.calories)) kcal")
                    .font(.edFootnoteStrong)
                    .foregroundStyle(Tokens.inkSoft)
                    .monospacedDigit()
            }
            addButton
        }
    }

    /// The plus, in the meal type's own hue.
    ///
    /// It was a `surface2` circle on a `surface` card, which is a two-step
    /// difference in the palette and read as absent: the control most likely to
    /// be looked for on an empty tile was the hardest thing on it to see. The
    /// hue ties it to the tile it belongs to and lifts it clear of the card in
    /// one move, and it stays inside the meal-type family, so it still cannot be
    /// mistaken for a verdict.
    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(slot.mealType.tint)
                .frame(width: 22, height: 22)
                .background(slot.mealType.tint.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(slot.mealType.tint.opacity(0.45), lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(slot.mealType.displayName.lowercased())")
    }

    // MARK: - Empty

    /// The empty state is a BUTTON, not a label.
    ///
    /// The plus sits at the far end of the title line, where the eye lands last.
    /// An empty tile is mostly empty space, and that space is the obvious thing
    /// to aim at, so it does the same job rather than nothing.
    private var emptyBody: some View {
        Button(action: onAdd) {
            HStack(spacing: Space.sm) {
                Text("No items added")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No \(slot.mealType.displayName.lowercased()) planned. Add one")
    }
}

/// One planned meal, drawn as a calendar block (#599).
///
/// ### Why a rail and a wash rather than a tick
///
/// The row used to open with a circle you could tap to mark the meal eaten. That
/// put a CONTROL in the position the eye lands on first, on a row whose job is to
/// be read: what is this, what does it cost me, what do I need to buy. It also
/// meant the most prominent thing on the row was the least used.
///
/// A calendar entry solves the same problem by colouring the block and leaving
/// it alone, so that is what this is: a coloured rail, a tinted fill, and the
/// content.
///
/// ### What it shows without being opened
///
/// The dish, its energy as a headline, its macros as named pills, and the key
/// ingredients under a label. Those answer the questions a plan is consulted
/// for. The recipe, the breakdown and the note need a reason to be looked at,
/// so they wait behind the tap.
///
/// The skipped treatment stays in the drawing — a struck-through, half-faded
/// block — but nothing sets it any more: the state control came off the sheet
/// on request. The model still carries the field, so a way to skip a meal can
/// return without a migration.
struct MealPlanBlock: View {
    let entry: LocalMealPlanEntry
    var onOpen: () -> Void

    private var tint: Color { entry.mealTypeEnum.tint }
    private var isSkipped: Bool { entry.statusEnum == .skipped }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: MealPlanBoardMetrics.rail / 2, style: .continuous)
                    .fill(tint)
                    .frame(width: MealPlanBoardMetrics.rail)

                VStack(alignment: .leading, spacing: Space.sm) {
                    titleRow

                    if let nutrients = entry.plannedNutrients {
                        MealPlanNutrientPills(nutrients: nutrients)
                    } else {
                        Text("No numbers yet")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.mutedSoft)
                    }

                    if !entry.ingredients.isEmpty { ingredientRow }
                }
                .padding(.leading, Space.md)
                .padding(.trailing, Space.md)
                .padding(.vertical, Space.sm + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                tint.opacity(MealPlanBoardMetrics.blockFill),
                in: RoundedRectangle(cornerRadius: MealPlanBoardMetrics.blockRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MealPlanBoardMetrics.blockRadius, style: .continuous)
                    .stroke(tint.opacity(MealPlanBoardMetrics.blockStroke), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: MealPlanBoardMetrics.blockRadius, style: .continuous))
            .opacity(isSkipped ? 0.5 : 1)
            // A Button wrapping bare Text is tappable only on the glyphs without
            // this, so the gap beside a short name would do nothing (#530).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenBlock)
        .accessibilityHint("Opens the recipe and the rest of this meal")
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            // Logged, said on the block rather than only inside it (#612).
            // A tick is the one state worth knowing without opening a meal:
            // it answers "have I dealt with this" for the whole day at a
            // glance. `success` green, because this is the one mark on the
            // plan that IS a verdict about a thing that happened.
            if entry.statusEnum == .eaten {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.success)
                    .accessibilityHidden(true)
            }
            // Shortened, not the whole title (#603). A block is a row in a
            // stack of four tiles, and a title typed as a sentence ("leftover
            // chicken curry with the rice from Sunday, plus a salad") pushed
            // the calorie pill onto its own line and the ingredients off the
            // bottom. The full title is in the sheet this block opens.
            Text(MealDisplayName.short(for: entry))
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .strikethrough(isSkipped, color: Tokens.mutedSoft)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            if let nutrients = entry.plannedNutrients {
                MealPlanCaloriePill(calories: nutrients.calories, tint: tint)
            }
        }
    }

    /// The key ingredients, named.
    ///
    /// The chips used to float under the numbers with nothing to say what they
    /// were, so a row reading "chicken thigh · jasmine rice · ginger" could as
    /// easily have been tags, a note, or what the dish is served with. One
    /// eyebrow fixes that for the cost of a label.
    private var ingredientRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("Ingredients")
                .eyebrow()
                .fixedSize()
            ingredientPills
        }
    }

    /// The key ingredients, on the block rather than behind it.
    ///
    /// This is the half of a plan that is not about nutrition: a block that says
    /// "chicken rice, 620 kcal" tells you nothing about whether you can make it
    /// tonight. Four pills do.
    ///
    /// They sit on the block's own tinted ground, so they take `surface` rather
    /// than `surface2` — `surface2` against a wash reads as a smudge rather than
    /// as a separate object.
    private var ingredientPills: some View {
        ChipFlowLayout(spacing: Space.xs) {
            ForEach(entry.ingredients, id: \.self) { ingredient in
                Text(ingredient)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.inkSoft)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Tokens.surface, in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 0.5))
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    /// The whole block in one sentence, so a reader is not handed a name, four
    /// numbers and six pills as eleven separate stops.
    private var spokenBlock: String {
        var parts = ["\(entry.mealTypeEnum.displayName), \(entry.title)"]
        if isSkipped { parts.append("skipped") }
        if entry.statusEnum == .eaten { parts.append("eaten") }
        if let nutrients = entry.plannedNutrients {
            parts.append("about \(MealFormat.calories(nutrients.calories)) kilocalories")
            for nutrient in Nutrient.macrosInOrder {
                parts.append("\(MealFormat.grams(nutrients[nutrient])) grams \(nutrient.displayName.lowercased())")
            }
        } else {
            parts.append("no numbers yet")
        }
        if !entry.ingredients.isEmpty {
            parts.append("needs \(entry.ingredients.joined(separator: ", "))")
        }
        return parts.joined(separator: ", ")
    }
}
