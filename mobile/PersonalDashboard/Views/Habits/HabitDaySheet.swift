import SwiftUI

/// Which day of which habit the day editor is open on (#661).
struct HabitDaySelection: Identifiable, Equatable {
    let habitUUID: String
    let day: Date
    var id: String { HabitCheckInID.make(habitUUID: habitUUID, day: day) }
}

/// Set one past (or today's) day: done, partial, skipped, or cleared (#661).
///
/// Four plain Buttons rather than a picker, because each is a complete action
/// and a picker would need a Save after it. Partial appears only for a count
/// habit: a yes/no habit has no "some of it".
///
/// Future days never reach this sheet (their cells are disabled), and
/// `HabitService` refuses them anyway.
struct HabitDaySheet: View {
    @Environment(\.dismiss) private var dismiss

    let habit: LocalHabit
    let day: Date
    let state: HabitDayState

    @State private var partialCount: Int = 1
    @State private var errorMessage: String?

    private var target: Int { max(1, habit.targetCount) }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.md) {
                        HabitBadge(habit: habit, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(habit.name)
                                .font(.edHeading)
                                .foregroundStyle(Tokens.ink)
                                .lineLimit(1)
                            Text("\(HabitDayFormat.long(day)) · \(state.label.capitalizedFirst)")
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.muted)
                        }
                        Spacer()
                        HabitDayMark(state: state, tint: habit.tint, size: 30)
                    }

                    VStack(spacing: Space.sm) {
                        Button {
                            apply(.done)
                        } label: {
                            Label(target > 1 ? "Done, \(target) of \(target)" : "Done", systemImage: "checkmark")
                        }
                        .buttonStyle(EdButtonStyle(kind: .primary, fullWidth: true))

                        if target > 1 {
                            HStack(spacing: Space.sm) {
                                Stepper(value: $partialCount, in: 1...(target - 1)) {
                                    Text("\(partialCount) of \(target)\(habit.unit.map { " \($0)" } ?? "")")
                                        .font(.edBody)
                                        .foregroundStyle(Tokens.ink)
                                        .monospacedDigit()
                                }
                                Button("Set") { apply(.partial(partialCount)) }
                                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                            }
                            .padding(Space.md)
                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                            .paperBorder(Tokens.border, radius: Radius.md)
                        }

                        Button {
                            apply(.skipped)
                        } label: {
                            Label("Skip this day", systemImage: "minus")
                        }
                        .buttonStyle(EdButtonStyle(kind: .secondary, fullWidth: true))

                        Text("A skipped day keeps your streak and is left out of the rate.")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            apply(.cleared)
                        } label: {
                            Label("Clear", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(EdButtonStyle(kind: .ghost, fullWidth: true))
                        .disabled(!hasLog)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.danger)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.lg)
            }
            .navigationTitle("Change day")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 420)
        #else
        .presentationDetents([.medium])
        #endif
        .onAppear {
            if case .partial(let count, _) = state { partialCount = min(max(1, count), max(1, target - 1)) }
        }
    }

    private var hasLog: Bool {
        switch state {
        case .done, .partial, .skipped: return true
        default: return false
        }
    }

    private func apply(_ setting: HabitDaySetting) {
        do {
            try HabitService.default().set(habit, on: day, to: setting)
            Haptics.tick()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
