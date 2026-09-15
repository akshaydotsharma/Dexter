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

/// Trends is #545. The balance analysis is not built here.
struct MealsTrendsPlaceholder: View {
    var body: some View {
        MealsPlaceholderPanel(
            title: "Trends",
            systemImage: "chart.xyaxis.line",
            body1: "A week and a month read together, so a single heavy day stops looking like a problem and a pattern starts to.",
            body2: "Not built yet. Keep logging and there will be something to read."
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
