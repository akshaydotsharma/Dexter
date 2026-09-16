import SwiftUI

/// Fixed metrics for the plan board (#599).
///
/// Held here rather than as literals inside the tile for the reason every other
/// metrics table in this app gives: the minimum tile width and the row cap are
/// read together — the cap only makes sense at that width — and a change to one
/// that is not a change to the other is the kind of drift nobody notices until a
/// tile clips.
enum MealPlanBoardMetrics {
    /// Narrowest a tile may be before the grid drops a column.
    ///
    /// 260 fits a dish name and its calorie figure on one line at `.edBody`
    /// without truncating, and it gives an iPhone at 390 pt exactly ONE column,
    /// which is correct: two 170 pt tiles would truncate every name they hold.
    /// A Mac detail pane gets two or three.
    static let tileMinWidth: CGFloat = 260

    /// Gap between tiles, both axes.
    static let gutter: CGFloat = Space.md

    /// How many blocks a tile lists before it folds into a count.
    ///
    /// Four, which is more than breakfast, lunch or dinner ever holds and is the
    /// point at which a tile of snacks stops being glanceable. The rest are
    /// reachable in one tap, and the count says how many there are.
    static let visibleRowCap = 4

    /// The meal-type dot on a tile header.
    static let dot: CGFloat = 7
}

/// One meal type's blocks on the selected day (#599).
///
/// ### Why a tile and not a section of rows
///
/// The plan is four things, and the question it answers is "which of them is
/// still empty". A list of sections answers that only by scrolling to the end of
/// each one; four tiles answer it at a glance, because an empty tile LOOKS
/// empty. It also gives the day a fixed shape — four boxes, always in the same
/// order — so nothing below the fold moves as blocks are added.
///
/// The rows inside used to be the Tasks and Notes row construction, which was
/// wrong for a reason that is not cosmetic: those rows carry a title and a state
/// and nothing else, and a planned meal has to carry its numbers. A row that
/// cannot show 520 kcal is a row that makes the user open something to find out
/// whether the day adds up.
///
/// ### Two controls, both real Buttons
///
/// The tick and the row. Neither is a tap GESTURE on a container, which matters
/// beyond taste: macOS SwiftUI ignores synthetic clicks on tap-gesture controls,
/// so a tile built that way could not be driven by an automated pass at all.
///
/// Skip, delete and edit are NOT here. They live in the detail sheet the row
/// opens, because a tile that carried an overflow menu per row would spend its
/// width on controls instead of on the numbers it exists to show.
struct MealPlanTile: View {
    let slot: MealPlanSlot
    var onAdd: () -> Void
    var onOpen: (LocalMealPlanEntry) -> Void
    var onToggleEaten: (LocalMealPlanEntry) -> Void

    private var visible: [LocalMealPlanEntry] {
        Array(slot.entries.prefix(MealPlanBoardMetrics.visibleRowCap))
    }

    private var hidden: Int {
        max(slot.entries.count - MealPlanBoardMetrics.visibleRowCap, 0)
    }

    /// The tile's own totals, over the blocks that count and carry numbers.
    /// Nil when nothing in the tile has any, which is when the footer is
    /// withheld rather than drawn as a row of zeros.
    private var totals: MealNutrients? {
        let counted = slot.counted.compactMap(\.plannedNutrients)
        guard !counted.isEmpty else { return nil }
        return counted.reduce(MealNutrients.zero, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header

            if slot.isEmpty {
                emptyBody
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible, id: \.clientUUID) { entry in
                        MealPlanTileRow(
                            entry: entry,
                            onOpen: { onOpen(entry) },
                            onToggleEaten: { onToggleEaten(entry) }
                        )
                    }
                }
                if hidden > 0 {
                    Text("+\(hidden) more")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.top, Space.xxs)
                }
                if let totals { footer(totals) }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(slot.mealType.tint)
                .frame(width: MealPlanBoardMetrics.dot, height: MealPlanBoardMetrics.dot)
            Text(slot.mealType.displayName)
                .eyebrow()
            Spacer(minLength: Space.sm)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.inkSoft)
                    .frame(width: 26, height: 26)
                    .background(Tokens.surface2, in: Circle())
                    .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(slot.mealType.displayName.lowercased())")
        }
    }

    // MARK: - Empty

    /// The empty state is a BUTTON, not a label.
    ///
    /// The plus in the header is small and sits where the eye lands last. An
    /// empty tile is mostly empty space, and that space is the obvious place to
    /// aim at, so it does the same thing rather than nothing.
    private var emptyBody: some View {
        Button(action: onAdd) {
            HStack(spacing: Space.sm) {
                Text("No items added")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("No \(slot.mealType.displayName.lowercased()) planned. Add one")
    }

    // MARK: - Footer

    /// The tile's macro rung, in the fixed order every Meals surface prints
    /// them. Never sorted by value: position is how a nutrient is identified
    /// once colour has been spent elsewhere.
    ///
    /// Neutral, never a verdict. A tile is one part of a day, and a verdict is
    /// about the whole of one — painting breakfast amber for being under a
    /// DAY's protein target would be reading the wrong number against the wrong
    /// thing.
    private func footer(_ totals: MealNutrients) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)
            HStack(spacing: Space.xs) {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(totals[nutrient], for: nutrient),
                        variant: .neutral,
                        fillsWidth: true
                    )
                }
            }
        }
        .padding(.top, Space.xxs)
    }
}

/// One planned block inside a tile (#599).
///
/// A tick and a row, and the row carries the numbers. Everything else about the
/// block — skip, delete, the ingredients, the recipe — is one tap away in the
/// detail sheet, because a tile has room for a name and a figure and not for a
/// control strip.
struct MealPlanTileRow: View {
    let entry: LocalMealPlanEntry
    var onOpen: () -> Void
    var onToggleEaten: () -> Void

    private var isSkipped: Bool { entry.statusEnum == .skipped }

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            tick
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(isSkipped ? Tokens.muted : Tokens.ink)
                        .strikethrough(isSkipped, color: Tokens.mutedSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    detailLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A Button wrapping bare Text is tappable only on the glyphs
                // without this, so the gap beside a short name would do nothing
                // (#530).
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spokenRow)
            .accessibilityHint("Opens this planned meal")
        }
        .padding(.vertical, Space.sm)
        .opacity(isSkipped ? 0.55 : 1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)
        }
    }

    private var tick: some View {
        Button(action: onToggleEaten) {
            Image(systemName: entry.statusEnum.sfSymbol)
                .font(.system(size: 15, weight: .regular))
                // Green on an eaten block and nothing else. `Tokens.success` is
                // a verdict colour everywhere else on this surface, and spending
                // it here is deliberate: a ticked block IS a verdict, on whether
                // the plan was followed.
                .foregroundStyle(entry.statusEnum == .eaten ? Tokens.success : Tokens.mutedSoft)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSkipped)
        .accessibilityLabel(
            entry.statusEnum == .eaten
                ? "Mark \(entry.title) as not eaten"
                : "Mark \(entry.title) as eaten"
        )
        .accessibilityAddTraits(entry.statusEnum == .eaten ? [.isButton, .isSelected] : .isButton)
    }

    /// The numbers, or what is missing instead of them.
    ///
    /// A block with no numbers says so rather than printing zeros. That is the
    /// state a hand-typed block starts in, and it is also the prompt to open the
    /// block and estimate it, so it has to be visible from the tile.
    @ViewBuilder
    private var detailLine: some View {
        if isSkipped {
            Text("Skipped")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        } else if let nutrients = entry.plannedNutrients {
            Text(Self.macroLine(nutrients))
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } else {
            Text("No numbers yet")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
        }
    }

    /// "480 kcal · 32 P · 54 C · 14 F".
    ///
    /// Initials rather than words, and that is a concession to width this
    /// surface can afford exactly here: the tile row is the one place in Meals
    /// where four figures have to fit beside a dish name. The full words are on
    /// the tile's own footer rung two lines below, on the detail sheet, and in
    /// the accessibility label, so the initial is never the only place a
    /// nutrient is named.
    static func macroLine(_ nutrients: MealNutrients) -> String {
        "\(MealFormat.calories(nutrients.calories)) kcal"
            + " · \(MealFormat.grams(nutrients.proteinG)) P"
            + " · \(MealFormat.grams(nutrients.carbsG)) C"
            + " · \(MealFormat.grams(nutrients.fatG)) F"
    }

    /// The whole row in one sentence, so a reader is not handed a name, four
    /// numbers and a state as six separate stops.
    private var spokenRow: String {
        var parts = [entry.title]
        if isSkipped {
            parts.append("skipped")
        } else {
            if entry.statusEnum == .eaten { parts.append("eaten") }
            if let nutrients = entry.plannedNutrients {
                parts.append("about \(MealFormat.calories(nutrients.calories)) kilocalories")
                for nutrient in Nutrient.macrosInOrder {
                    parts.append("\(MealFormat.grams(nutrients[nutrient])) grams \(nutrient.displayName.lowercased())")
                }
            } else {
                parts.append("no numbers yet")
            }
        }
        return parts.joined(separator: ", ")
    }
}
