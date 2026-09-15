import SwiftUI
import SwiftData

/// The three tabs inside Meals (#543).
enum MealsTab: String, CaseIterable, Identifiable {
    case today
    case trends
    case plan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today:  return "Today"
        case .trends: return "Trends"
        case .plan:   return "Plan"
        }
    }
}

/// Meal logging v1 (#543).
///
/// ### What this surface is
///
/// You describe a meal in words, Claude estimates its nutrition, and the day
/// adds up in front of you. Two things separate it from a food-tracking app:
/// there is no database search, no portion picker and no serving dropdown,
/// because the description is the input; and the numbers are honest about being
/// estimates, so calories round to the nearest 10 and every meal carries a
/// confidence.
///
/// ### The three tabs
///
/// Today is built here. Trends is #545 and Plan has no feature behind it at all
/// — both render a panel saying so. Plan is a TAB rather than a section because
/// that reserves the slot without adding a permanently empty row to a
/// twelve-section sidebar.
///
/// ### Targets
///
/// `MealTargets` is read when a record exists and ignored when it does not
/// (#544 builds the derivation). Logging is never blocked on setup: with no
/// targets the day card shows totals and no bars.
struct MealsView: View {
    @Bindable var router: AppRouter

    @Environment(\.modelContext) private var modelContext

    /// Every meal, sorted the way the log reads: by day, then by the instant
    /// inside it. Filtered to the selected day in memory — the day comparison is
    /// a stored-day equality, which a `#Predicate` cannot express, and this is a
    /// personal-scale table.
    @Query(
        sort: [
            SortDescriptor(\LocalMeal.date, order: .forward),
            SortDescriptor(\LocalMeal.loggedAt, order: .forward)
        ]
    ) private var allMeals: [LocalMeal]

    /// v1 only ever holds one record. Queried rather than fetched so the card
    /// repaints the moment #544 writes one.
    @Query(sort: [SortDescriptor(\MealTargets.effectiveFrom, order: .forward)])
    private var allTargets: [MealTargets]

    @State private var tab: MealsTab = .today

    /// The day on screen, device-local midnight. A stepper moves it back; it
    /// never moves past today, because a meal you have not eaten is not a log
    /// entry.
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    @State private var openMeal: LocalMeal?

    /// The derive-review-save flow (#544). Opened from the setup card when no
    /// targets exist and from the targets row once they do.
    @State private var showingTargets = false

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // iOS carries its own in-view bar; macOS puts the title in the
                // native window toolbar via `.macSectionChrome` below (#283).
                #if os(iOS)
                TopBar(
                    title: "Meals",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )
                #endif

                tabBar

                switch tab {
                case .today:  todayTab
                case .trends: scrolling { MealsTrendsPlaceholder() }
                case .plan:   scrolling { MealsPlanPlaceholder() }
                }
            }
        }
        .activeSection(.meals)
        .macSectionChrome("Meals")
        .sheet(item: $openMeal) { meal in
            MealDetailSheet(meal: meal)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(isPresented: $showingTargets) {
            MealTargetsSheet()
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    // MARK: - Chrome

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(MealsTab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.sm)
        .accessibilityLabel("Meals view")
    }

    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
        }
    }

    // MARK: - Today

    private var todayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                // Pinned above everything while no targets exist (#544). It is
                // an offer, not a wall: the composer and the day card below it
                // work exactly the same before and after it is answered.
                if targetsInForce == nil {
                    MealTargetsSetupCard { showingTargets = true }
                }

                dateStepper

                // The composer only appears on today. Estimating a meal onto a
                // day that has ended is a legitimate thing to want, but the
                // primary path has to stay one field and one button, and a
                // composer that silently logs to March is worse than one that is
                // not there.
                if isToday {
                    MealComposer(
                        day: selectedDay,
                        existingOnDay: mealsOnDay,
                        onLogged: { _ in }
                    )
                }

                MealDayCard(summary: summary, targets: targetsInForce)

                mealList

                // Once targets exist the setup card is replaced by a quiet row
                // at the foot of the tab, which is where you go to re-derive
                // after a weight change.
                if let targets = targetsInForce {
                    MealTargetsRow(targets: targets) { showingTargets = true }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xxl)
            .padding(.top, Space.xs)
        }
    }

    private var dateStepper: some View {
        HStack(spacing: Space.sm) {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.inkSoft)
            .accessibilityLabel("Previous day")

            VStack(spacing: 0) {
                // Addition 4: the navigation anchor for the whole tab, so it
                // sits above the meal row kcal figures it governs rather than
                // level with them. To revert, put back `.edBodyMedium`.
                Text(dayTitle)
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                Text(Self.dayFormatter.string(from: selectedDay))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
            .frame(maxWidth: .infinity)

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isToday ? Tokens.mutedSoft : Tokens.inkSoft)
            .disabled(isToday)
            .accessibilityLabel("Next day")
        }
        .padding(.vertical, Space.xs)
    }

    @ViewBuilder
    private var mealList: some View {
        let flagged = MealDuplicateCheck.flaggedIDs(among: mealsOnDay)
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
                        onTap: { openMeal = meal }
                    )
                }
            }
        }
    }

    // MARK: - Derived

    /// Meals on the selected day. Matched through `WallClock.isSameStoredDay`,
    /// so a stored UTC anchor is compared as a day and never as an instant
    /// (#506).
    private var mealsOnDay: [LocalMeal] {
        let anchor = WallClock.dayAnchor(from: selectedDay)
        return allMeals.filter { WallClock.isSameStoredDay($0.date, anchor) }
    }

    private var summary: MealDaySummary {
        MealDaySummary(meals: mealsOnDay)
    }

    /// The targets in force on the selected day: the latest record that has
    /// already taken effect, or the earliest there is. Same rule as
    /// `MealService.targets(on:)`, read off the live query so the card repaints
    /// without a refetch.
    private var targetsInForce: MealTargets? {
        let anchor = WallClock.dayAnchor(from: selectedDay)
        return allTargets.last { WallClock.startOfStoredDay($0.effectiveFrom) <= anchor }
            ?? allTargets.first
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDay) { return "Today" }
        if calendar.isDateInYesterday(selectedDay) { return "Yesterday" }
        return Self.weekdayFormatter.string(from: selectedDay)
    }

    private func step(_ days: Int) {
        let calendar = Calendar.current
        guard let moved = calendar.date(byAdding: .day, value: days, to: selectedDay) else { return }
        guard moved <= calendar.startOfDay(for: Date()) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            selectedDay = calendar.startOfDay(for: moved)
        }
    }

    /// `selectedDay` is a device-local midnight, never a stored anchor, so a
    /// device-local formatter is correct here.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
}
