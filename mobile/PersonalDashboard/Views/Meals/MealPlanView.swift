import SwiftUI
import SwiftData

/// The Plan tab (#599).
///
/// ### What it is
///
/// A calendar of meals you intend to eat, and a chat that helps you decide what
/// they should be. A date holds blocks — breakfast, lunch, dinner and as many
/// snacks as the day needs — and each block says what it is and what the main
/// ingredients are. A block can be ticked off or skipped.
///
/// ### It has its own day, and that is deliberate
///
/// The Meals section's `selectedDay` is the TRACKING day. It cannot move past
/// today, because a meal you have not eaten is not a log entry, and the composer
/// on that tab writes to it. A plan lives in the future, so sharing the value
/// would either freeze the plan at today or point the composer at a day it must
/// never write to (#592).
///
/// So the two days are separate values, and the section hides the chrome's date
/// control while this tab is showing. Two controls in one chrome naming two
/// different days is a contradiction the user has to resolve on every glance;
/// this tab carries its own calendar and that calendar is the day control.
///
/// ### Nothing here writes on its own
///
/// Every block on the calendar was put there by a tap. The chat proposes and the
/// user disposes — see `MealPlanAdvisor` for why that is not negotiable.
struct MealPlanView: View {

    /// Every logged meal and every targets record, handed down from the
    /// section's own queries rather than re-declared here.
    ///
    /// One query serving both tabs is what stops the Tracking day card and this
    /// tab's chat context reading two different sets of rows, and it is what
    /// keeps a second `@Query` out of a view that can be rebuilt on every
    /// keystroke in the chat (#442).
    let allMeals: [LocalMeal]
    let allTargets: [MealTargets]

    /// Owned by the section so the conversation survives closing the sheet. See
    /// the note on `MealPlanChatSheet`.
    @Bindable var chat: MealPlanChatModel

    /// Every planned block. Filtered to a day or a range in memory — the day
    /// comparison is a stored-day equality, which a `#Predicate` cannot express,
    /// and this is a personal-scale table. The same call `MealsView` makes about
    /// its meals.
    @Query(
        sort: [
            SortDescriptor(\LocalMealPlanEntry.date, order: .forward),
            SortDescriptor(\LocalMealPlanEntry.slotIndex, order: .forward)
        ]
    ) private var allEntries: [LocalMealPlanEntry]

    @State private var scope: MealPlanScope = .week
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var visibleWeek: Date = MealPlanCalendar.weekStart(of: Date())
    @State private var visibleMonth: Date = MealPlanCalendar.monthStart(of: Date())

    @State private var editorTarget: MealPlanEditorTarget?
    @State private var showingChat = false
    @State private var errorMessage: String?

    private var service: MealPlanService { .default() }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                scopeStrip
                calendarCard
                actionBar
                if let errorMessage {
                    Text(errorMessage)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MealPlanDayPanel(
                    plan: selectedPlan,
                    targets: MealTargets.inForce(on: selectedDay, among: allTargets),
                    onAdd: { editorTarget = .new(day: selectedDay, mealType: $0) },
                    onOpen: { editorTarget = .existing($0) },
                    onToggleEaten: toggleEaten,
                    onSkip: toggleSkip,
                    onDuplicate: duplicate,
                    onDelete: delete
                )
                MealPlanIngredientsCard(
                    ingredients: scopeIngredients,
                    scopeLabel: scopeLabel
                )
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.xs)
            .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
        }
        // Picking a day in one scope should leave the other scope pointing at it
        // too, so switching Week to Month does not jump to a month the selection
        // is not in.
        .onChange(of: selectedDay) { _, day in
            visibleWeek = MealPlanCalendar.weekStart(of: day, calendar: calendar)
            visibleMonth = MealPlanCalendar.monthStart(of: day, calendar: calendar)
        }
        .sheet(item: $editorTarget) { target in
            MealPlanEntryEditor(target: target)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(isPresented: $showingChat) {
            MealPlanChatSheet(
                model: chat,
                day: selectedDay,
                dayLabel: shortDayLabel,
                targets: MealTargets.inForce(on: selectedDay, among: allTargets),
                loggedMeals: allMeals,
                plan: selectedPlan
            )
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #endif
        }
    }

    // MARK: - Scope

    private var scopeStrip: some View {
        EdTabStrip(
            tabs: MealPlanScope.allCases,
            selection: $scope,
            label: { $0.displayName },
            accessibilityName: "Plan range"
        )
        .frame(maxWidth: MealPlanMetrics.maxWidth)
    }

    @ViewBuilder
    private var calendarCard: some View {
        switch scope {
        case .week:
            MealPlanWeekStrip(
                week: $visibleWeek,
                selectedDay: $selectedDay,
                readings: readings
            )
        case .month:
            MealPlanMonthGrid(
                month: $visibleMonth,
                selectedDay: $selectedDay,
                readings: readings
            )
        }
    }

    // MARK: - Day actions

    /// The three things you do to a whole day: ask about it, fill it from
    /// another one, or empty it.
    ///
    /// The chat is the primary button because it is the one the tab was asked
    /// for. The copies sit in a menu: they are the fastest way to fill a week
    /// and they are also the easiest to reach for by accident, and a copy that
    /// lands on the wrong day leaves blocks to delete one at a time.
    private var actionBar: some View {
        HStack(spacing: Space.sm) {
            Button {
                showingChat = true
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Ask what to eat")
                }
            }
            .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))

            Menu {
                Button {
                    copyDay(offsetDays: -1)
                } label: {
                    Label("From the day before", systemImage: "arrow.left.arrow.right")
                }
                Button {
                    copyDay(offsetDays: -7)
                } label: {
                    Label("From this day last week", systemImage: "calendar.badge.clock")
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copy")
                }
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
            }
            .menuStyleCompat()
            .accessibilityLabel("Copy another day's plan onto this one")

            Spacer(minLength: 0)

            Menu {
                Button(role: .destructive) {
                    clearDay()
                } label: {
                    Label("Clear this day", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyleCompat()
            .disabled(selectedPlan.isEmpty)
            .accessibilityLabel("More actions for this day")
        }
    }

    // MARK: - Derived

    /// Built in ONE pass over the table and shared by both calendars, rather
    /// than asked per square. Forty-two squares each re-scanning the table is
    /// the per-row cost that froze Finance (#442).
    private var readings: [Date: MealPlanReading] {
        MealPlanDay.readings(in: allEntries)
    }

    private var selectedPlan: MealPlanDay {
        MealPlanDay.onDay(selectedDay, in: allEntries)
    }

    /// The blocks inside the scope on screen, for the ingredient roll-up.
    private var scopeEntries: [LocalMealPlanEntry] {
        let range = MealPlanCalendar.range(for: scope, containing: selectedDay, calendar: calendar)
        let lower = WallClock.dayAnchor(from: range.start)
        let upper = WallClock.dayAnchor(from: range.end)
        return allEntries.filter { entry in
            let day = WallClock.startOfStoredDay(entry.date)
            return day >= lower && day <= upper
        }
    }

    private var scopeIngredients: [MealPlanIngredient] {
        MealPlanDay.ingredients(in: scopeEntries)
    }

    /// "this week" or "in September". The roll-up card reads "Ingredients
    /// <this>", so the phrase carries its own preposition.
    private var scopeLabel: String {
        switch scope {
        case .week:
            return calendar.isDate(selectedDay, equalTo: Date(), toGranularity: .weekOfYear)
                ? "this week"
                : "that week"
        case .month:
            return "in \(Self.monthName.string(from: selectedDay))"
        }
    }

    /// How the chat's Add button names the day: "today", "tomorrow", or the
    /// weekday and date.
    private var shortDayLabel: String {
        if calendar.isDateInToday(selectedDay) { return "today" }
        if calendar.isDateInTomorrow(selectedDay) { return "tomorrow" }
        if calendar.isDateInYesterday(selectedDay) { return "yesterday" }
        return Self.shortDay.string(from: selectedDay)
    }

    // MARK: - Writes
    //
    // Every one of these is a service call wrapped in the same error handling.
    // The view holds no copy of a block's state: SwiftData's change
    // notification repaints the list, so there is nothing here that can drift
    // out of step with the store.

    private func toggleEaten(_ entry: LocalMealPlanEntry) {
        perform {
            try service.setStatus(entry.statusEnum == .eaten ? .planned : .eaten, on: entry)
            Haptics.tick()
        }
    }

    private func toggleSkip(_ entry: LocalMealPlanEntry) {
        perform {
            try service.setStatus(entry.statusEnum == .skipped ? .planned : .skipped, on: entry)
            Haptics.light()
        }
    }

    private func duplicate(_ entry: LocalMealPlanEntry) {
        perform {
            try service.addEntry(
                date: entry.deviceDay,
                mealType: entry.mealTypeEnum,
                title: entry.title,
                ingredients: entry.ingredients,
                notes: entry.notes,
                // A duplicate is something still to do, never something already
                // done. Carrying `.eaten` across would tick a meal nobody ate.
                status: .planned,
                nutrients: entry.plannedNutrients,
                source: MealPlanSource.copy
            )
        }
    }

    private func delete(_ entry: LocalMealPlanEntry) {
        perform {
            try service.deleteEntry(entry)
            Haptics.destructive()
        }
    }

    private func copyDay(offsetDays: Int) {
        perform {
            guard let source = calendar.date(byAdding: .day, value: offsetDays, to: selectedDay) else { return }
            let made = try service.copyDay(from: source, to: selectedDay)
            if made.isEmpty {
                errorMessage = "Nothing to copy: \(Self.shortDay.string(from: source)) has no planned meals."
            } else {
                Haptics.light()
            }
        }
    }

    private func clearDay() {
        perform {
            try service.clearDay(selectedDay)
            Haptics.destructive()
        }
    }

    /// Run a write, and put whatever it threw on screen.
    ///
    /// Clearing the message FIRST is what makes a retry readable: without it, a
    /// second attempt that succeeds would leave the first attempt's error
    /// sitting under a day that is now fine.
    private func perform(_ work: () throws -> Void) {
        errorMessage = nil
        do {
            try work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Formatters
    //
    // Every date reaching these is a device-local midnight, never a stored
    // anchor, so a device-local formatter is correct (#506).

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        return f
    }()

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()
}
