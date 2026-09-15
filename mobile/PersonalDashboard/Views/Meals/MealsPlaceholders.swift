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
/// Reading a single past day is not here. That is the date control's job, which
/// is why the second body line says where it now lives (#567).
struct MealsHistoryPlaceholder: View {
    var body: some View {
        MealsPlaceholderPanel(
            title: "History",
            systemImage: "chart.xyaxis.line",
            body1: "Charts over the days you have logged: a week and a month read together, so a single heavy day stops looking like a problem and a pattern starts to.",
            body2: "Not built yet: that is issue #545. To read one past day, use the date control at the top of the screen."
        )
    }
}

/// The charts, presented over whatever Meals was showing (#567).
///
/// History stopped being a tab because it is somewhere you look and come back
/// from, not somewhere the content settles. That makes it a presentation, and a
/// presentation needs a way out, which a tab never did: hence the Done button
/// this wrapper adds around the panel.
///
/// The macOS frame is not optional. A SwiftUI sheet on macOS sizes to its
/// content, and a panel that only states what is coming collapses to little more
/// than its own toolbar without an explicit size (#474 hit this three times).
struct MealsHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()
                ScrollView {
                    MealsHistoryPlaceholder()
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.xl)
                }
            }
            .navigationTitle("History")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .trailingBar) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
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
