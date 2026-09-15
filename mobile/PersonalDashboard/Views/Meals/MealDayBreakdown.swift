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
/// The composer. Estimating a meal onto a day that has ended is a legitimate
/// thing to want, but the primary path has to stay one field and one button, so
/// the composer belongs to Today alone and is not part of "a day".
struct MealDayBreakdown: View {

    let summary: MealDaySummary
    let targets: MealTargets?
    /// Changes only the empty sentence: "yet today" versus "on this day". The
    /// numbers, the card and the ordering are identical either way.
    let isToday: Bool
    /// The row an Activity deep-link just landed on, or nil. Held by the section
    /// because the pulse outlives the tab switch that brings this view on screen.
    let pulsedMealID: String?
    let onOpenMeal: (LocalMeal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            MealDayCard(summary: summary, targets: targets)
            mealList
        }
    }

    @ViewBuilder
    private var mealList: some View {
        let flagged = MealDuplicateCheck.flaggedIDs(among: summary.all)
        let rows = summary.orderedRows(flaggedAsDuplicate: flagged)
        if rows.isEmpty {
            Text(isToday
                 ? "Nothing logged yet today."
                 : "Nothing was logged on this day.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .padding(.vertical, Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: Space.sm) {
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
}
