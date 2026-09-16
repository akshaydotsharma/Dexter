import SwiftUI

/// One planned meal, as a block in the day panel (#599).
///
/// ### Three controls, and each one is a real Button
///
/// The state glyph, the row body and the overflow menu. None of them is a tap
/// GESTURE on a container, which matters beyond taste: macOS SwiftUI ignores
/// synthetic clicks on tap-gesture and List-selection controls, so a row built
/// that way cannot be driven by an automated pass at all and every change to it
/// costs a hands-on check. It also matters for the pointer, which gets a real
/// hit region rather than whatever a `contentShape` happened to cover.
///
/// The row body opens the editor on a TAP. Never a long-press and never a
/// context-menu "Edit": an edit surface in this app is reached by tapping the
/// thing you want to edit.
///
/// ### Why the state glyph and the menu are separate
///
/// The glyph is the one-tap action — ticking a meal off — and it is the one the
/// user performs most days. Skip is rarer and destructive-ish: it takes the
/// block out of the day's totals and out of the shopping roll-up, which is a
/// change to numbers elsewhere on the screen. Putting both on one control would
/// make a three-state cycle, and a cycle means the only way to reach "skipped"
/// is to pass through "eaten", which briefly says something false.
struct MealPlanEntryRow: View {
    let entry: LocalMealPlanEntry

    var onOpen: () -> Void
    var onToggleEaten: () -> Void
    var onSkip: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void

    private var isSkipped: Bool { entry.statusEnum == .skipped }

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            stateButton
            VStack(alignment: .leading, spacing: Space.xs) {
                titleRow
                if !entry.ingredients.isEmpty { ingredientChips }
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            overflowMenu
        }
        .flatContentRow()
        .opacity(isSkipped ? 0.55 : 1)
    }

    // MARK: - State

    private var stateButton: some View {
        Button(action: onToggleEaten) {
            Image(systemName: entry.statusEnum.sfSymbol)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(stateTint)
                .frame(width: 28, height: 28)
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

    /// Green on an eaten block and nothing else.
    ///
    /// `Tokens.success` is a VERDICT colour everywhere else on this surface, and
    /// spending it here is deliberate rather than an oversight: a ticked block
    /// is the one thing on the plan that genuinely is a verdict, on whether the
    /// plan was followed. Nothing else in this row is tinted, so there is no
    /// second green for it to be confused with.
    private var stateTint: Color {
        switch entry.statusEnum {
        case .eaten:   return Tokens.success
        case .skipped: return Tokens.mutedSoft
        case .planned: return Tokens.mutedSoft
        }
    }

    // MARK: - Body

    private var titleRow: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(entry.title)
                    .font(.edBodyMedium)
                    .foregroundStyle(isSkipped ? Tokens.muted : Tokens.ink)
                    .strikethrough(isSkipped, color: Tokens.mutedSoft)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.sm)
                trailingFigures
            }
            // A Button wrapping bare Text is only tappable on the glyphs
            // themselves without this, so the gap between a short title and the
            // figures would do nothing (#530).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenRow)
        .accessibilityHint("Opens this planned meal")
    }

    @ViewBuilder
    private var trailingFigures: some View {
        if isSkipped {
            MealFlagChip("Skipped", systemImage: "slash.circle", tint: Tokens.muted)
        } else if let nutrients = entry.plannedNutrients {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(MealFormat.calories(nutrients.calories)) kcal")
                    .font(.edFootnoteStrong)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                Text("\(MealFormat.grams(nutrients.proteinG)) g protein")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    private var ingredientChips: some View {
        ChipFlowLayout(spacing: Space.xs) {
            ForEach(entry.ingredients, id: \.self) { ingredient in
                Text(ingredient)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Tokens.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ingredients: \(entry.ingredients.joined(separator: ", "))")
    }

    // MARK: - Overflow

    private var overflowMenu: some View {
        Menu {
            Button {
                onOpen()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                onSkip()
            } label: {
                Label(
                    isSkipped ? "Un-skip" : "Skip this meal",
                    systemImage: isSkipped ? "arrow.uturn.backward" : "slash.circle"
                )
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyleCompat()
        .accessibilityLabel("More actions for \(entry.title)")
    }

    // MARK: - Spoken

    /// The whole row in one sentence, so a reader is not handed a title, two
    /// numbers and a state as four separate stops.
    private var spokenRow: String {
        var parts = ["\(entry.mealTypeEnum.displayName), \(entry.title)"]
        if isSkipped {
            parts.append("skipped")
        } else {
            if entry.statusEnum == .eaten { parts.append("eaten") }
            if let nutrients = entry.plannedNutrients {
                parts.append("about \(MealFormat.calories(nutrients.calories)) kcal")
                parts.append("\(MealFormat.grams(nutrients.proteinG)) grams protein")
            } else {
                parts.append("no numbers")
            }
        }
        return parts.joined(separator: ", ")
    }
}
