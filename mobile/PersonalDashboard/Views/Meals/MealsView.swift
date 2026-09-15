import SwiftUI
import SwiftData

/// The four tabs inside Meals (#543, widened in #559, corrected in #565).
///
/// ### Why there is no Trends tab
///
/// #559 read "historic charts" as "historic chats" and built the wrong shape: a
/// History tab that browsed days, beside a Trends tab reserving the charts. They
/// were always the same slot. History is where the historic charts live, so it
/// takes that name and #545 now builds into it. Trends is gone rather than
/// renamed, because there was never a second thing for it to hold.
///
/// ### Why Today browses days again
///
/// Splitting "log today" and "read an older day" across two tabs sounded right
/// and was not. They are one question — how is this day going — asked of
/// different days, and one surface answers it. Today holds the day, whichever
/// day that is, and reaches the others through a calendar. Targets is the only
/// genuine second surface #559 found.
enum MealsTab: String, CaseIterable, Identifiable {
    case today
    case history
    case plan
    case targets

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today:   return "Today"
        case .history: return "History"
        case .plan:    return "Plan"
        case .targets: return "Targets"
        }
    }
}

/// Meal logging v1 (#543), restructured in #559 and corrected in #565.
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
/// ### The four tabs
///
/// Today is the day: a date control, the composer, the day card and that day's
/// meals. It opens on today and the date control reaches any earlier day.
/// History is the historic charts and is #545. Targets holds the setup offer or
/// the eight derived numbers. Plan has no feature behind it at all. History and
/// Plan both render a panel saying so; Plan is a TAB rather than a section
/// because that reserves the slot without adding a permanently empty row to a
/// twelve-section sidebar.
///
/// ### Why the composer is only on today
///
/// Estimating a meal onto a day that has ended is a legitimate thing to want,
/// but the primary path has to stay one field and one button, and a composer
/// that silently logs to March is worse than one that is not there. So the tab
/// reads any day and writes only to today.
///
/// ### Targets
///
/// `MealTargets` is read when a record exists and ignored when it does not. A
/// day is never blocked on setup: with no targets the day card shows totals and
/// no bars, whichever day is selected.
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

    /// The day Today is showing, device-local midnight. Starts on today and
    /// never moves past it, because a meal you have not eaten is not a log entry.
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// The month the popover grid is on, device-local midnight of its first day.
    /// Held separately from `selectedDay` so paging through months does not
    /// change which day the tab is reading; the date control re-points it at the
    /// selected day each time the popover opens, so it never reopens somewhere
    /// the user did not leave it.
    @State private var visibleMonth: Date = MealCalendar.monthStart(of: Date())

    /// The month grid, anchored to the date control.
    @State private var showingCalendar = false

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
                case .history: scrolling { MealsHistoryPlaceholder() }
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
        // Picking a day is the popover's whole purpose, so it closes on the pick
        // rather than waiting to be dismissed. Also fires for the "Today" button
        // and the deep link, where closing an already-closed popover is a no-op.
        .onChange(of: selectedDay) { _, _ in showingCalendar = false }
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
    /// and it truncates rather than shrinks, which is what turned five segments
    /// at phone width into five abbreviations. Four is easier than the five this
    /// was built for, so nothing about it changes here. See `EdTabStrip`.
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

    /// History, Plan and Targets. The bottom inset clears the floating tab bar,
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

    /// One day in full, and by default that day is today.
    ///
    /// The tab opens on today and every block below the date control follows
    /// whichever day is selected: the composer's presence, the day card, the meal
    /// list and each row's breakdown. Nothing here knows about a second tab,
    /// because there is not one any more.
    private var todayTab: some View {
        dayScroll {
            VStack(alignment: .leading, spacing: Space.lg) {
                dateControl

                // The composer only appears on today. Estimating a meal onto a
                // day that has ended is a legitimate thing to want, but the
                // primary path has to stay one field and one button, and a
                // composer that silently logs to March is worse than one that is
                // not there.
                if isSelectedToday {
                    MealComposer(
                        day: selectedDay,
                        existingOnDay: selectedSummary.all,
                        onLogged: { _ in }
                    )
                }

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

    /// Names the day the tab is showing, and opens the month grid.
    ///
    /// A control rather than a heading, because it is the only way to any day
    /// but today, and a label you cannot press would leave the user stranded on
    /// a day in March. It carries a "Today" affordance of its own for the same
    /// reason: returning is one tap, not a hunt through the grid.
    ///
    /// ### Why it wears the secondary button's shell
    ///
    /// It was bare text with a small glyph, and it did not read as tappable. The
    /// "Today" button sitting beside it was a bordered pill, so the more
    /// discoverable of the two was the one that did less — and the user has
    /// already given this note once on this surface, about a discard button that
    /// was "not very evident its a clickable button". Shipping a second quiet
    /// affordance next to the first would be the same note twice.
    ///
    /// So it takes `EdButtonStyle(kind: .secondary, size: .sm)`, LITERALLY the
    /// style its neighbour uses, rather than a hand-rolled lookalike. That makes
    /// the two peers by construction: the same surface, the same border, the same
    /// radius and the same press feedback, differing only in what they contain.
    /// The children set their own fonts and inks, which override the style's.
    ///
    /// The glyph is the part that says what happens on tap, so it gains weight
    /// rather than losing it beside a louder frame.
    private var dateControl: some View {
        // Centred, not baseline-aligned. While the date was bare text, matching
        // its first baseline to the button's label was the right call. Now that
        // both are pills, a shared baseline leaves the two frames visibly offset,
        // and what the eye lines up is the boxes.
        HStack(alignment: .center, spacing: Space.sm) {
            Button {
                visibleMonth = MealCalendar.monthStart(of: selectedDay)
                showingCalendar = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dayTitle)
                            .font(.edHeading)
                            .foregroundStyle(Tokens.ink)
                        Text(Self.dayFormatter.string(from: selectedDay))
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
            .accessibilityLabel("\(dayTitle), \(Self.dayFormatter.string(from: selectedDay)). Choose a day")
            // No `arrowEdge`. The control sits at the top of the tab, and forcing
            // the popover above it clipped the month off the top of the window;
            // the system places it below when that is where the room is. Same
            // call as the Tasks calendar, which opens from the same kind of spot.
            .popover(isPresented: $showingCalendar) {
                MealCalendarPopover(
                    month: $visibleMonth,
                    selectedDay: $selectedDay,
                    readings: MealCalendar.readings(in: allMeals),
                    today: Date()
                )
            }

            Spacer(minLength: Space.sm)

            // Only worth screen space when it would do something.
            if !isSelectedToday {
                Button("Today") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedDay = todayDay
                    }
                }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                .accessibilityLabel("Back to today")
            }
        }
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

    /// Land a deep-link on its meal: point Today at the meal's day and pulse the
    /// row.
    ///
    /// One path for every meal, which is what #565 restored. #559 had to choose
    /// a tab, because Today could only show today and anything older belonged to
    /// a second tab. Today reaches any day again, so there is no choice left to
    /// make and no branch that can send a link to the wrong surface.
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

        let landing = MealsView.landing(forMealOn: meal.deviceDay)
        tab = landing.tab
        selectedDay = landing.day
        visibleMonth = landing.month
        pulsedMealID = meal.clientUUID

        let id = meal.clientUUID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if pulsedMealID == id { pulsedMealID = nil }
        }
    }

    /// Where a deep-link to a meal logged on `day` puts the section.
    ///
    /// Pulled out of `consumeFocus` so the rule can be pinned by a test without a
    /// view hierarchy. `tab` is unconditional now, and is returned rather than
    /// assumed so that a future tab which could also hold a meal has one place to
    /// change.
    static func landing(
        forMealOn day: Date,
        calendar: Calendar = .current
    ) -> (tab: MealsTab, day: Date, month: Date) {
        (
            tab: .today,
            day: calendar.startOfDay(for: day),
            month: MealCalendar.monthStart(of: day, calendar: calendar)
        )
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
