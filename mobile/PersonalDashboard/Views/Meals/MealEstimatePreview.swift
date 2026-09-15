import SwiftUI

/// One estimated dish, shown with the portion the estimate assumed (#543).
///
/// The portion is given the same visual weight as the name. It is an
/// ASSUMPTION, it is the largest single source of error in a text-derived
/// estimate, and an assumption nobody can see is an error nobody can fix.
struct MealItemLine: View {
    let item: MealItemEntry

    /// True when the portion could not be read and the meal was flagged for it.
    private var portionMissing: Bool {
        item.portionQuantity <= 0 || item.portionUnit.isEmpty
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(portionMissing ? "No portion assumed" : item.portionDescription)
                    .font(.edCaption)
                    .foregroundStyle(portionMissing ? Tokens.danger : Tokens.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.sm)
            Text("\(MealFormat.calories(item.calories)) kcal")
                .font(.edCaption)
                .foregroundStyle(Tokens.inkSoft)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The estimate, before anything is written (#543).
///
/// Shows the per-item assumptions, the totals, a confidence badge, and — when a
/// guard failed — the reason, stated plainly and before the Log button rather
/// than after it.
struct MealEstimatePreview: View {
    let checked: CheckedMealEstimate
    let description: String
    let onDiscard: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            header

            if checked.needsDetail {
                needsDetailBlock
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(checked.items) { item in
                        MealItemLine(item: item)
                    }
                }
                totalsRow
            }

            if let repaired = checked.repairNote {
                repairBlock(repaired)
            }

            if let note = checked.assumptionsNote {
                Text(note)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reason = checked.suspectReason {
                suspectBlock(reason)
            }

            HStack(spacing: Space.sm) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                Spacer(minLength: Space.sm)
                Button(checked.needsDetail ? "Log it anyway" : "Log meal", action: onConfirm)
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Label(checked.mealType.displayName, systemImage: checked.mealType.sfSymbol)
                .font(.edFootnote)
                .foregroundStyle(Tokens.accentMeals)
            Spacer(minLength: Space.sm)
            MealFlagChip(
                MealFormat.confidenceBand(checked.confidence),
                tint: checked.confidence >= 0.75 ? Tokens.success : Tokens.muted
            )
        }
    }

    private var totalsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text("\(MealFormat.calories(checked.nutrients.calories)) kcal")
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
            Spacer(minLength: Space.sm)
            Text(macroSummary)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()
        }
        .padding(.top, Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var macroSummary: String {
        let n = checked.nutrients
        return "P \(MealFormat.grams(n.proteinG)) · C \(MealFormat.grams(n.carbsG)) · F \(MealFormat.grams(n.fatG))"
    }

    private var needsDetailBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("No food identified")
                .font(.edFootnote)
                .foregroundStyle(Tokens.warning)
            Text("Logging this keeps the description and the fact that you ate. Add detail later and re-estimate.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A value the guards fixed in place.
    ///
    /// Stated plainly and NOT as a warning: the meal is coherent, it counts in
    /// the day, and nothing is being asked of the user. It is here because a
    /// number that was changed on the way in should be a number the user can see
    /// was changed.
    private func repairBlock(_ note: String) -> some View {
        Label(note, systemImage: "slider.horizontal.3")
            .font(.edCaption)
            .foregroundStyle(Tokens.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Stated before the button, not after it. A warning a user meets only once
    /// they have already committed is not a warning.
    private func suspectBlock(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("This estimate does not add up", systemImage: "exclamationmark.triangle")
                .font(.edFootnote)
                .foregroundStyle(Tokens.danger)
            Text(reason)
                .font(.edCaption)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("It still saves, flagged, and stays out of the day's totals until you correct it.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.dangerSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
