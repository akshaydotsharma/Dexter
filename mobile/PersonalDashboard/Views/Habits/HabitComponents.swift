import SwiftUI

// MARK: - Day formatting

/// Formatters for habit days (#661). Built once (#614), and every one is fed
/// `WallClock.deviceDay(from:)` first, never a raw anchor: an anchor formatted
/// in a device timezone west of UTC prints the day before (#506).
enum HabitDayFormat {
    private static let weekdayLetter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()

    private static let weekdayName: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let dayNumber: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d")
        return f
    }()

    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    private static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f
    }()

    static func monthYear(_ anchor: Date) -> String { monthYear.string(from: WallClock.deviceDay(from: anchor)) }

    static func weekdayLetter(_ anchor: Date) -> String { weekdayLetter.string(from: WallClock.deviceDay(from: anchor)) }
    static func weekdayName(_ anchor: Date) -> String { weekdayName.string(from: WallClock.deviceDay(from: anchor)) }
    static func dayNumber(_ anchor: Date) -> String { dayNumber.string(from: WallClock.deviceDay(from: anchor)) }
    static func long(_ anchor: Date) -> String { long.string(from: WallClock.deviceDay(from: anchor)) }
}

// MARK: - The mark for one day

/// One day of one habit, drawn (#661).
///
/// Encoded by SHAPE and glyph first, colour second, so no state depends on
/// telling two hues apart:
///
/// - done: solid in the habit colour, with a check
/// - partial: a ring filled part-way round, in the habit colour
/// - skipped: a flat paper disc with a dash
/// - not done (a past due day with nothing logged): an empty circle. There is
///   no "missed" mark and no red: a day is done or it is empty (#661)
/// - pending (today): an empty ring in the habit colour, the "do me" state
/// - not due / before start: a SMALLER, fainter empty circle, so the days the
///   habit asks for still stand out from the days it does not
/// - future: a dashed outline
struct HabitDayMark: View {
    let state: HabitDayState
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            switch state {
            case .done, .extra:
                Circle().fill(tint)
                glyph("checkmark", Tokens.accentFg)
            case .partial(let count, let target):
                Circle().fill(Tokens.paper2)
                progressRing(fraction: target > 0 ? Double(count) / Double(target) : 0)
            case .skipped:
                Circle().fill(Tokens.paper2)
                glyph("minus", Tokens.muted)
            case .missed:
                emptyMark(scale: 1)
            case .pending:
                Circle().strokeBorder(tint, lineWidth: max(1.5, size * 0.07))
            case .unscheduled, .notStarted:
                emptyMark(scale: 0.62)
                    .opacity(0.7)
            case .future:
                Circle().strokeBorder(Tokens.border, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
    }

    /// The empty day: a paper disc with a thin rule. `scale` shrinks it for a
    /// day the habit does not ask for.
    private func emptyMark(scale: CGFloat) -> some View {
        ZStack {
            Circle().fill(Tokens.paper2.opacity(0.6))
            Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1)
        }
        .frame(width: size * scale, height: size * scale)
    }

    private func progressRing(fraction: Double) -> some View {
        let line = max(2, size * 0.12)
        return ZStack {
            Circle().strokeBorder(tint.opacity(0.25), lineWidth: line)
            Circle()
                .inset(by: line / 2)
                .trim(from: 0, to: min(max(fraction, 0.08), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: max(7, size * 0.42), weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - Day actions

/// What a day cell can do (#661). The section builds one of these per habit, so
/// the strip and the month grid share exactly one behaviour.
struct HabitDayActions {
    /// One tap: check or uncheck.
    let toggle: (Date) -> Void
    /// A context-menu choice: Done, Skip, Clear.
    let set: (Date, HabitDaySetting) -> Void
    /// "Partial..." opens the day sheet for the count.
    let partial: (Date) -> Void
    /// Whether the habit has a count target, so Partial is offered.
    let isCountHabit: Bool
}

/// One tappable day (#661), used by the week strip and the month grid.
///
/// A tap is a direct check / uncheck, with no sheet. Partial and Skip live in
/// the context menu (long-press on iOS, right-click on the Mac). Only future
/// days are disabled. It is a Button, not a tap gesture, so macOS QA and
/// VoiceOver can reach it.
struct HabitDayCell<Label: View>: View {
    let day: Date
    let state: HabitDayState
    let actions: HabitDayActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { actions.toggle(day) } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.isLoggable)
        .contextMenu {
            if state.isLoggable {
                Button { actions.set(day, .done) } label: { SwiftUI.Label("Done", systemImage: "checkmark") }
                if actions.isCountHabit {
                    Button { actions.partial(day) } label: { SwiftUI.Label("Partial…", systemImage: "circle.lefthalf.filled") }
                }
                Button { actions.set(day, .skipped) } label: { SwiftUI.Label("Skip", systemImage: "minus") }
                Button { actions.set(day, .cleared) } label: { SwiftUI.Label("Clear", systemImage: "arrow.uturn.backward") }
            }
        }
        .accessibilityLabel("\(HabitDayFormat.long(day)), \(state.label)")
        .accessibilityHint(hint)
    }

    private var hint: String {
        guard state.isLoggable else { return "" }
        return state.isChecked ? "Uncheck this day" : "Check this day"
    }
}

// MARK: - The section's week strip

/// The last seven days ending today, labelled, each one a `HabitDayCell` (#661).
struct HabitWeekStrip: View {
    let days: [Date]
    let states: [HabitDayState]
    let tint: Color
    let actions: HabitDayActions

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<min(days.count, states.count), id: \.self) { index in
                let day = days[index]
                let state = states[index]
                HabitDayCell(day: day, state: state, actions: actions) {
                    VStack(spacing: Space.xs) {
                        Text(HabitDayFormat.weekdayLetter(day))
                            .eyebrow()
                        HabitDayMark(state: state, tint: tint, size: 34)
                        Text(HabitDayFormat.dayNumber(day))
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - The month view

/// One month of one habit, with month-to-month navigation (#661).
///
/// Opens on the month it is given. `‹` stops at `earliestMonth`, `›` stops at
/// the current month. The grid is weekday-aligned in the device's first-weekday
/// order, which is the order the week strip reads in too.
///
/// Every slot id is DISTINCT by construction: a day's id is its anchor, a blank
/// slot's id is its negative index. Two ForEach blocks with offset ids is what
/// dropped and shifted cells in the first grid.
struct HabitMonthView: View {
    let rule: HabitRule
    let entries: [Date: HabitDayEntry]
    let today: Date
    let tint: Color
    let actions: HabitDayActions
    @Binding var month: Date

    private var firstWeekday: Int { Calendar.current.firstWeekday }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        let currentMonth = HabitLedger.monthStart(for: today)
        let earliest = min(HabitLedger.earliestMonth(rule, entries: entries), currentMonth)
        let shown = HabitLedger.monthStart(for: month)
        let summary = HabitLedger.monthSummary(rule, entries: entries, month: shown, today: today)

        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Button { month = HabitLedger.month(-1, from: shown) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(EdIconButtonStyle(tint: Tokens.inkSoft, size: 36))
                .disabled(shown <= earliest)
                .opacity(shown <= earliest ? 0.3 : 1)
                .accessibilityLabel("Previous month")

                Spacer()
                Text(HabitDayFormat.monthYear(shown))
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                Spacer()

                Button { month = HabitLedger.month(1, from: shown) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(EdIconButtonStyle(tint: Tokens.inkSoft, size: 36))
                .disabled(shown >= currentMonth)
                .opacity(shown >= currentMonth ? 0.3 : 1)
                .accessibilityLabel("Next month")
            }

            summaryLine(summary)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<7, id: \.self) { column in
                    Text(Self.weekdayInitial((column + firstWeekday - 1) % 7))
                        .eyebrow()
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(slots(for: shown), id: \.id) { slot in
                    if let day = slot.day {
                        let state = HabitLedger.state(rule, entry: entries[day], on: day, today: today)
                        HabitDayCell(day: day, state: state, actions: actions) {
                            VStack(spacing: 2) {
                                HabitDayMark(state: state, tint: tint, size: 30)
                                Text(HabitDayFormat.dayNumber(day))
                                    .font(.edCaption)
                                    .foregroundStyle(day == HabitLedger.key(today) ? Tokens.ink : Tokens.muted)
                                    .fontWeight(day == HabitLedger.key(today) ? .semibold : .regular)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    /// "Done 18 · Skipped 1   86%" — what happened that month.
    private func summaryLine(_ summary: HabitMonthSummary) -> some View {
        var parts = ["Done \(summary.done)", "Skipped \(summary.skipped)"]
        if summary.extra > 0 { parts.append("Extra \(summary.extra)") }
        let rate = summary.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        return HStack(spacing: Space.sm) {
            Text(parts.joined(separator: " · "))
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(2)
            Spacer(minLength: Space.sm)
            Text(rate)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .monospacedDigit()
                .accessibilityLabel("Rate \(rate)")
        }
        .accessibilityElement(children: .combine)
    }

    private struct Slot {
        let id: Int
        let day: Date?
    }

    private func slots(for month: Date) -> [Slot] {
        let days = HabitLedger.daysInMonth(of: month)
        guard let first = days.first else { return [] }
        let weekday = HabitLedger.weekdayIndex(of: first) + 1
        let blanks = (weekday - firstWeekday + 7) % 7
        return (0..<blanks).map { Slot(id: -1 - $0, day: nil) }
            + days.map { Slot(id: Int($0.timeIntervalSince1970), day: $0) }
    }

    private static func weekdayInitial(_ sundayBased: Int) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return symbols.indices.contains(sundayBased) ? symbols[sundayBased] : ""
    }
}

// MARK: - The Today trend row

/// The last seven days as a full-width row of marks, for the Today card (#661).
///
/// The same visual language as `HabitWeekStrip` (weekday letter above, the same
/// mark), without the date number: the card is a glance, and the letter is
/// what a reader scans by. Display only; the card row owns the tap.
///
/// Each mark is its own accessibility element ("Tuesday, done"), so VoiceOver
/// can step through the week instead of hearing one run-on label.
struct HabitWeekTrend: View {
    let days: [Date]
    let states: [HabitDayState]
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(days, states).enumerated()), id: \.offset) { _, pair in
                let (day, state) = pair
                VStack(spacing: 4) {
                    Text(HabitDayFormat.weekdayLetter(day))
                        .eyebrow()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HabitDayMark(state: state, tint: tint, size: size)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(HabitDayFormat.weekdayName(day)), \(state.label)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days")
    }
}

// MARK: - The habit's badge

/// The emoji, or a colour disc when there is no emoji (#661).
struct HabitBadge: View {
    let habit: LocalHabit
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(habit.tint.opacity(0.16))
            if habit.emoji.isEmpty {
                Circle().fill(habit.tint).frame(width: size * 0.36, height: size * 0.36)
            } else {
                Text(habit.emoji).font(.system(size: size * 0.52))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Every day", "Mon, Wed, Fri", with the target when there is one.
enum HabitScheduleText {
    static func summary(for habit: LocalHabit) -> String {
        var parts: [String] = []
        switch habit.scheduleEnum {
        case .daily:
            parts.append("Every day")
        case .weekdays:
            parts.append(weekdays(mask: habit.weekdayMask))
        }
        if habit.targetCount > 1 {
            parts.append("\(habit.targetCount)\(habit.unit.map { " \($0)" } ?? "") a day")
        }
        return parts.joined(separator: " · ")
    }

    /// Weekday names in the device's first-weekday order.
    static func weekdays(mask: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        let ordered = (0..<7).map { ($0 + first) % 7 }
        let picked = ordered.filter { mask & (1 << $0) != 0 }
        if picked.count == 7 { return "Every day" }
        if Set(picked) == Set(1...5) { return "Weekdays" }
        return picked.map { symbols[$0] }.joined(separator: ", ")
    }
}
