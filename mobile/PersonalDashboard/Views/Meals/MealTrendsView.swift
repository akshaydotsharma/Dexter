import SwiftUI

/// Period presets, as a row of chips plus a Custom control (#545).
///
/// Its own view rather than a reuse of `FinanceFilterBar`: that one carries
/// category, person, event, merchant and import-source multi-selects that have
/// no counterpart here, and a filter bar whose only dimension is the date does
/// not need a sheet to hold one more.
struct MealTrendsFilterBar: View {
    @Binding var selection: MealTrendSelection

    @State private var showingCustom = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(MealTrendPeriod.presets) { preset in
                    chip(
                        label: preset.displayName,
                        icon: nil,
                        selected: selection.period == preset,
                        action: { selection.period = preset }
                    )
                }
                chip(
                    label: customLabel,
                    icon: "calendar",
                    selected: selection.period == .custom,
                    action: { showingCustom = true }
                )
                // macOS anchors a popover to the chip that opened it; iOS takes
                // a detented sheet. Copied from `FinanceFilterBar` rather than
                // invented: `presentationDetents` do nothing on macOS, and the
                // sheet there renders as a small centred window that clips its
                // own content (#341).
                #if os(macOS)
                .popover(isPresented: $showingCustom, arrowEdge: .bottom) {
                    customPicker.frame(width: 320, height: 210)
                }
                #endif
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.xs)
        }
        #if os(iOS)
        .sheet(isPresented: $showingCustom) {
            customPicker
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    private var customLabel: String {
        guard selection.period == .custom else { return "Custom" }
        return selection.bandLabel()
    }

    private var customPicker: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Custom range").eyebrow()
            DatePicker(
                "From",
                selection: $selection.customStart,
                in: ...Date(),
                displayedComponents: .date
            )
            DatePicker(
                "To",
                selection: $selection.customEnd,
                in: ...Date(),
                displayedComponents: .date
            )
            Button("Apply") {
                selection.period = .custom
                showingCustom = false
            }
            .buttonStyle(.borderedProminent)
            .tint(Tokens.accentMeals)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(
        label: String,
        icon: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.edFootnote)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Tokens.accentFg : Tokens.inkSoft)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(
                selected ? Tokens.accentMeals : Tokens.surface,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The Trends tab (#545).
///
/// ### The shape
///
/// A filter bar of period presets, a collapsed band, and an expandable panel —
/// the Finance dashboard's shape, because this answers the same class of
/// question about a different table and a reader who knows one should not have
/// to learn the other.
///
/// ### Zero API calls
///
/// Nothing on this surface calls anything. `MealInsights.build` is arithmetic
/// over the rows the section already holds and the targets record beside them,
/// so a period change, a meal edit, an expand and a collapse all cost one pass
/// over the meals and nothing else. The single call in the tab is the one
/// "Ask Dexter about this" makes when it is pressed.
///
/// ### The rows are never re-queried per row
///
/// `allMeals` and `allTargets` arrive from the section's `@Query`s and are
/// passed down as plain arrays. No row view here declares a query of its own:
/// #442 cost Finance seconds of blocked main thread because two per-row queries
/// multiplied by row count inside an eager stack, and the fix is structural, not
/// a thing to remember.
struct MealTrendsView: View {
    let allMeals: [LocalMeal]
    let allTargets: [MealTargets]
    @Bindable var router: AppRouter

    @State private var selection = MealTrendSelection()
    @State private var includePartialDays = false
    @State private var isExpanded = true

    /// The one computed value both the band and the panel read.
    @State private var insights: MealInsights = .empty
    @State private var hasComputed = false

    var body: some View {
        VStack(spacing: 0) {
            MealTrendsFilterBar(selection: $selection)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if hasComputed {
                        MealTrendsBand(
                            insights: insights,
                            headerLabel: selection.bandLabel(),
                            isExpanded: $isExpanded,
                            includePartialDays: $includePartialDays,
                            onAskDexter: askDexter
                        )
                    } else {
                        MealTrendsBandPlaceholder(headerLabel: selection.bandLabel())
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
            }
        }
        // ONE recompute per input change, never one per body pass (#442). The
        // signature hashes exactly the fields the aggregation reads, which is
        // what makes skipping a recompute SAFE and not merely fast: if none of
        // them changed, no day bucket, no average and no band can have changed.
        // A cheaper key like `allMeals.count` would silently miss an edit to a
        // three-week-old meal's calories.
        .task(id: dataSignature) {
            insights = MealInsights.build(
                meals: allMeals,
                targets: MealTargets.inForce(on: Date(), among: allTargets),
                range: selection.resolvedRange(),
                includePartialDays: includePartialDays
            )
            hasComputed = true
        }
    }

    // MARK: - Recompute key

    private var dataSignature: Int {
        var hasher = Hasher()
        hasher.combine(selection)
        hasher.combine(includePartialDays)
        hasher.combine(allMeals.count)
        for meal in allMeals {
            hasher.combine(meal.date)
            hasher.combine(meal.mealType)
            hasher.combine(meal.source)
            hasher.combine(meal.isSuspect)
            hasher.combine(meal.needsDetail)
            for nutrient in Nutrient.allCases { hasher.combine(meal.value(for: nutrient)) }
        }
        hasher.combine(allTargets.count)
        for record in allTargets {
            hasher.combine(record.effectiveFrom)
            for nutrient in Nutrient.allCases { hasher.combine(record.target(for: nutrient)) }
        }
        return hasher.finalize()
    }

    // MARK: - Ask Dexter

    /// Hand the COMPUTED insights to chat, as text, and let the chat surface
    /// make the one call.
    ///
    /// The prompt is built from the same value the screen is drawn from, so the
    /// model is asked about the numbers the user is looking at. Nothing is
    /// called here: the call happens once, in `ChatView`, when the prompt lands.
    private func askDexter() {
        router.pendingChatPrompt = insights.chatPrompt(periodLabel: selection.bandLabel())
        router.go(to: .chat)
    }
}
