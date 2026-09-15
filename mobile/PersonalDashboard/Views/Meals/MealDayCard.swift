import SwiftUI

/// One horizontal progress bar with a label, a value and, when there is a
/// target, a verdict (#543).
///
/// Hand-rolled the way the Finance category bars are, rather than a `Gauge` or a
/// `ProgressView`: those two carry platform chrome that changes between iOS and
/// macOS and cannot be tinted per verdict without fighting them. A capsule over
/// a capsule is two shapes and looks identical on both platforms.
struct MealNutrientBar: View {
    let nutrient: Nutrient
    let value: Double
    /// Nil when no targets are set. The bar then draws no track and no verdict,
    /// only the number.
    let target: Double?

    private var verdict: MealVerdict? {
        guard let target else { return nil }
        return nutrient.verdict(value: value, target: target)
    }

    /// How much of the track is filled. Clamped at 1 so a day at 180% does not
    /// paint outside the card; the verdict carries the fact that it is over.
    private var fraction: Double {
        guard let target, target > 0 else { return 0 }
        return min(max(value / target, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(nutrient.displayName)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer(minLength: Space.sm)
                Text(valueText)
                    .font(.edFootnoteStrong)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
            }

            if let target, target > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Tokens.paper2)
                        Capsule()
                            .fill(verdict?.tint ?? Tokens.accentMeals)
                            .frame(width: max(geo.size.width * fraction, fraction > 0 ? 3 : 0))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var valueText: String {
        guard let target, target > 0 else {
            return MealFormat.value(value, for: nutrient)
        }
        return "\(MealFormat.grams(value)) / \(MealFormat.grams(target)) \(nutrient.unit)"
    }

    private var accessibilityText: String {
        guard let target, target > 0, let verdict else {
            return "\(nutrient.displayName), \(MealFormat.value(value, for: nutrient))"
        }
        return "\(nutrient.displayName), \(MealFormat.grams(value)) of \(MealFormat.grams(target)) \(nutrient.unit), \(verdict.label)"
    }
}

/// The day's numbers, at the top of Today (#543).
///
/// ### Bars, not a ring
///
/// A ring encodes one number well and eight badly. This card carries calories,
/// four macros and three ceilings, and every one of them has to be readable
/// beside the others. Stacked bars also match the Finance dashboard's own
/// hand-rolled category bars, so the two surfaces read as one app.
///
/// ### With no targets set
///
/// Targets are #544 and may never have been run. The card then shows the totals
/// and NOTHING else: no tracks, no verdicts, no implied "you are doing well".
/// Logging is never blocked on setup, so a day still adds up on the first
/// morning the feature is opened.
struct MealDayCard: View {
    let summary: MealDaySummary
    let targets: MealTargets?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            if summary.isUnlogged {
                unloggedNote
            } else {
                calorieBlock
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                // Addition 3: the bar stack gets a label, because the Watch row
                // below it has one and an unlabelled stack beside a labelled
                // one reads as an oversight. To revert, drop the eyebrow line
                // and the VStack around it.
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Macros").eyebrow()
                    // Fibre joins the three macros because it is a floor most
                    // days miss and nothing else on the card shows it.
                    //
                    // The treatment forks on whether a target exists, because a
                    // bar with no target has no track to draw: it degrades to a
                    // bare label-and-value row, directly above a Watch row of
                    // pills carrying exactly the same kind of fact. Two
                    // treatments for one kind of data, and the bar's whole
                    // justification (it carries proportion) is the part that
                    // went missing. With no target the pill is the honest mark;
                    // once a target exists the bar earns its place back.
                    if targets == nil {
                        HStack(spacing: Space.sm) {
                            ForEach(Nutrient.macrosInOrder) { nutrient in
                                MealStatPill(
                                    nutrient: nutrient,
                                    value: summary.totals[nutrient],
                                    target: nil,
                                    fillsWidth: true
                                )
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(Nutrient.macrosInOrder) { nutrient in
                                MealNutrientBar(
                                    nutrient: nutrient,
                                    value: summary.totals[nutrient],
                                    target: target(for: nutrient)
                                )
                            }
                        }
                    }
                }
                watchRow
                if !summary.excluded.isEmpty {
                    excludedNote
                }
            }

            if targets == nil && !summary.isUnlogged {
                noTargetsNote
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text("The day").eyebrow()
            Spacer(minLength: Space.sm)
            if !summary.isUnlogged {
                Text(mealCountText)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
        }
    }

    private var mealCountText: String {
        let counted = summary.counted.count
        let noun = counted == 1 ? "meal" : "meals"
        if summary.excluded.isEmpty {
            return "\(counted) \(noun)"
        }
        return "\(counted) \(noun) counted, \(summary.excluded.count) held back"
    }

    /// The headline. Calories first and largest, because it is the one number
    /// that answers "how is today going" on its own.
    private var calorieBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(summary.totals.calories))
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .tracking(-0.6)
                    .monospacedDigit()
                Text("kcal").eyebrow()
                Spacer(minLength: Space.sm)
                if let remainder = remainderText {
                    // The number a next meal is chosen against. At edFootnote
                    // beside a 28pt figure it was not one of the two numbers
                    // this row exists to give.
                    Text(remainder)
                        .font(.edBodyMedium)
                        .foregroundStyle(remainderTint)
                        .monospacedDigit()
                }
            }

            if let calorieTarget = target(for: .calories), calorieTarget > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.paper2)
                        Capsule()
                            .fill(calorieVerdict?.tint ?? Tokens.accentMeals)
                            .frame(
                                width: max(
                                    geo.size.width * min(summary.totals.calories / calorieTarget, 1),
                                    summary.totals.calories > 0 ? 3 : 0
                                )
                            )
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var calorieVerdict: MealVerdict? {
        guard let calorieTarget = target(for: .calories) else { return nil }
        return Nutrient.calories.verdict(value: summary.totals.calories, target: calorieTarget)
    }

    /// "820 left" or "180 over". Spelled out rather than shown as a percentage,
    /// because the remainder is the number a next meal is chosen against.
    private var remainderText: String? {
        guard let calorieTarget = target(for: .calories), calorieTarget > 0 else { return nil }
        let delta = calorieTarget - summary.totals.calories
        if delta >= 0 {
            return "\(MealFormat.calories(delta)) left"
        }
        return "\(MealFormat.calories(-delta)) over"
    }

    private var remainderTint: Color {
        guard let calorieTarget = target(for: .calories), calorieTarget > 0 else { return Tokens.muted }
        return summary.totals.calories > calorieTarget ? Tokens.danger : Tokens.muted
    }

    private var watchRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Watch").eyebrow()
            HStack(spacing: Space.sm) {
                ForEach(Nutrient.ceilingsInOrder) { nutrient in
                    MealStatPill(
                        nutrient: nutrient,
                        value: summary.totals[nutrient],
                        target: target(for: nutrient),
                        fillsWidth: true
                    )
                }
            }
        }
    }

    /// A day nobody logged is not a day of nothing. Said in words, because the
    /// alternative — a card of zeros — is exactly the reading this has to
    /// prevent.
    private var unloggedNote: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Not logged")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
            // In this state it is the card's entire content, so it is set at
            // reading size rather than as a footnote under a heading.
            Text("No meals were recorded on this day. That is different from a day that came to very little.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var excludedNote: some View {
        Text(
            summary.excluded.count == 1
                ? "One meal is held out of these totals until it is corrected."
                : "\(summary.excluded.count) meals are held out of these totals until they are corrected."
        )
        .font(.edFootnote)
        .foregroundStyle(Tokens.warning)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var noTargetsNote: some View {
        Text("No targets set, so these are totals only. Set your targets to see how a day is tracking.")
            .font(.edFootnote)
            .foregroundStyle(Tokens.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func target(for nutrient: Nutrient) -> Double? {
        guard let targets else { return nil }
        let value = targets.target(for: nutrient)
        return value > 0 ? value : nil
    }
}
