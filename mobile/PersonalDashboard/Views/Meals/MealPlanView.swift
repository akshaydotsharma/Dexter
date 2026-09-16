import SwiftUI
import SwiftData

/// The Plan tab (#599).
///
/// ### The shape of it
///
/// A month calendar at the top, the day's four meals stacked under it, and the
/// chat floating over the bottom corner. Each of those three went somewhere else
/// first, and each moved for the same reason: the PLAN is the content, and the
/// two things around it kept pushing it off the screen.
///
/// The calendar was a Week/Month strip, then a popover in the section chrome.
/// On the screen it costs a fixed block of height and answers the question the
/// tab opens on — which day am I looking at — without a tap.
///
/// The chat was a sheet, then an inline panel at the top. As a floating button
/// it costs one corner, and the panel it opens covers part of the plan instead
/// of all of it, so a suggestion can be added and the tile filling in is visible
/// in the same glance.
///
/// ### The day
///
/// Owned by the section, and separate from Tracking's day. That one cannot move
/// past today, because the composer writes to it and a meal is a record of
/// something already eaten (#592); a plan lives in the future. The chrome's date
/// control is withheld while this tab shows, because this tab has a calendar of
/// its own and two controls picking one day is worse than one in either place.
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

    /// The day being planned, and the month the grid is on. Both owned by the
    /// section: the day so it survives a tab switch, the month so paging away
    /// and coming back does not reset it.
    @Binding var selectedDay: Date
    @Binding var visibleMonth: Date

    /// Owned by the section so the conversation survives a tab switch.
    @Bindable var chat: MealPlanChatModel

    @State private var editorTarget: MealPlanEditorTarget?
    @State private var chatOpen = false
    @State private var errorMessage: String?

    private var plans: MealPlanService { .default() }
    private var calendar: Calendar { Calendar.current }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    MealPlanMonthGrid(
                        month: $visibleMonth,
                        selectedDay: $selectedDay,
                        readings: MealPlanDay.readings(in: allEntries)
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
                        onCopyDay: copyDay,
                        onClearDay: clearDay
                    )
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xs)
                .padding(.bottom, BottomTabBarMetrics.scrollBottomInset)
            }

            MealPlanChatOverlay(
                model: chat,
                defaultDay: selectedDay,
                dayLabel: shortDayLabel,
                hasTargets: MealTargets.inForce(on: selectedDay, among: allTargets) != nil,
                hasHistory: !allMeals.isEmpty,
                hasPlan: !selectedPlan.isEmpty,
                onSend: send,
                onAdd: add,
                isOpen: $chatOpen
            )
        }
        // Picking a day is what the grid is for, and a day picked while the chat
        // is open is almost always a day the user wants to LOOK at. Closing the
        // panel gets it out of the way of the answer.
        .onChange(of: selectedDay) { _, _ in
            if chatOpen { withAnimation(.easeOut(duration: 0.2)) { chatOpen = false } }
        }
        .sheet(item: $editorTarget) { target in
            MealPlanEntrySheet(target: target)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }

    // MARK: - Derived

    private var selectedPlan: MealPlanDay {
        MealPlanDay.onDay(selectedDay, in: allEntries)
    }

    /// How the chat's opener names the day: "today", "tomorrow", or the weekday
    /// and date. The same phrasing `MealPlanSuggestionCard` uses, so one day is
    /// never described two ways on one screen.
    private var shortDayLabel: String {
        MealPlanSuggestionCard.dayLabel(selectedDay, calendar: calendar)
    }

    // MARK: - Chat

    /// Build the context afresh on every send.
    ///
    /// Not cached, and that is the point: the user can add a suggestion, change
    /// the plan and ask again, and the next turn has to be told about the day as
    /// it is NOW rather than as it was when the panel opened. It is arithmetic
    /// over arrays already in memory, so it costs nothing to rebuild.
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

    /// Write a suggestion onto the day and meal the CARD was set to, which need
    /// not be the day the calendar is on.
    ///
    /// The `why` is deliberately NOT carried across. It is an argument for a
    /// choice, and once the choice is made it stops being true of the plan: a
    /// block reading "you are short on protein today" a week later is a note
    /// about a day that has been and gone. The prep note IS carried, because
    /// soaking the beans is still true on the night.
    private func add(_ suggestion: MealPlanSuggestion, day: Date, mealType: MealType) {
        perform {
            try plans.addEntry(
                date: day,
                mealType: mealType,
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
