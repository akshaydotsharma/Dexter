import SwiftUI
import SwiftData

/// Today's habits, on the Today surface (#661).
///
/// One row per habit due today: the mark, the name, the streak, the last seven
/// days as dots, and a one-tap check-off. A yes/no habit toggles; a count habit
/// adds one per tap. A done habit stays where it is, dimmed, so the list does
/// not jump under the thumb while the user works down it.
///
/// ### One fetch
///
/// The two queries live on this card, not on its rows. Check-ins are grouped by
/// habit and day once per render (`HabitLedger.group`) and every row receives
/// its slice as a value, so the card costs two fetches however many habits
/// there are (#442).
struct TodayHabitsCard: View {
    /// Opens the Habits section, focused on one habit when given.
    let onOpen: (LocalHabit?) -> Void

    @Query(
        filter: #Predicate<LocalHabit> { $0.deletedAt == nil && $0.archivedAt == nil },
        sort: [SortDescriptor<LocalHabit>(\.sortIndex), SortDescriptor<LocalHabit>(\.createdAt)]
    )
    private var habits: [LocalHabit]

    @Query(filter: #Predicate<LocalHabitCheckIn> { $0.deletedAt == nil })
    private var checkIns: [LocalHabitCheckIn]

    @State private var errorMessage: String?

    var body: some View {
        let today = HabitLedger.todayAnchor()
        let grouped = HabitLedger.group(checkIns.map { ($0.habitUUID, $0.day, $0.entry) })
        let due = habits.filter { habit in
            let state = HabitLedger.state(habit.rule, entry: nil, on: today, today: today)
            return state != .unscheduled && state != .notStarted
        }
        let weekDays = HabitLedger.days(endingOn: today, count: 7)
        let doneCount = due.filter { habit in
            HabitLedger.state(habit.rule, entry: grouped[habit.clientUUID]?[today], on: today, today: today) == .done
        }.count

        TodayCard(
            section: .habits,
            title: "Habits",
            count: doneCount,
            countLabel: "of \(due.count) done",
            isLoading: false,
            isEmpty: due.isEmpty,
            emptyText: habits.isEmpty ? "No habits yet." : "Nothing due today.",
            // The footer is the way in to create the first habit, so it stays.
            keepsFooterWhenEmpty: true
        ) {
            VStack(spacing: 0) {
                ForEach(Array(due.enumerated()), id: \.element.clientUUID) { index, habit in
                    let entries = grouped[habit.clientUUID] ?? [:]
                    TodayHabitRow(
                        habit: habit,
                        todayState: HabitLedger.state(habit.rule, entry: entries[today], on: today, today: today),
                        todayCount: entries[today].map { $0.status == .done ? $0.count : 0 } ?? 0,
                        streak: HabitLedger.currentStreak(habit.rule, entries: entries, today: today),
                        days: weekDays,
                        week: HabitLedger.states(habit.rule, entries: entries, days: weekDays, today: today),
                        onCheck: { check(habit, today: today) },
                        onOpen: { onOpen(habit) }
                    )
                    if index < due.count - 1 {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Space.lg)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.danger)
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.sm)
                }
            }
        } footer: {
            TodayCardFooter(label: habits.isEmpty ? "Set up habits" : "All habits") { onOpen(nil) }
        }
    }

    private func check(_ habit: LocalHabit, today: Date) {
        do {
            try HabitService.default().tap(habit, today: today)
            errorMessage = nil
            Haptics.tick()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One habit on the Today card.
///
/// Two lines. The name line: badge, name, the streak, and the one-tap check on
/// the trailing edge. Under it, the last seven days at full width, big enough to
/// read at a glance: that trend is the point of the card.
///
/// Done today dims the NAME LINE only. The trend keeps full strength, because a
/// dimmed week would be hardest to read on exactly the days that went well.
///
/// The check is a sibling Button, never nested inside the open Button. The name
/// line is a Button that opens the section; the trend opens it too, on a tap.
private struct TodayHabitRow: View {
    let habit: LocalHabit
    let todayState: HabitDayState
    let todayCount: Int
    let streak: Int
    let days: [Date]
    let week: [HabitDayState]
    let onCheck: () -> Void
    let onOpen: () -> Void

    private var isDone: Bool { todayState == .done }
    private var target: Int { max(1, habit.targetCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Button(action: onOpen) {
                    HStack(spacing: Space.md) {
                        HabitBadge(habit: habit, size: 32)
                        Text(habit.name)
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.ink)
                            .strikethrough(isDone, color: Tokens.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: Space.sm)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilitySummary)
                .accessibilityHint("Opens Habits")
                .opacity(isDone ? 0.55 : 1)

                if streak > 0 {
                    streakBadge
                }

                checkButton
            }

            HabitWeekTrend(days: days, states: week, tint: habit.tint, size: 30)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .animation(.easeOut(duration: 0.2), value: isDone)
    }

    /// The streak, next to the name and in the habit colour. Kept at full
    /// strength when the row dims: a streak that just grew is the reward.
    private var streakBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(habit.tint)
            Text("\(streak)")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 4)
        .background(habit.tint.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(streak) day streak")
    }

    @ViewBuilder
    private var checkButton: some View {
        Button(action: onCheck) {
            if target > 1 {
                // A count habit: the count, and a ring that fills toward the target.
                ZStack {
                    HabitDayMark(
                        state: todayCount >= target ? .done
                            : (todayCount > 0 ? .partial(count: todayCount, target: target) : .pending),
                        tint: habit.tint,
                        size: 34
                    )
                    if todayCount < target {
                        Text("\(todayCount)")
                            .font(.edCaption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.ink)
                            .monospacedDigit()
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            } else {
                HabitDayMark(state: isDone ? .done : .pending, tint: habit.tint, size: 30)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checkLabel)
    }

    private var checkLabel: String {
        if target > 1 {
            return "Add one to \(habit.name), \(todayCount) of \(target)"
        }
        return isDone ? "Mark \(habit.name) not done" : "Mark \(habit.name) done"
    }

    private var accessibilitySummary: String {
        // The streak badge speaks for itself, so it is not repeated here.
        [habit.name, todayState.label].joined(separator: ", ")
    }
}
