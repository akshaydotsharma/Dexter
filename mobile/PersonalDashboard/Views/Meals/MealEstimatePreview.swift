import SwiftUI

/// One estimated dish, shown with the portion the estimate assumed (#543).
///
/// The portion is given the same visual weight as the name. It is an
/// ASSUMPTION, it is the largest single source of error in a text-derived
/// estimate, and an assumption nobody can see is an error nobody can fix.
struct MealItemLine: View {
    let item: MealItemEntry

    /// How this item's calories are printed. An item scaled from a published
    /// panel keeps its own figure; a portion guess rounds (#594).
    var precision: MealFormat.Precision = .estimate

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
            Text("\(MealFormat.calories(item.calories, precision)) kcal")
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
    /// Which day the Log button writes to, in words, when that day is not today
    /// (#592). Nil on today.
    let dayNote: String?

    /// Rows that came out of the saved item library and were NOT estimated
    /// (#625). Empty on the ordinary path, where this whole view is the #543
    /// preview unchanged.
    ///
    /// ### Why they are a parameter here and not a second preview
    ///
    /// The composer can log a meal that is half typed and half picked, and the
    /// two halves have to be told apart on screen: the user's move on seeing a
    /// figure is to ask whether anyone guessed it. The first build of that
    /// screen was a separate `mixedPreview` inside the composer, which meant
    /// two statements of the header, the repair note, the assumptions, the
    /// suspect block, the sources and the actions.
    ///
    /// That is the shape this repo has paid for repeatedly: #475 split a
    /// two-leg ticket in the email path only, #500 decoded a boarding pass
    /// differently on the attach path, #546 states the meal rules once for
    /// exactly this reason. The drift is invisible in the diff that causes it,
    /// because each statement still looks right on its own. So there is one
    /// preview, and the difference between the two cases is this array.
    var savedItems: [MealItemEntry] = []

    let onDiscard: () -> Void
    let onConfirm: () -> Void

    /// Every row the Log button will write, estimated ones first.
    private var allItems: [MealItemEntry] { checked.items + savedItems }

    /// What the totals row prints.
    ///
    /// With no saved items this is `checked.nutrients` VERBATIM, not a re-sum
    /// of the items. The distinction is load-bearing: a needs-detail estimate
    /// carries totals with no items behind them, and re-summing would show a
    /// meal as zero. `MealEstimationService.save` guards the same case the same
    /// way, so the preview and the written row agree by construction.
    private var totals: MealNutrients {
        savedItems.isEmpty ? checked.nutrients : MealNutrients.sum(of: allItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            if checked.needsDetail {
                needsDetailBlock
            }

            if savedItems.isEmpty {
                // The #543 path, unchanged: one ungrouped list, and nothing at
                // all when the estimate identified no food.
                if !checked.needsDetail {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(checked.items) { item in
                            MealItemLine(item: item, precision: precision)
                        }
                    }
                }
            } else {
                // Two groups, labelled, because the user's move on seeing a
                // figure is to ask whether anyone guessed it. The saved rows
                // print at `.stated` precision: a library row is a published
                // panel, and rounding 148 kcal to 150 would throw away the
                // exactness that is the whole reason the library exists (#594).
                if !checked.needsDetail {
                    itemGroup(
                        title: "Estimated from what you typed",
                        note: "Portions are assumed.",
                        items: checked.items,
                        precision: precision
                    )
                }
                itemGroup(
                    title: "From your saved items",
                    note: "Read off the label, not estimated.",
                    items: savedItems,
                    precision: .stated
                )
            }

            // Shown whenever there is anything to total. A needs-detail
            // estimate on its own has no numbers worth a row; the same estimate
            // beside a saved item does, because the saved item has them.
            if !checked.needsDetail || !savedItems.isEmpty {
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

            // Below the assumptions and above the day note: the assumptions say
            // what was guessed, this says what was not, and the pair is the
            // whole story of where the numbers came from (#594).
            MealSourcesBlock(sources: checked.groundingSources)

            if let dayNote {
                dayTargetBlock(dayNote)
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
            // Both chips, never one instead of the other. They answer different
            // questions: this one says the figures came from a published panel,
            // the confidence band still reports the PORTION, which a lookup does
            // not settle and which is where a text-derived estimate goes wrong
            // (#594).
            if checked.isGrounded {
                MealGrounding.chip()
            }
            MealFlagChip(
                MealFormat.confidenceBand(checked.confidence),
                tint: checked.confidence >= 0.75 ? Tokens.success : Tokens.muted
            )
        }
    }

    /// How this estimate's figures are printed. A grounded meal is not rounded
    /// as though its calories were worked out from an assumed portion (#594).
    private var precision: MealFormat.Precision {
        MealGrounding.precision(isGrounded: checked.isGrounded)
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
                value: MealFormat.calories(totals.calories, precision),
                variant: .accent,
                accessibilityText: "\(MealFormat.calories(totals.calories, precision)) kilocalories"
            )

            // Flowed rather than stacked in an HStack: four pills plus their
            // labels do not fit one line on a phone, and clipping a macro is
            // worse than wrapping it.
            ChipFlowLayout {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(totals[nutrient], for: nutrient)
                    )
                }
            }
        }
        .padding(.top, Space.xs)
    }

    /// One labelled group of item lines, used only when the meal has both
    /// estimated and saved rows. The note under the title is what does the
    /// work: it says whether the numbers beside it were guessed.
    private func itemGroup(
        title: String,
        note: String,
        items: [MealItemEntry],
        precision: MealFormat.Precision
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).eyebrow()
                Text(note)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                MealItemLine(item: item, precision: precision)
            }
        }
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
            // With saved items in the meal, "No food identified" is false: the
            // packets are identified and carry exact numbers. Only the typed
            // half failed, and saying so is the difference between a warning
            // the user can act on and one that looks like a bug.
            Text(savedItems.isEmpty ? "No food identified" : "The typed part was not identified")
                .font(.edHeading)
                .foregroundStyle(Tokens.warning)
            Text(savedItems.isEmpty
                 ? "Logging this keeps the description and the fact that you ate. Add detail later and re-estimate."
                 : "Your saved items still carry their own numbers. Add detail to the rest later and re-estimate.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which day this writes to, stated where the user commits (#592).
    ///
    /// Only on a day that is not today, and directly above the button rather
    /// than beside it. Beside it, the line competes with two controls for the
    /// width of a phone and is the part that truncates; above it, it has a full
    /// line and is the last thing read before the tap.
    ///
    /// This is the second of the two statements that let the composer leave
    /// today at all, the first being its own eyebrow. It is in the accent the
    /// section uses for meal type, so it is not read as a warning: logging onto
    /// an earlier day is the thing the user asked for, not a risk being flagged.
    private func dayTargetBlock(_ note: String) -> some View {
        Label(note, systemImage: "calendar")
            .font(.edFootnoteStrong)
            .foregroundStyle(Tokens.accentMeals)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    /// Discard sits immediately left of the primary, not marooned at the far
    /// edge in ghost styling. A destructive-ish action the user has to find is
    /// not an action they will take, and the pair reads as one decision.
    private var actions: some View {
        HStack(spacing: Space.sm) {
            Spacer(minLength: Space.sm)
            Button("Discard", action: onDiscard)
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
            // "Log it anyway" is the right words only when the meal has no
            // numbers at all. A saved item in the tray means it does.
            Button(checked.needsDetail && savedItems.isEmpty ? "Log it anyway" : "Log meal", action: onConfirm)
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
