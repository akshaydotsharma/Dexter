import SwiftUI

/// The day's meals, on the Today surface (#547).
///
/// ### It reads the summary, it does not total anything
///
/// Every number here comes off `MealDaySummary`, which is where the line
/// between a meal that counts and a meal that does not is drawn. A suspect meal
/// has numbers known to be wrong and a needs-detail meal has none at all, and
/// both are held out of the total. A card that summed its own rows would fold
/// them back in, so Today and the Meals section would print two different
/// figures for one day with nothing on either screen to say which was right.
///
/// ### It is a shorter MealDayCard, not a different one
///
/// Calories are the headline with the bar under them, the four macros are the
/// row below, and the meal count rides in the card's eyebrow the way every
/// other Today card's count does. The three ceilings, the per-nutrient bars and
/// the assumptions all stay in the Meals section: this card answers "how is
/// today going" and hands off for anything past that.
///
/// The headline figure is `.edTitle` rather than the section card's
/// `.edDisplay` because the Today header already owns `.edDisplay` on this
/// surface, and two display figures one above the other read as two headers.
///
/// ### With no targets set
///
/// Totals and the count, and nothing else: no track, no remainder, no verdict
/// hue. Targets may never have been derived, and logging is never blocked on
/// setup.
struct TodayMealsCard: View {

    /// The day, already totalled. Built by the caller through
    /// `MealDaySummary.onDay`, the same call the Meals section makes.
    let summary: MealDaySummary

    /// The targets in force today, or nil when none have been set.
    let targets: MealTargets?

    /// Opens the Meals section.
    let onOpen: () -> Void

    var body: some View {
        TodayCard(
            section: .meals,
            title: "Meals",
            // The COUNTED meals, not every row: the figure above it is the
            // total of exactly these, and a count that included a held-back
            // meal would make "3 meals, 900 kcal" read as a light day rather
            // than as a day with a question outstanding.
            count: summary.counted.count,
            countLabel: "logged",
            // Nothing to wait for: the rows arrive on a live query, so there is
            // no first paint with an empty store behind it.
            isLoading: false,
            isEmpty: summary.isUnlogged,
            emptyText: "Nothing logged yet today.",
            // Unlike Tasks, Notes and Lists, this card is empty every morning
            // rather than only when the user owns none of the thing. Dropping
            // the footer with the numbers would take the way into Meals off
            // Today at exactly the hour it is most wanted.
            keepsFooterWhenEmpty: true
        ) {
            VStack(alignment: .leading, spacing: Space.md) {
                calorieBlock
                macroRow
                if !summary.excluded.isEmpty {
                    heldBackNote
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        } footer: {
            TodayCardFooter(label: "All meals", onTap: onOpen)
        }
    }

    // MARK: - Pieces

    /// The headline: the day's calories, what is left of the target, and the
    /// bar. The bar and the remainder both disappear when there is no target,
    /// which is the whole of the no-targets state.
    private var calorieBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(summary.totals.calories))
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                Text("kcal").eyebrow()
                Spacer(minLength: Space.sm)
                if let remainder = remainderText {
                    Text(remainder)
                        .font(.edFootnote)
                        .foregroundStyle(remainderTint)
                        .monospacedDigit()
                }
            }

            if let calorieTarget, calorieTarget > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.paper2)
                        Capsule()
                            // The hue is the verdict's and nothing else's. The
                            // accent is only the no-verdict fallback, which a
                            // non-nil target makes unreachable.
                            .fill(calorieVerdict?.tint ?? Tokens.accentMeals)
                            .frame(
                                width: max(
                                    geo.size.width * min(summary.totals.calories / calorieTarget, 1),
                                    summary.totals.calories > 0 ? 3 : 0
                                )
                            )
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The four the day is steered by, in the fixed order every Meals surface
    /// prints them. Pills rather than bars because this card is a glance and
    /// four stacked bars would make it the tallest thing on Today; a rounded
    /// rectangle is the shape that means "a quantity" throughout this feature,
    /// and it carries the verdict when a target exists.
    private var macroRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(Nutrient.macrosInOrder) { nutrient in
                MealStatPill(
                    nutrient: nutrient,
                    value: summary.totals[nutrient],
                    target: target(for: nutrient),
                    fillsWidth: true
                )
            }
        }
    }

    /// Says the total is short on purpose. Without it the card would under-count
    /// silently, which is the one failure `MealDaySummary` exists to prevent.
    private var heldBackNote: some View {
        Text(
            summary.excluded.count == 1
                ? "One meal is held out of this total until it is corrected."
                : "\(summary.excluded.count) meals are held out of this total until they are corrected."
        )
        .font(.edCaption)
        .foregroundStyle(Tokens.warning)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Derived

    private var calorieTarget: Double? { target(for: .calories) }

    private var calorieVerdict: MealVerdict? {
        guard let calorieTarget else { return nil }
        return Nutrient.calories.verdict(value: summary.totals.calories, target: calorieTarget)
    }

    /// "820 left" or "180 over" — the number a next meal is chosen against.
    private var remainderText: String? {
        guard let calorieTarget, calorieTarget > 0 else { return nil }
        let delta = calorieTarget - summary.totals.calories
        if delta >= 0 {
            return "\(MealFormat.calories(delta)) left"
        }
        return "\(MealFormat.calories(-delta)) over"
    }

    private var remainderTint: Color {
        guard let calorieTarget, calorieTarget > 0 else { return Tokens.muted }
        return summary.totals.calories > calorieTarget ? Tokens.danger : Tokens.muted
    }

    private func target(for nutrient: Nutrient) -> Double? {
        guard let targets else { return nil }
        let value = targets.target(for: nutrient)
        return value > 0 ? value : nil
    }
}
