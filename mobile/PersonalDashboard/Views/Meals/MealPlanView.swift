import SwiftUI
import SwiftData

/// The Plan tab (#599).
///
/// ### What it is
///
/// A calendar of meals you intend to eat, and a chat that helps you decide what
/// they should be. One day at a time: the chat at the top, the day's four tiles
/// under it, and what the day needs from a shop at the foot.
///
/// ### It has no calendar of its own
///
/// The day is chosen in the section chrome, by the same control Tracking uses.
/// The tab used to carry a Week/Month strip inline as well, which was two
/// calendars on one surface: the second one pushed the day's content down the
/// screen every time it was on show, and the chrome control sat above it naming
/// a different day. Now there is one control, and `MealsView` points it at this
/// tab's day while this tab is showing.
///
/// The plan's day and Tracking's day are still separate VALUES. That control
/// cannot reach a future day on Tracking, because the composer writes to it and
/// a meal is a record of something already eaten (#592); a plan lives in the
/// future. Same control, two days, and the calendar behind it allows the future
/// on this tab and not on that one.
///
/// ### Nothing here writes on its own
///
/// Every block was put there by a tap. The chat proposes and the user disposes —
/// see `MealPlanAdvisor` for why that is not negotiable.
struct MealPlanView: View {

    /// Every logged meal, every targets record and every planned block, handed
    /// down from the section's own queries rather than re-declared here.
    ///
    /// One query serving every tab is what stops the Tracking day card, this
    /// tab's tiles and the chat's context reading three different sets of rows,
    /// and it keeps a second `@Query` out of a view that is rebuilt on every
    /// keystroke in the chat (#442).
    let allMeals: [LocalMeal]
    let allTargets: [MealTargets]
    let allEntries: [LocalMealPlanEntry]

    /// The day being planned. Owned by the section, because the chrome's date
    /// control drives it.
    @Binding var selectedDay: Date

    /// Owned by the section so the conversation survives a tab switch. See the
    /// note on `MealPlanChatPanel`.
    @Bindable var chat: MealPlanChatModel

    @State private var editorTarget: MealPlanEditorTarget?
    @State private var errorMessage: String?

    private var plans: MealPlanService { .default() }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    MealPlanChatPanel(
                        model: chat,
                        dayLabel: shortDayLabel,
                        hasTargets: MealTargets.inForce(on: selectedDay, among: allTargets) != nil,
                        hasHistory: !allMeals.isEmpty,
                        hasPlan: !selectedPlan.isEmpty,
                        onSend: send,
                        onAdd: add
                    )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    MealPlanBoard(
                        plan: selectedPlan,
                        targets: MealTargets.inForce(on: selectedDay, among: allTargets),
                        onAdd: { editorTarget = .new(day: selectedDay, mealType: $0) },
                        onOpen: { editorTarget = .existing($0) },
                        onToggleEaten: toggleEaten,
                        onCopyDay: copyDay,
                        onClearDay: clearDay
                    )

                    MealPlanNeedsCard(
                        ingredients: MealPlanDay.ingredients(in: selectedPlan.all),
                        blocksWithoutIngredients: selectedPlan.counted.filter { $0.ingredients.isEmpty }.count
                    )
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xs)
                .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
            }
            // The panel has no viewport of its own, so keeping the newest turn
            // in view is the PAGE's job. Scrolling to the last turn rather than
            // to a bottom anchor is deliberate here: the board sits below the
            // chat, and anchoring to the page bottom during a reply would drag
            // the user away from the answer and down to the tiles.
            .onChange(of: chat.turns.last?.text) { _, _ in scrollToNewestTurn(proxy) }
            .onChange(of: chat.turns.count) { _, _ in scrollToNewestTurn(proxy) }
        }
        .sheet(item: $editorTarget) { target in
            MealPlanEntrySheet(target: target)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    private func scrollToNewestTurn(_ proxy: ScrollViewProxy) {
        guard let id = chat.turns.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    // MARK: - Derived

    private var selectedPlan: MealPlanDay {
        MealPlanDay.onDay(selectedDay, in: allEntries)
    }

    /// How the chat's Add button names the day: "today", "tomorrow", or the
    /// weekday and date.
    private var shortDayLabel: String {
        if calendar.isDateInToday(selectedDay) { return "today" }
        if calendar.isDateInTomorrow(selectedDay) { return "tomorrow" }
        if calendar.isDateInYesterday(selectedDay) { return "yesterday" }
        return Self.shortDay.string(from: selectedDay)
    }

    // MARK: - Chat

    /// Build the context afresh on every send.
    ///
    /// Not cached, and that is the point: the user can add a suggestion, change
    /// the plan and ask again, and the next turn has to be told about the day as
    /// it is NOW rather than as it was when the panel first rendered. It is
    /// arithmetic over arrays already in memory, so it costs nothing to rebuild.
    private func send() {
        chat.send(
            context: MealPlanContext.build(
                day: selectedDay,
                targets: MealTargets.inForce(on: selectedDay, among: allTargets),
                loggedMeals: allMeals,
                planForDay: selectedPlan
            ),
            defaultMealType: MealEstimationService.inferredType(at: Date())
        )
    }

    /// Write a suggestion onto the day.
    ///
    /// The `why` is deliberately NOT carried across. It is an argument for a
    /// choice, and once the choice is made it stops being true of the plan: a
    /// block reading "you are short on protein today" a week later is a note
    /// about a day that has been and gone. The prep note IS carried, because
    /// soaking the beans is still true on the night.
    private func add(_ suggestion: MealPlanSuggestion) {
        perform {
            try plans.addEntry(
                date: selectedDay,
                mealType: suggestion.mealType,
                title: suggestion.title,
                ingredients: suggestion.ingredients,
                notes: suggestion.prepNote,
                status: .planned,
                nutrients: suggestion.nutrients,
                source: MealPlanSource.chat
            )
            // Marked only after the write succeeded. A card reading "Added" over
            // a write that threw is worse than one that can be tapped twice.
            chat.markAdded(suggestion)
            Haptics.light()
        }
    }

    // MARK: - Writes
    //
    // Every one of these is a service call wrapped in the same error handling.
    // The view holds no copy of a block's state: SwiftData's change notification
    // repaints the tiles, so there is nothing here that can drift out of step
    // with the store.

    private func toggleEaten(_ entry: LocalMealPlanEntry) {
        perform {
            try plans.setStatus(entry.statusEnum == .eaten ? .planned : .eaten, on: entry)
            Haptics.tick()
        }
    }

    private func copyDay(offsetDays: Int) {
        perform {
            guard let source = calendar.date(byAdding: .day, value: offsetDays, to: selectedDay) else { return }
            let made = try plans.copyDay(from: source, to: selectedDay)
            if made.isEmpty {
                errorMessage = "Nothing to copy: \(Self.shortDay.string(from: source)) has no planned meals."
            } else {
                Haptics.light()
            }
        }
    }

    private func clearDay() {
        perform {
            try plans.clearDay(selectedDay)
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
}
