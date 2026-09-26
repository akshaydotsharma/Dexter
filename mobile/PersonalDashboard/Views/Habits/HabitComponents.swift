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
/// - pending (today): an empty ring in the habit colour, the "do me" state
/// - every other day: ONE empty circle. A past due day with nothing logged, a
///   day the habit does not ask for, a day before the start, and a future day
///   all look the same (#664). There is no "missed" mark and no red (#661).
///
/// The states still differ where it matters: a future day is disabled by
/// `HabitDayCell`, and every state keeps its own accessibility label.
///
/// Every mark in one view is one size (#664). The first version shrank and
/// faded the not-due mark and dashed the future one, so a strip whose start
/// day had moved back showed prominent and faded circles side by side, which
/// read as a bug.
struct HabitDayMark: View {
    let state: HabitDayState
    let tint: Color
    var size: CGFloat = HabitDayMark.sectionSize

    /// The one mark size on the Habits page: the 7-day strip AND the month
    /// grid (#664). The Today card passes its own, larger size.
    static let sectionSize: CGFloat = 30

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
            case .pending:
                Circle().strokeBorder(tint, lineWidth: max(1.5, size * 0.07))
            case .missed, .unscheduled, .notStarted, .future:
                emptyMark
            }
        }
        .frame(width: size, height: size)
    }

    /// The empty day: a paper disc with a thin rule. The one look for every
    /// day with nothing logged that is not today.
    private var emptyMark: some View {
        ZStack {
            Circle().fill(Tokens.paper2.opacity(0.6))
            Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1)
        }
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
/// days are locked, and they render as a plain label, not a Button. Every
/// other day is a Button, not a tap gesture, so macOS QA and VoiceOver can
/// reach it.
struct HabitDayCell<Label: View>: View {
    let day: Date
    let state: HabitDayState
    let actions: HabitDayActions
    @ViewBuilder let label: () -> Label

    var body: some View {
        if state.isLoggable {
            Button { actions.toggle(day) } label: {
                // At least 44pt tall around the smaller mark (#664), so the target
                // stays the column width by 44pt whatever the mark size is.
                label()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { actions.set(day, .done) } label: { SwiftUI.Label("Done", systemImage: "checkmark") }
                if actions.isCountHabit {
                    Button { actions.partial(day) } label: { SwiftUI.Label("Partial…", systemImage: "circle.lefthalf.filled") }
                }
                Button { actions.set(day, .skipped) } label: { SwiftUI.Label("Skip", systemImage: "minus") }
                Button { actions.set(day, .cleared) } label: { SwiftUI.Label("Clear", systemImage: "arrow.uturn.backward") }
            }
            .accessibilityLabel("\(HabitDayFormat.long(day)), \(state.label)")
            .accessibilityHint(hint)
        } else {
            // A future day is not a Button at all, rather than a DISABLED one:
            // a disabled plain Button dims its label, and #664 wants the future
            // to look exactly like every other empty day. It still cannot be
            // tapped, and it still says "upcoming".
            label()
                .frame(minHeight: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(HabitDayFormat.long(day)), \(state.label)")
        }
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
                        HabitDayMark(state: state, tint: tint, size: HabitDayMark.sectionSize)
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
                                HabitDayMark(state: state, tint: tint, size: HabitDayMark.sectionSize)
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
/// what a reader scans by.
///
/// Past marks are display only; the card row owns their tap. The LAST column
/// (today) can be the check control (#665): pass `today` and that column
/// becomes a Button, at least 44pt tall and the column wide, with its own
/// label, hint and context menu. The Today card used to draw a second check
/// button beside the streak, so today showed twice.
///
/// Each mark is its own accessibility element ("Tuesday, done"), so VoiceOver
/// can step through the week instead of hearing one run-on label.
struct HabitWeekTrend: View {
    let days: [Date]
    let states: [HabitDayState]
    let tint: Color
    var size: CGFloat = 28
    var today: TodayControl? = nil

    /// What makes today's column a control.
    struct TodayControl {
        /// One tap: check / uncheck, or add one for a count habit.
        let onTap: () -> Void
        /// Shown in a context menu when today has something logged, so a
        /// count habit can get back to 0. Nil hides the menu.
        let onClear: (() -> Void)?
        /// Drawn over the mark: a count habit's count while under target.
        let overlayText: String?
        let accessibilityLabel: String
        let accessibilityHint: String
    }

    var body: some View {
        let pairs = Array(zip(days, states))
        HStack(spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                let (day, state) = pair
                if index == pairs.count - 1, let today {
                    Button(action: today.onTap) {
                        column(day: day, state: state, overlayText: today.overlayText)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let onClear = today.onClear {
                            Button(action: onClear) {
                                Label("Clear today", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                    .accessibilityLabel(today.accessibilityLabel)
                    .accessibilityHint(today.accessibilityHint)
                } else {
                    column(day: day, state: state, overlayText: nil)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(HabitDayFormat.weekdayName(day)), \(state.label)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days")
    }

    private func column(day: Date, state: HabitDayState, overlayText: String?) -> some View {
        VStack(spacing: 4) {
            Text(HabitDayFormat.weekdayLetter(day))
                .eyebrow()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            ZStack {
                HabitDayMark(state: state, tint: tint, size: size)
                if let overlayText {
                    Text(overlayText)
                        .font(.edCaption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Tokens.ink)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Lays out a row as N equal columns, with the FIRST subview across the
/// leading N-1 columns and the SECOND centred on the last column (#665).
///
/// `HabitWeekTrend` divides the same width into N equal columns, so a view in
/// the second slot sits exactly over today's mark at any width. That is the
/// streak pill on the Today card. It is placed by the same arithmetic as the
/// columns, never by a padding guessed from one screen width.
struct LastColumnLayout: Layout {
    var columns: Int = 7

    static func lastColumnCentre(width: CGFloat, columns: Int) -> CGFloat {
        let column = width / CGFloat(max(columns, 1))
        return width - column / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let column = width / CGFloat(max(columns, 1))
        let height = subviews.enumerated().map { index, view in
            let w = index == 0 ? width - column : column
            return view.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = bounds.width / CGFloat(max(columns, 1))
        if subviews.indices.contains(0) {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: bounds.width - column, height: bounds.height)
            )
        }
        if subviews.indices.contains(1) {
            // Centred on the last column. A pill wider than the column
            // overflows evenly on both sides, so its centre stays on the mark.
            subviews[1].place(
                at: CGPoint(x: bounds.minX + Self.lastColumnCentre(width: bounds.width, columns: columns), y: bounds.midY),
                anchor: .center,
                proposal: .unspecified
            )
        }
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
