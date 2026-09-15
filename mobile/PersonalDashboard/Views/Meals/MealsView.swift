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

    /// The row an Activity deep-link just landed on (#547). Held for ~600 ms,
    /// which is long enough to be seen and short enough not to read as a
    /// selection the user has to dismiss. Keyed on `clientUUID` because that is
    /// also the row's scroll id.
    @State private var pulsedMealID: String?

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
        // Activity / Today deep-link consumption. Both `onAppear` and
        // `onChange` are needed: on iOS the section is pushed and appears with
        // the focus already set, while on macOS the detail pane can already be
        // showing Meals when the focus is written.
        .onAppear { consumeFocus() }
        .onChange(of: router.focus) { _, _ in consumeFocus() }
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
        ScrollViewReader { proxy in
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
            // The scroll half of the deep-link. It runs on the pulse rather than on
            // the focus, because the focus may arrive while another tab is showing
            // and this reader is not mounted; the pulse survives that and fires the
            // scroll once the list is on screen. One run loop of slack lets the day
            // switch render its rows before we ask for one of them.
            .onChange(of: pulsedMealID) { _, id in scroll(proxy, to: id) }
            .onAppear { scroll(proxy, to: pulsedMealID) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Land a deep-link on its meal: switch to the day that holds it, put the
    /// Today tab in front of it, and pulse the row.
    ///
    /// Goes through the SAME `ActivityFocus` mechanism every other section
    /// uses, rather than a second navigation path. The id travels as a `UUID`
    /// there and is stored here as a string, so the match is case-insensitive:
    /// `MealService` lowercases what it writes, but a row that arrived from a
    /// peer or a tool call need not have.
    private func consumeFocus() {
        guard router.focus?.section == .meals, let focus = router.focus else { return }
        router.focus = nil
        guard let meal = allMeals.first(where: {
            $0.clientUUID.caseInsensitiveCompare(focus.id.uuidString) == .orderedSame
        }) else { return }

        tab = .today
        selectedDay = meal.deviceDay
        pulsedMealID = meal.clientUUID

        let id = meal.clientUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if pulsedMealID == id { pulsedMealID = nil }
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
                        onTap: { openMeal = meal },
                        isFocused: pulsedMealID == meal.clientUUID
                    )
                    .id(meal.clientUUID)
                }
            }
        }
    }

    // MARK: - Derived

    /// Meals on the selected day, in the order they were logged. Read off the
    /// summary rather than filtered again here, so the composer's duplicate
    /// check and the card's totals are looking at the same rows. The day match
    /// itself lives in `MealDaySummary.onDay`, where a stored UTC anchor is
    /// compared as a day and never as an instant (#506).
    private var mealsOnDay: [LocalMeal] { summary.all }

    /// Built through the shared selector, so this section and the Today card
    /// total one day exactly once (#547).
    private var summary: MealDaySummary {
        MealDaySummary.onDay(selectedDay, in: allMeals)
    }

    /// The targets in force on the selected day: the latest record that has
    /// already taken effect, or the earliest there is. Same rule as
    /// `MealService.targets(on:)`, read off the live query so the card repaints
    /// without a refetch.
    private var targetsInForce: MealTargets? {
        MealTargets.inForce(on: selectedDay, among: allTargets)
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
