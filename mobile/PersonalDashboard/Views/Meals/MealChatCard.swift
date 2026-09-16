import SwiftUI

/// The card chat shows after `log_meal` or `update_meal` lands (#546).
///
/// ### Why this is not the generic result card
///
/// Every other chat result answers "did it save". A meal has to answer "and
/// where does that leave me", because the remaining-today line is what turns a
/// logging action into an immediate answer, which is what makes the NEXT log
/// happen. A generic title-and-chips card cannot carry a headline figure, four
/// macros and a verdict without becoming one.
///
/// ### Everything here is a value, nothing is fetched
///
/// The card renders `MealLogSummary`, computed in the executor at the moment of
/// the write. It never reads the store: a view that re-fetched would show
/// different numbers from the ones the dialog spoke the instant a later meal
/// landed, and the card is a record of a moment, not a live tile.
struct MealChatCard: View {
    let summary: MealLogSummary
    /// Only set when the summary offers it — a dinner or snack logged between
    /// 00:00 and 03:59. Never fires on its own.
    var onMoveToYesterday: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            if summary.needsDetail {
                needsDetailBody
            } else {
                headline
                macroRow
            }

            if !summary.portionsLine.isEmpty {
                // Collapsed to one line on purpose: the full breakdown is a tap
                // away in the Meals detail sheet, and a chat thread that listed
                // five dishes per meal would stop being a conversation.
                Text(summary.portionsLine)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Assumed portions: \(summary.portionsLine)")
            }

            flags

            if let line = remainingLine {
                Text(line)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(Tokens.ink)
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
        HStack(spacing: Space.xs) {
            Text(eyebrow)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Tokens.muted)
            Spacer(minLength: 0)
            // The date is shown whenever it is NOT today. A silently misdated
            // meal corrupts two days at once and neither one looks wrong, so
            // the one moment the user can still catch it is here.
            if !summary.isToday {
                MealFlagChip(summary.dayLabel(), systemImage: "calendar", tint: Tokens.accentMeals)
            }
        }
    }

    private var eyebrow: String {
        "Logged · \(summary.mealType.displayName)"
    }

    /// How this meal's figures are printed, decided the one way every Meals
    /// surface decides it (#594).
    private var precision: MealFormat.Precision {
        MealGrounding.precision(isGrounded: summary.isGrounded)
    }

    // MARK: - The numbers

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(MealFormat.calories(summary.nutrients.calories, precision))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
            Text("kcal")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
            Spacer(minLength: 0)
            // Chat says what the composer's preview says about the same branded
            // meal, or one description gets two answers depending on which
            // surface logged it (#594).
            if summary.isGrounded {
                MealGrounding.chip()
            }
            MealFlagChip(
                MealFormat.confidenceBand(summary.confidence),
                systemImage: "gauge.medium",
                tint: summary.confidence < 0.45 ? Tokens.warning : Tokens.muted
            )
        }
        .accessibilityElement(children: .combine)
    }

    /// The four the day is steered by, in the fixed order every Meals surface
    /// prints them. Never sorted by value — position is how a nutrient is
    /// identified once colour has been spent on the verdict.
    private var macroRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(Nutrient.macrosInOrder) { nutrient in
                MealStatPill(
                    label: nutrient.displayName,
                    value: MealFormat.value(
                        summary.nutrients[nutrient],
                        for: nutrient,
                        precision: precision
                    ),
                    variant: .neutral,
                    fillsWidth: true
                )
            }
        }
    }

    private var needsDetailBody: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(summary.mealDescription)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
            Text("Saved without numbers — I could not tell what was in it. Open Meals to fill it in.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Flags

    @ViewBuilder
    private var flags: some View {
        let chips = flagChips
        if !chips.isEmpty {
            HStack(spacing: Space.sm) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    MealFlagChip(chip.text, systemImage: chip.icon, tint: chip.tint)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct FlagChip {
        let text: String
        let icon: String
        let tint: Color
    }

    private var flagChips: [FlagChip] {
        var chips: [FlagChip] = []
        if summary.wasDateClampedFromFuture {
            chips.append(FlagChip(
                text: "Date was in the future — used today",
                icon: "calendar.badge.exclamationmark",
                tint: Tokens.warning
            ))
        }
        if let minutes = summary.duplicateMinutesAgo {
            // Both rows are kept. The flag is a remark, never a block: people
            // do drink two coffees, and a capture path that refused the second
            // one would be a capture path that has stopped working.
            chips.append(FlagChip(
                text: "Similar to a meal \(MealLogSummary.spelledMinutes(minutes))",
                icon: "doc.on.doc",
                tint: Tokens.muted
            ))
        }
        if summary.suspectReason != nil {
            chips.append(FlagChip(text: "Flagged, not counted", icon: "exclamationmark.triangle", tint: Tokens.danger))
        }
        return chips
    }

    // MARK: - Left today

    /// "1,140 kcal and 82 g protein left today", or nil when no targets are
    /// set. Nil rather than a zero: an unset target is not a target of zero,
    /// and printing "0 left" would read as a day already blown.
    private var remainingLine: String? {
        guard summary.isToday else { return nil }
        guard let calories = summary.caloriesRemaining, let protein = summary.proteinRemaining else {
            return nil
        }
        let caloriePart = calories >= 0
            ? "\(MealFormat.calories(calories)) kcal"
            : "\(MealFormat.calories(-calories)) kcal over"
        let proteinPart = protein > 0
            ? "\(MealFormat.grams(protein)) g protein"
            : "protein target met"
        return calories >= 0
            ? "\(caloriePart) and \(proteinPart) left today"
            : "\(caloriePart), \(proteinPart) left today"
    }

    // MARK: - Bottom row

    @ViewBuilder
    private var bottomRow: some View {
        HStack(spacing: Space.sm) {
            // Offered, never applied automatically. A 1am snack usually belongs
            // to the day that just ended, but guessing wrong is invisible on
            // both days and the user has no reason to go looking.
            if summary.offersYesterdayMove, let onMoveToYesterday {
                Button("Add to yesterday instead?", action: onMoveToYesterday)
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            }
            Spacer(minLength: 0)
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text("Go to meal")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .regular))
                    }
                }
                .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            }
        }
    }
}
