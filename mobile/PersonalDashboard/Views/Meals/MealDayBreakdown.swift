import SwiftUI

/// One day, read in full: the card of numbers and the meals behind them (#559).
///
/// ### Why this is a component and not two calls in two tabs
///
/// Today and History both show a day. Before #559 there was one tab, so the day
/// card and the meal list sat inline in `MealsView` and there was nothing to keep
/// in step. With two tabs showing the same thing, an inline copy in each is a
/// copy that will drift: the empty sentence gets reworded in one, the duplicate
/// flagging gets a rule in the other, and the same day starts reading differently
/// depending on which tab you reached it from.
///
/// So the day is one view taking one `MealDaySummary`, and both tabs hand it one.
/// Neither tab can render a day the other cannot.
///
/// ### What stays outside it
///
/// The composer, which since #592 appears on every day this view can be handed.
/// It is still not part of "a day", and the reason is a division of jobs rather
/// than a restriction: this view reads a day and the composer writes to one. A
/// caller that only wants to show a day gets one, without also offering a write
/// it did not ask for.
///
/// The composer also has to state the day it is writing to, which is its own
/// label's job and would be a second, quieter claim if it were made down here in
/// the read-only card.
struct MealDayBreakdown: View {

    let summary: MealDaySummary
    let targets: MealTargets?
    /// Changes only the empty sentence: "today" versus "on this day". The
    /// numbers, the card and the ordering are identical either way.
    let isToday: Bool
    /// The row an Activity deep-link just landed on, or nil. Held by the section
    /// because the pulse outlives the tab switch that brings this view on screen.
    let pulsedMealID: String?
    let onOpenMeal: (LocalMeal) -> Void

    var body: some View {
        if summary.isUnlogged {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Space.lg) {
                MealDayCard(summary: summary, targets: targets)
                mealList
            }
        }
    }

    /// A day with nothing on it, said once (#633).
    ///
    /// ### Why the card goes with the sentence
    ///
    /// This state used to be three statements of one fact: a "Not logged"
    /// heading, a paragraph under it drawing the distinction between a blank day
    /// and a light one, and a third line below the card repeating it. All three
    /// sat inside or under a bordered card whose job is to carry the day's
    /// figures, and a day with no figures gives it nothing to hold. The card
    /// became a box around a sentence.
    ///
    /// The distinction that paragraph was making is a real one and it is still
    /// made, where it can be read at a glance rather than explained: the
    /// calendar draws an unlogged day differently from a light one, and Trends
    /// counts unlogged days as their own figure. It does not need a paragraph
    /// on the day itself.
    ///
    /// Centred, because with the card gone there is no left edge for it to
    /// belong to. The composer sits directly above; this is the answer to
    /// "and what is below it", not a label on anything.
    private var emptyState: some View {
        Text(isToday ? "No meals logged today" : "No meals logged on this day")
            .font(.edSubheadline)
            .foregroundStyle(Tokens.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xl)
    }

    private var mealList: some View {
        let flagged = MealDuplicateCheck.flaggedIDs(among: summary.all)
        let rows = summary.orderedRows(flaggedAsDuplicate: flagged)
        // No empty branch here any more. `orderedRows` is a permutation of
        // `summary.all`, so it is empty exactly when `isUnlogged` is true, and
        // that case never reaches this far.
        return VStack(spacing: Space.sm) {
            ForEach(rows) { meal in
                MealRow(
                    meal: meal,
                    isDuplicate: flagged.contains(meal.clientUUID),
                    onTap: { onOpenMeal(meal) },
                    isFocused: pulsedMealID == meal.clientUUID
                )
                .id(meal.clientUUID)
            }
        }
    }
}
