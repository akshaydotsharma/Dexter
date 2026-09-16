import SwiftUI
import SwiftData

/// The four tabs inside Meals (#543, #559, #565, #567, renamed in #569, Trends
/// added in #545).
///
/// ### What a tab is for here
///
/// A tab is a place the content can BE. Tracking is a day, Trends is a window,
/// Plan is a plan, Targets is eight numbers. Each is somewhere you settle.
///
/// History left because it is not that. It is a thing you look at and come back
/// from, so #567 moved it into the section chrome and #569 removed it outright.
/// Trends is not History returning: History was a control that reached a past
/// day, which the calendar already does. Trends is a different subject, the
/// window rather than the day, and it is a place rather than a trip.
///
/// ### Why the first tab is Tracking and not Today
///
/// It was called Today and then stopped being today: picking a day in the
/// calendar re-renders it for that day. A tab named for one day while showing
/// any day is a label contradicting its own content, and the name is the thing
/// that was wrong. The case is renamed too, not just the string, because a case
/// called `today` that shows March is the same mismatch one level down.
///
/// The rename moves a job. The tab used to name the day; now the date control in
/// the chrome does, which is why that control states the date at all times
/// rather than only when you have moved off today.
enum MealsTab: String, CaseIterable, Identifiable {
    case tracking
    case trends
    case plan
    case targets

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tracking: return "Tracking"
        case .trends:   return "Trends"
        case .plan:     return "Plan"
        case .targets:  return "Targets"
        }
    }
}

/// Meal logging v1 (#543), restructured in #559, #565, #567 and #569.
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
/// Tracking is the day: the composer, the day card and that day's meals. It
/// opens on today, and the date control in the section chrome names the day and
/// reaches any earlier one. Trends is the window: a period filter, an average
/// against target, a balance table and the callouts that come out of it (#545).
/// Plan is the plan: a calendar of meals you intend to eat, and a chat that
/// helps you decide what they should be (#599). Targets holds the setup offer or
/// the eight derived numbers.
///
/// Plan is a TAB rather than a section because that keeps the whole of Meals
/// behind one sidebar row: a planned meal, a logged meal and a target are three
/// views of the same subject, and splitting them across the sidebar would make
/// the user choose which one they were in before they could look at any of them.
///
/// It carries its own selected day, and the chrome's date control is withheld
/// while it is showing. That control cannot reach a future day, because the
/// Tracking composer writes to it and a meal is a record of something already
/// eaten (#592). A plan lives in the future, so it needs a calendar that can go
/// there, and two controls in one chrome naming two different days is a
/// contradiction the user has to resolve on every glance.
///
/// Trends makes ZERO API calls. Every number and every sentence on it is
/// arithmetic over the rows this section already queries, against the targets
/// record beside them, which is what lets it recompute freely and what stops two
/// numbers on one screen disagreeing.
///
/// ### Why the composer is on every day
///
/// It reads any day and writes to any day (#592). Until then it wrote only to
/// today, because the primary path has to stay one field and one button and a
/// composer that silently logs to March is worse than one that is not there.
/// What changed is not the risk, it is that the composer now answers it: on any
/// day but today its eyebrow states the date it is writing to, and the estimate
/// preview states it again beside the Log button. Nothing here is silent any
/// more, so nothing has to be withheld.
///
/// The day is still chosen in exactly one place, the calendar in the section
/// chrome. The composer has no day control of its own and must not gain one, or
/// the surface would hold two answers to which day a meal belongs to.
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

    /// Every planned block. Queried HERE rather than inside `MealPlanView` so
    /// the chrome's date control can mark the days that hold a plan without the
    /// tab being on screen, and so one query feeds both the control and the tab
    /// (#442, #599).
    @Query(
        sort: [
            SortDescriptor(\LocalMealPlanEntry.date, order: .forward),
            SortDescriptor(\LocalMealPlanEntry.slotIndex, order: .forward)
        ]
    ) private var allPlanEntries: [LocalMealPlanEntry]

    @State private var tab: MealsTab = .tracking

    /// The day Today is showing, device-local midnight. Starts on today and
    /// never moves past it, because a meal you have not eaten is not a log entry.
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// The month the popover grid is on, device-local midnight of its first day.
    /// Held separately from `selectedDay` so paging through months does not
    /// change which day the tab is reading; the date control re-points it at the
    /// selected day each time the popover opens, so it never reopens somewhere
    /// the user did not leave it.
    @State private var visibleMonth: Date = MealCalendar.monthStart(of: Date())

    /// The day the Plan tab is showing, device-local midnight (#599).
    ///
    /// A SECOND day, held apart from `selectedDay`, and that separation is the
    /// load-bearing part. The tracking day can never move past today, because
    /// the composer writes to it and a meal is a record of something already
    /// eaten (#592). A plan lives in the future. One value would either freeze
    /// the plan at today or point the composer at a day it must never write to.
    ///
    /// The chrome's date control drives whichever of the two the current tab is
    /// on, so it still reads as ONE control — which is what it looks like, and
    /// what the user asked for.
    @State private var planDay: Date = Calendar.current.startOfDay(for: Date())

    /// The month the PLAN popover is on. Held apart from `visibleMonth` for the
    /// same reason the days are: paging the plan's calendar into next month must
    /// not move the tracking calendar, which cannot go there.
    @State private var planMonth: Date = MealPlanCalendar.monthStart(of: Date())

    /// The month grid, anchored to the date control in the section chrome.
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

    /// The plan conversation (#599).
    ///
    /// Held HERE rather than inside `MealPlanView`, so switching to Trends and
    /// back does not throw the thread away. A tab switch destroys the tab's
    /// view; the section survives it. It still ends when the user leaves Meals,
    /// which is the same call the main chat surface makes — what is worth
    /// keeping from a plan conversation is the block it produced, and that is on
    /// the calendar.
    @State private var planChat = MealPlanChatModel()

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
                    },
                    trailing: { chromeControls }
                )
                #endif

                tabBar

                switch tab {
                case .tracking: trackingTab
                case .trends:   trendsTab
                case .plan:     planTab
                case .targets:  targetsTab
                }
            }
        }
        .activeSection(.meals)
        // macOS puts the date control in the NATIVE window toolbar, beside the
        // refresh item `macSectionChrome` already installs (#283, #291).
        //
        // The HStack holds ONE control since #569 removed the history button, and
        // it stays anyway. The whole trailing closure goes into a SINGLE
        // `ToolbarItem`, which renders one control, so a second button added
        // beside the first REPLACES it rather than joining it. Tasks found that
        // out when its calendar silently vanished (#385/#524). Deleting the
        // wrapper would take the warning with it and leave the next control to
        // rediscover the trap.
        .macSectionChrome("Meals") {
            #if os(macOS)
            HStack(spacing: Space.xs) {
                // Withheld on the Plan tab for the reason `chromeControls`
                // gives. The `if` sits INSIDE the HStack deliberately: the whole
                // trailing closure is one `ToolbarItem`, and a multi-statement
                // body would distribute the toolbar across each branch (#597).
                if tab != .plan {
                    macDateButton
                }
            }
            #endif
        }
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
        // The same rule for the Plan tab's day, which the same control picks.
        .onChange(of: planDay) { _, _ in showingCalendar = false }
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

    // MARK: - Chrome controls (#567)

    /// The two navigation controls, in the order the issue fixes: date, then
    /// history. On iOS they sit in `TopBar`'s trailing slot, immediately left of
    /// the profile pip.
    ///
    /// There is no refresh control between them and the pip, because iOS has
    /// none to place: refresh on this platform is the pull-to-refresh gesture
    /// (`syncRefreshable`), and `MacSyncRefreshButton` is macOS-only by an
    /// explicit decision recorded in `SyncRefresh.swift`. Adding a phone refresh
    /// button here would be inventing a control, not moving one.
    #if os(iOS)
    @ViewBuilder
    private var chromeControls: some View {
        // Withheld on the Plan tab, which puts its month grid on the screen
        // itself (#599). Two controls picking the same day is worse than one in
        // either position: the chrome one would name a day the grid below it
        // already shows, and the user would have to work out which of them they
        // had last touched.
        if tab != .plan {
            TopBarIconButton(
                systemName: "calendar",
                accessibilityLabel: dateControlAccessibilityLabel,
                action: openCalendar,
                label: dateControlLabel
            )
            .popover(isPresented: $showingCalendar) { calendarPopover }
        }
    }
    #endif

    #if os(macOS)
    /// The toolbar twin of the iOS date control. A plain `Button` rather than
    /// `TopBarIconButton`, because the native toolbar draws its own chrome and a
    /// 44 pt touch target is a phone measure.
    ///
    /// The popover hangs off this button directly. That works here for the same
    /// reason it works for the Tasks calendar (#385): a toolbar item is a stable
    /// view with a real window-relative frame, so SwiftUI can anchor to it. The
    /// hand-rolled `MacAnchoredPopover` is NOT needed — it exists for a popover
    /// that must survive an `NSOpenPanel` taking key (#416), and nothing here
    /// opens a file panel.
    private var macDateButton: some View {
        Button(action: openCalendar) {
            HStack(spacing: Space.xs) {
                Image(systemName: "calendar")
                Text(dateControlLabel)
            }
        }
        .help(dateControlAccessibilityLabel)
        .accessibilityLabel(dateControlAccessibilityLabel)
        .popover(isPresented: $showingCalendar) { calendarPopover }
    }

    #endif

    /// The tracking month grid. The Plan tab has no popover: its calendar is on
    /// the screen (#599).
    private var calendarPopover: some View {
        MealCalendarPopover(
            month: $visibleMonth,
            selectedDay: $selectedDay,
            readings: MealCalendar.readings(in: allMeals),
            today: Date()
        )
    }

    /// The day the chrome control names. Only the tracking day now, since the
    /// control is withheld on the one tab that has another.
    private var chromeDay: Date { selectedDay }

    /// The selected day, always (#567, widened in #569).
    ///
    /// This is what makes one control do two jobs: it states the day and it opens
    /// the calendar. #567 showed the date only once you had moved off today,
    /// because the tab was called "Today" and carried the day itself. #569
    /// renamed that tab to "Tracking", which took the day off it, so the control
    /// is now the ONLY thing above the fold naming the day the numbers belong to
    /// and it has to say so in every state.
    ///
    /// It is also why there is no separate Today button: returning is picking
    /// today in the calendar this control already opens.
    ///
    /// ### Why "15 Sep" and not "Monday"
    ///
    /// The first build used the weekday, and beside the section title at 390 pt
    /// it truncated to "Thurs…". A truncated label is worse than a short one when
    /// stating the day is the whole job. The date is also the more honest answer:
    /// a weekday never said WHICH week, and "15 Sep" does, in fewer characters.
    /// The weekday survives in the accessibility label and on the day card.
    /// Reads whichever day the current tab is on, so one control can name two
    /// of them without ever naming the wrong one (#599).
    private var dateControlLabel: String {
        Self.chromeDayFormatter.string(from: chromeDay)
    }

    /// Where the difference between today and an older day still lives.
    ///
    /// #569 traded a strong visual signal for a constant one: the date used to
    /// APPEAR when you moved off today, and now it is always there, so its
    /// presence no longer carries the distinction. The composer used to carry it
    /// instead, by being absent on any day but today, and #592 put it on every
    /// day. So the sighted cue is now a sentence rather than a difference: the
    /// composer's eyebrow reads "What did you eat on Monday, 14 Sep?" off today
    /// and "What did you eat?" on it.
    ///
    /// A screen-reader user reaching this control has met neither cue yet, which
    /// is why it still says "not today" in words rather than leaving the date to
    /// be compared against a today the reader has to already know.
    private var dateControlAccessibilityLabel: String {
        let day = chromeDay
        let date = Self.dayFormatter.string(from: day)
        if Calendar.current.isDateInToday(day) {
            return "Choose a day. Showing today, \(date)"
        }
        return "Choose a day. Showing \(Self.relativeDayName(day)), \(date). Not today"
    }

    /// Always re-point the grid at the day on screen before opening, so it never
    /// reopens on a month the user paged to and abandoned.
    private func openCalendar() {
        visibleMonth = MealCalendar.monthStart(of: selectedDay)
        showingCalendar = true
    }

    // MARK: - Chrome

    /// The app's own strip, not `.pickerStyle(.segmented)`. The native control
    /// draws its own greys and its own font, none of which come from `Tokens`,
    /// and it truncates rather than shrinks, which is what turned five segments
    /// at phone width into five abbreviations. `EdTabStrip` shrinks instead, so
    /// the fourth tab added in #545 costs a little label width and no truncation.
    /// See `EdTabStrip`.
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

    // MARK: - Tracking

    /// One day in full, and by default that day is today.
    ///
    /// The tab opens on today and every block follows
    /// whichever day is selected: the composer and the day it writes to, the day
    /// card, the meal list and each row's breakdown. Nothing here knows about a
    /// second tab, because there is not one any more.
    private var trackingTab: some View {
        dayScroll {
            VStack(alignment: .leading, spacing: Space.lg) {
                // The composer follows the selected day like every other block
                // on this tab (#592). It is safe off today because it says which
                // day it is writing to: the eyebrow names the date, and the
                // estimate preview names it again beside the Log button. It is
                // handed the day and nothing else, so it cannot choose one.
                MealComposer(
                    day: selectedDay,
                    existingOnDay: selectedSummary.all,
                    onLogged: { _ in }
                )

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

    // MARK: - Trends

    /// The window, not the day (#545).
    ///
    /// It takes the section's two `@Query` results as plain arrays rather than
    /// declaring its own. One query serving both tabs is what stops the day card
    /// and the balance table reading two different sets of rows, and it is what
    /// keeps a per-row query from ever appearing inside a list here (#442).
    private var trendsTab: some View {
        MealTrendsView(
            allMeals: allMeals,
            allTargets: allTargets,
            router: router
        )
    }

    // MARK: - Plan

    /// The plan calendar and the chat behind it (#599).
    ///
    /// It takes the section's two `@Query` results as plain arrays, exactly as
    /// Trends does, and declares one query of its own for the planned blocks.
    /// Nothing about the Tracking day reaches it: the plan has its own selected
    /// day, because the tracking day cannot move past today and a plan lives in
    /// the future. See the note on `MealPlanView`.
    private var planTab: some View {
        MealPlanView(
            allMeals: allMeals,
            allTargets: allTargets,
            allEntries: allPlanEntries,
            selectedDay: $planDay,
            visibleMonth: $planMonth,
            chat: planChat
        )
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
            tab: .tracking,
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
        Self.relativeDayName(selectedDay)
    }

    /// "Today", "Yesterday", "Tomorrow", or the weekday.
    ///
    /// Static and day-agnostic since #599, because the chrome control now names
    /// either the tracking day or the plan day and both need the same phrasing.
    /// Tomorrow is in the list for the plan's sake: it is a day the tracking
    /// calendar can never reach and the plan's most common one.
    static func relativeDayName(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return Self.weekdayFormatter.string(from: day)
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

    /// The chrome's own short form (#567). No year: the calendar cannot reach a
    /// future day and a year-old day is rare enough that the accessibility label
    /// and the calendar itself can carry it.
    private static let chromeDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
}
