import SwiftUI

/// A tab that exists and says what it will hold (#543).
///
/// Deliberately a real panel rather than a fall-through to an empty view. A tab
/// that renders nothing reads as a bug; a tab that says what it is for reads as
/// a plan.
struct MealsPlaceholderPanel: View {
    let title: String
    let systemImage: String
    let body1: String
    let body2: String

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text(title)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
            VStack(spacing: Space.sm) {
                Text(body1)
                Text(body2)
            }
            .font(.edFootnote)
            .foregroundStyle(Tokens.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }
}

/// History holds the historic charts, and #545 builds them.
///
/// This was `MealsTrendsPlaceholder` until #565. The two names were always one
/// slot: charts over the days you have logged ARE the history of this section,
/// and a Trends tab sitting beside a History tab came from misreading the
/// request. Renamed rather than kept alongside, so there is no second empty tab
/// waiting on content that has nowhere to come from.
///
/// Reading a single past day is not here. That is Today's job, through the
/// calendar in its date control, which is why the second body line says so.
struct MealsHistoryPlaceholder: View {
    var body: some View {
        MealsPlaceholderPanel(
            title: "History",
            systemImage: "chart.xyaxis.line",
            body1: "Charts over the days you have logged: a week and a month read together, so a single heavy day stops looking like a problem and a pattern starts to.",
            body2: "Not built yet: that is issue #545. To read one past day, tap the date at the top of Today."
        )
    }
}

/// Plan is a tab rather than its own section on purpose.
///
/// It reserves the slot, so the real feature is not a navigation redesign later.
/// It costs one view. And an empty sidebar row would clutter a twelve-section
/// list every day for something that does not exist.
struct MealsPlanPlaceholder: View {
    var body: some View {
        MealsPlaceholderPanel(
            title: "Plan",
            systemImage: "calendar.badge.clock",
            body1: "Meal plans are coming.",
            body2: "For now Dexter tracks what you actually ate, which is the half that has to be right first."
        )
    }
}
