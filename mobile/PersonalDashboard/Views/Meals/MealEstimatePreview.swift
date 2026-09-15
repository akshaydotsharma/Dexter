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
                // The name leads its line, so it sits a full rung above the
                // portion under it. At 13 over 12 the two were one point apart
                // and the whole block read as a single grey mass.
                Text(item.name)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(portionMissing ? "No portion assumed" : item.portionDescription)
                    .font(.edFootnote)
                    .foregroundStyle(portionMissing ? Tokens.danger : Tokens.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.sm)
            Text("\(MealFormat.calories(item.calories)) kcal")
                .font(.edFootnoteStrong)
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
///
/// ### Why the kcal figure is a rung below the day card's
///
/// The day card prints its total at `edDisplay`; this prints its proposal at
/// `edTitle`. A proposal must never outrank the day it feeds, or the surface
/// reads as though logging has already happened.
struct MealEstimatePreview: View {
    let checked: CheckedMealEstimate
    let description: String
    let onDiscard: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
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

            // Addition 2: the block is reserved on any estimate that produced
            // items, so the preview does not change height between one estimate
            // and the next. To revert, make this `if checked.assumptionsNote != nil`.
            if !checked.needsDetail || checked.assumptionsNote != nil {
                assumptionsBlock
            }

            if let reason = checked.suspectReason {
                suspectBlock(reason)
            }

            actions
        }
        // Addition 1: the preview is a proposal and gets a surface of its own,
        // rather than sharing the composer's box with the input field behind a
        // hairline rule. To revert, drop these three modifiers and put back the
        // leading `Rectangle().fill(Tokens.divider).frame(height: 0.5)`.
        .padding(Space.lg)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            // A category label, not a fact about the meal. As an eyebrow it
            // demotes by kind instead of by size, which leaves the size budget
            // to the numbers below it.
            Label(checked.mealType.displayName, systemImage: checked.mealType.sfSymbol)
                .eyebrow(Tokens.accentMeals)
            Spacer(minLength: Space.sm)
            MealFlagChip(
                MealFormat.confidenceBand(checked.confidence),
                tint: checked.confidence >= 0.75 ? Tokens.success : Tokens.muted
            )
        }
    }

    /// The headline figure and the four macros the day is steered by.
    ///
    /// The three ceilings stay out: this is a decision surface, and three
    /// ceiling numbers with no target to read them against are noise. All eight
    /// are in the detail sheet.
    private var totalsRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            MealStatPill(
                label: "kcal",
                value: MealFormat.calories(checked.nutrients.calories),
                variant: .accent,
                accessibilityText: "\(MealFormat.calories(checked.nutrients.calories)) kilocalories"
            )

            // Flowed rather than stacked in an HStack: four pills plus their
            // labels do not fit one line on a phone, and clipping a macro is
            // worse than wrapping it.
            ChipFlowLayout {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(checked.nutrients[nutrient], for: nutrient)
                    )
                }
            }
        }
        .padding(.top, Space.xs)
    }

    /// What the estimate had to guess at.
    ///
    /// The sentence is the one thing on this surface a user argues with, so it
    /// is set at reading size and it is selectable: on macOS a `Text` cannot be
    /// copied unless it says so, and this is a line people want to paste back
    /// into the description to correct it.
    private var assumptionsBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Assumed").eyebrow()
            Text(checked.assumptionsNote ?? " ")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var needsDetailBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("No food identified")
                .font(.edHeading)
                .foregroundStyle(Tokens.warning)
            Text("Logging this keeps the description and the fact that you ate. Add detail later and re-estimate.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Discard sits immediately left of the primary, not marooned at the far
    /// edge in ghost styling. A destructive-ish action the user has to find is
    /// not an action they will take, and the pair reads as one decision.
    private var actions: some View {
        HStack(spacing: Space.sm) {
            Spacer(minLength: Space.sm)
            Button("Discard", action: onDiscard)
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
            Button(checked.needsDetail ? "Log it anyway" : "Log meal", action: onConfirm)
                .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
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
            .font(.edFootnote)
            .foregroundStyle(Tokens.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Stated before the button, not after it. A warning a user meets only once
    /// they have already committed is not a warning.
    private func suspectBlock(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label("This estimate does not add up", systemImage: "exclamationmark.triangle")
                .font(.edHeading)
                .foregroundStyle(Tokens.danger)
            Text(reason)
                .font(.edSubheadline)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // Deliberately one rung under the reason: it says what happens
            // next, which nobody has to act on.
            Text("It still saves, flagged, and stays out of the day's totals until you correct it.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.dangerSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
