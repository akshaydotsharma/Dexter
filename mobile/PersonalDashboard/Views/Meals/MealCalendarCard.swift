import SwiftUI

/// Fixed metrics for the History month grid (#559).
///
/// Held here rather than as literals in the view for the same reason every other
/// metrics table in this app exists: the cell height and the bar height are read
/// together, and a change to one that is not a change to the other is the kind of
/// drift nobody notices until a row clips.
enum MealCalendarMetrics {
    /// Height of one day square. Tall enough for a numeral, a calorie figure and
    /// the quantity bar without any of the three shrinking.
    static let cell: CGFloat = 48
    /// Height of the quantity bar along the bottom of a logged square.
    static let bar: CGFloat = 3
    /// The narrowest a bar may be drawn once it is drawn at all, so the lightest
    /// logged day in a month is still visibly a mark and not an empty square.
    static let barMinimum: CGFloat = 3
    /// Gap between squares. Small: the grid should read as a block of days, not
    /// as forty-two separate cards.
    static let gutter: CGFloat = Space.xs
    /// The grid stops widening past this. On a Mac detail pane a full-width
    /// calendar gives 150 pt squares holding a two-digit number.
    static let maxWidth: CGFloat = 460
}

/// The month grid in History (#559).
///
/// ### Why the cells are not tinted
///
/// On this surface hue means a verdict about a day and nothing else — see
/// `MealStatPill`. Thirty coloured squares would spend the section's entire
/// colour budget on a screen whose job is to get you to one day, and they would
/// claim a verdict for every one of them, including the days before any targets
/// existed.
///
/// So quantity is carried by the three things that survive greyscale. The
/// numeral is heavier on a day that was logged. The counted calories are printed.
/// And a bar along the bottom of the square is scaled against the heaviest day in
/// the month on screen, so a heavy day is visible as a long mark before you read
/// a single figure. Nothing in the grid is coloured; the verdict arrives when you
/// tap a day and the card below draws it against a target.
///
/// ### Why an unlogged day is empty rather than zero
///
/// A blank day means the log was not kept. A low day means it was. That
/// difference is the entire value of keeping one, so a day with no meals gets no
/// figure and no bar, and its numeral drops to `mutedSoft`. A logged day whose
/// counted total is genuinely zero still gets its bar, at the minimum width, so
/// the two states can never be confused.
struct MealCalendarCard: View {

    /// The month on screen, device-local midnight of its first day.
    @Binding var month: Date
    /// The day the breakdown below is showing.
    @Binding var selectedDay: Date
    /// Every day that holds meals, keyed by stored day anchor.
    let readings: [Date: MealDayReading]
    /// Injected so a test or a preview can pin "now". The view never reads the
    /// clock itself.
    var today: Date = Date()

    private var calendar: Calendar { Calendar.current }

    private var slots: [MealCalendarSlot] {
        MealCalendar.slots(forMonthOf: month, calendar: calendar)
    }

    private var heaviest: Double? {
        MealCalendar.heaviest(among: slots, readings: readings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            weekdayRow
            grid
        }
        .padding(Space.lg)
        .frame(maxWidth: MealCalendarMetrics.maxWidth, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Space.sm) {
            stepButton(
                icon: "chevron.left",
                label: "Previous month",
                enabled: true
            ) { step(-1) }

            Text(Self.monthFormatter.string(from: month))
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            stepButton(
                icon: "chevron.right",
                label: "Next month",
                enabled: canStepForward
            ) { step(1) }
        }
    }

    /// Backwards is never disabled. A month with nothing in it is still reachable,
    /// so the grid cannot trap the user behind a gap in the log.
    private var canStepForward: Bool {
        MealCalendar.canStepForward(from: month, today: today, calendar: calendar)
    }

    private func stepButton(
        icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Tokens.inkSoft : Tokens.mutedSoft)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        HStack(spacing: MealCalendarMetrics.gutter) {
            ForEach(Array(MealCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .eyebrow()
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MealCalendarMetrics.gutter),
            count: 7
        )
        return LazyVGrid(columns: columns, spacing: MealCalendarMetrics.gutter) {
            ForEach(slots) { slot in
                if let day = slot.day {
                    cell(for: day)
                } else {
                    Color.clear
                        .frame(height: MealCalendarMetrics.cell)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - One day

    private func cell(for day: Date) -> some View {
        let reading = MealCalendar.reading(for: day, in: readings)
        let selectable = MealCalendar.isSelectable(day, today: today, calendar: calendar)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)

        return Button {
            guard selectable else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 2) {
                Text(Self.dayNumberFormatter.string(from: day))
                    .font(reading.isLogged ? .edFootnoteStrong : .edFootnote)
                    .foregroundStyle(numeralInk(selectable: selectable, logged: reading.isLogged))
                    .monospacedDigit()

                if let calories = reading.calories {
                    Text(MealFormat.calories(calories))
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    // Holds the numeral's position steady across a month in which
                    // only some days were logged, so the grid reads as a grid.
                    Text(" ")
                        .font(.edCaption)
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)

                quantityBar(for: reading)
            }
            .padding(.vertical, Space.xs)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: MealCalendarMetrics.cell)
            .background {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isSelected ? Tokens.surface2 : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .stroke(
                                isSelected ? Tokens.borderStrong : (isToday ? Tokens.border : Color.clear),
                                lineWidth: isSelected ? 1 : 0.5
                            )
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityLabel(accessibilityLabel(day: day, reading: reading, selectable: selectable))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func numeralInk(selectable: Bool, logged: Bool) -> Color {
        guard selectable else { return Tokens.mutedSoft.opacity(0.5) }
        return logged ? Tokens.ink : Tokens.mutedSoft
    }

    /// How much, as length. Scaled against the heaviest logged day in the month on
    /// screen, so the reading is a comparison within the month rather than a
    /// verdict against a target the day may predate.
    @ViewBuilder
    private func quantityBar(for reading: MealDayReading) -> some View {
        if let calories = reading.calories {
            GeometryReader { geo in
                let fraction = heaviest.map { min(max(calories / $0, 0), 1) } ?? 0
                Capsule()
                    .fill(Tokens.inkSoft)
                    .frame(
                        width: max(geo.size.width * fraction, MealCalendarMetrics.barMinimum),
                        height: MealCalendarMetrics.bar
                    )
            }
            .frame(height: MealCalendarMetrics.bar)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: MealCalendarMetrics.bar)
        }
    }

    private func accessibilityLabel(day: Date, reading: MealDayReading, selectable: Bool) -> String {
        let date = Self.spokenDayFormatter.string(from: day)
        guard selectable else { return "\(date), not yet" }
        switch reading {
        case .unlogged:
            return "\(date), not logged"
        case .logged(let calories):
            return "\(date), \(MealFormat.calories(calories)) kcal"
        }
    }

    // MARK: - Actions

    private func step(_ months: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            month = MealCalendar.step(month, byMonths: months, today: today, calendar: calendar)
        }
    }

    // MARK: - Formatters
    //
    // Every date reaching these is a device-local midnight, never a stored
    // anchor, so a device-local formatter is correct (#506).

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private static let spokenDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
}
