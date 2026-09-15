import SwiftUI
import SwiftData

/// The five tabs inside Meals (#543, widened in #559).
///
/// Today held five jobs at once before #559: the composer, the day total, the
/// meal log, a day stepper and the targets card, with targets appearing in two
/// different places depending on whether they had been set. Logging a meal and
/// browsing the past are two different visits to this section, and neither had a
/// surface of its own. History and Targets are those two surfaces.
enum MealsTab: String, CaseIterable, Identifiable {
    case today
    case history
    case trends
    case plan
    case targets

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today:   return "Today"
        case .history: return "History"
        case .trends:  return "Trends"
        case .plan:    return "Plan"
        case .targets: return "Targets"
        }
    }
}

/// Meal logging v1 (#543), restructured into five tabs (#559).
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
/// ### The five tabs
///
/// Today is strictly today: the composer, the day card and today's meals.
/// History is the day browser — a month grid you pick a day out of, with that
/// day's breakdown under it. Targets holds the setup offer or the eight derived
/// numbers. Trends is #545 and Plan has no feature behind it at all; both render
/// a panel saying so. Plan is a TAB rather than a section because that reserves
/// the slot without adding a permanently empty row to a twelve-section sidebar.
///
/// ### Why the composer is only on Today
///
/// Estimating a meal onto a day that has ended is a legitimate thing to want,
/// but the primary path has to stay one field and one button, and a composer
/// that silently logs to March is worse than one that is not there. So History
/// browses and does not write.
///
/// ### Targets
///
/// `MealTargets` is read when a record exists and ignored when it does not. A
/// day is never blocked on setup: with no targets the day card shows totals and
/// no bars, on Today and in History alike.
struct MealsView: View {
    @Bindable var router: AppRouter

    @Environment(\.modelContext) private var modelContext

    /// Every meal, sorted the way the log reads: by day, then by the instant
    /// inside it. Filtered to a day in memory — the day comparison is a
    /// stored-day equality, which a `#Predicate` cannot express, and this is a
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

    /// The day History is showing, device-local midnight. Only History reads it;
    /// Today is always `todayDay`. It never moves past today, because a meal you
    /// have not eaten is not a log entry.
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// The month the History grid is on, device-local midnight of its first day.
    /// Held separately from `selectedDay` so stepping through months does not
    /// change which day the breakdown is reading.
    @State private var visibleMonth: Date = MealCalendar.monthStart(of: Date())

    @State private var openMeal: LocalMeal?

    /// The row an Activity deep-link just landed on (#547). Held for ~600 ms,
    /// which is long enough to be seen and short enough not to read as a
    /// selection the user has to dismiss. Keyed on `clientUUID` because that is
    /// also the row's scroll id.
    @State private var pulsedMealID: String?

    /// The derive-review-save flow (#544). Opened from the Targets tab, in both
    /// its states.
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
                case .today:   todayTab
                case .history: historyTab
                case .trends:  scrolling { MealsTrendsPlaceholder() }
                case .plan:    scrolling { MealsPlanPlaceholder() }
                case .targets: targetsTab
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

    /// The app's own strip, not `.pickerStyle(.segmented)`. The native control
    /// draws its own greys and its own font, none of which come from `Tokens`,
    /// and it truncates rather than shrinks, so five segments at phone width
    /// become five abbreviations. See `EdTabStrip`.
    private var tabBar: some View {
        EdTabStrip(
            tabs: MealsTab.allCases,
            selection: $tab,
            label: { $0.displayName },
            accessibilityName: "Meals view"
        )
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.sm)
    }

    /// Trends, Plan and Targets. The bottom inset clears the floating tab bar,
    /// which is 74 pt tall and was covering the foot of the Targets card.
    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
        }
    }

    // MARK: - Today

    /// Strictly today. No stepper, and no targets card in either state: the
    /// setup offer and the eight numbers both live on the Targets tab now, so
    /// this tab has one job and keeps it.
    private var todayTab: some View {
        dayScroll {
            VStack(alignment: .leading, spacing: Space.lg) {
                MealComposer(
                    day: todayDay,
                    existingOnDay: todaySummary.all,
                    onLogged: { _ in }
                )

                MealDayBreakdown(
                    summary: todaySummary,
                    targets: MealTargets.inForce(on: todayDay, among: allTargets),
                    isToday: true,
                    pulsedMealID: pulsedMealID,
                    onOpenMeal: { openMeal = $0 }
                )
            }
        }
    }

    // MARK: - History

    /// The day browser. The grid picks a day; the breakdown under it is the SAME
    /// component Today renders, so a day cannot read one way here and another way
    /// there.
    ///
    /// Stacked rather than side by side on macOS. The breakdown is a tall column
    /// of bars and meal rows and the grid is a fixed-width block, so a two-pane
    /// layout would put a short calendar beside a long scroll and leave most of
    /// the left half empty.
    private var historyTab: some View {
        dayScroll {
            VStack(alignment: .leading, spacing: Space.lg) {
                MealCalendarCard(
                    month: $visibleMonth,
                    selectedDay: $selectedDay,
                    readings: MealCalendar.readings(in: allMeals),
                    today: Date()
                )

                selectedDayTitle

                MealDayBreakdown(
                    summary: selectedSummary,
                    targets: MealTargets.inForce(on: selectedDay, among: allTargets),
                    isToday: isSelectedToday,
                    pulsedMealID: pulsedMealID,
                    onOpenMeal: { openMeal = $0 }
                )
            }
        }
    }

    /// Names the day the breakdown below is about. The grid highlights the
    /// square, but the square is a numeral in a block of numerals, and the card
    /// under it carries no date of its own.
    private var selectedDayTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dayTitle)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
            Text(Self.dayFormatter.string(from: selectedDay))
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Targets

    /// One tab, two states, and the same subject in both: the setup offer while
    /// no record exists, the eight derived numbers once one does.
    /// `MealTargetsSheet` is still the only edit flow, opened from either state.
    private var targetsTab: some View {
        scrolling {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let targets = MealTargets.inForce(on: todayDay, among: allTargets) {
                    MealTargetsSummaryCard(targets: targets) { showingTargets = true }
                } else {
                    MealTargetsSetupCard { showingTargets = true }
                }
            }
        }
    }

    // MARK: - Shared scroll container

    /// The scroll body Today and History share, including the deep-link scroll.
    ///
    /// The scroll runs on the pulse rather than on the focus, because the focus
    /// may arrive while another tab is showing and this reader is not mounted;
    /// the pulse survives that and fires the scroll once the list is on screen.
    private func dayScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Built once, outside the reader. `ScrollViewReader` takes an escaping
        // closure, and a non-escaping builder parameter cannot be captured by one.
        let inner = content()
        return ScrollViewReader { proxy in
            ScrollView {
                inner
                    .padding(.horizontal, Space.lg)
                    // Space.xxl is 32 and the floating tab bar is 74, so the last
                    // meal row of a long day used to stop underneath it.
                    .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
                    .padding(.top, Space.xs)
            }
            .onChange(of: pulsedMealID) { _, id in scroll(proxy, to: id) }
            .onAppear { scroll(proxy, to: pulsedMealID) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else { return }
        // One run loop of slack lets the day switch render its rows before we
        // ask for one of them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    // MARK: - Deep link

    /// Land a deep-link on its meal: put the right tab in front of it, point that
    /// tab at the right day, and pulse the row.
    ///
    /// The tab is chosen by the meal's own day, which is what #559 changed. Today
    /// is now today only, so a link to a meal logged three weeks ago has no
    /// landing place there; it goes to History, which selects the day and steps
    /// the grid to the month holding it. A link to a meal logged today still
    /// lands on Today, because that is the tab the user was looking at when they
    /// logged it.
    ///
    /// Goes through the SAME `ActivityFocus` mechanism every other section uses,
    /// rather than a second navigation path. The id travels as a `UUID` there and
    /// is stored here as a string, so the match is case-insensitive:
    /// `MealService` lowercases what it writes, but a row that arrived from a
    /// peer or a tool call need not have.
    private func consumeFocus() {
        guard router.focus?.section == .meals, let focus = router.focus else { return }
        router.focus = nil
        guard let meal = allMeals.first(where: {
            $0.clientUUID.caseInsensitiveCompare(focus.id.uuidString) == .orderedSame
        }) else { return }

        let landing = MealsView.tab(forMealOn: meal.deviceDay)
        tab = landing
        if landing == .history {
            selectedDay = Calendar.current.startOfDay(for: meal.deviceDay)
            visibleMonth = MealCalendar.monthStart(of: meal.deviceDay)
        }
        pulsedMealID = meal.clientUUID

        let id = meal.clientUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if pulsedMealID == id { pulsedMealID = nil }
        }
    }

    /// Which tab shows the meal logged on `day`. Pulled out of `consumeFocus` so
    /// the routing rule can be pinned by a test without a view hierarchy.
    static func tab(forMealOn day: Date, today: Date = Date(), calendar: Calendar = .current) -> MealsTab {
        calendar.isDate(day, inSameDayAs: today) ? .today : .history
    }

    // MARK: - Derived

    /// Recomputed rather than held in `@State`, so a session left open across
    /// midnight does not keep calling yesterday "today".
    private var todayDay: Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// Built through the shared selector, so this section and the Today card
    /// total one day exactly once (#547). The day match itself lives in
    /// `MealDaySummary.onDay`, where a stored UTC anchor is compared as a day and
    /// never as an instant (#506).
    private var todaySummary: MealDaySummary {
        MealDaySummary.onDay(todayDay, in: allMeals)
    }

    private var selectedSummary: MealDaySummary {
        MealDaySummary.onDay(selectedDay, in: allMeals)
    }

    private var isSelectedToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    private var dayTitle: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDay) { return "Today" }
        if calendar.isDateInYesterday(selectedDay) { return "Yesterday" }
        return Self.weekdayFormatter.string(from: selectedDay)
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
