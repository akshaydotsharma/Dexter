import SwiftUI

/// The month grid, as the Plan tab's month scope (#599).
///
/// ### What a cell says, and what it deliberately does not
///
/// A numeral and four pips. No calorie figure and no quantity bar, which is
/// where this differs from `MealCalendarCard` and why it is a separate view
/// rather than a parameter on that one.
///
/// A planned block usually carries no numbers at all — the user typed a title
/// and moved on — so a calorie figure would be blank on most squares and, worse,
/// would be a PARTIAL total on the rest. "1,200" on a day whose two numberless
/// blocks are missing from it is a false statement in the one place on the
/// surface with no room to qualify it. The day panel prints the total with its
/// caveat attached; a square cannot.
///
/// ### It steps forward without limit
///
/// The Tracking calendar stops at the current month because there are no meals
/// to log in the future. A plan lives there. See the note on `MealPlanCalendar`.
struct MealPlanMonthGrid: View {

    /// The month on screen, device-local midnight of its first day.
    @Binding var month: Date
    @Binding var selectedDay: Date
    /// Every planned day, keyed by stored day anchor.
    let readings: [Date: MealPlanReading]
    /// Injected so a test or a preview can pin "now".
    var today: Date = Date()

    private var calendar: Calendar { Calendar.current }

    private var slots: [MealCalendarSlot] {
        MealPlanCalendar.monthSlots(forMonthOf: month, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
            weekdayRow
            grid
        }
        .padding(Space.md)
        .frame(maxWidth: MealPlanMetrics.maxWidth, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Space.sm) {
            stepButton(icon: "chevron.left", label: "Previous month") { step(-1) }

            Text(Self.monthFormatter.string(from: month))
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            stepButton(icon: "chevron.right", label: "Next month") { step(1) }
        }
    }

    private func stepButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.inkSoft)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        HStack(spacing: MealPlanMetrics.gutter) {
            ForEach(Array(MealPlanCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .eyebrow()
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MealPlanMetrics.gutter),
            count: 7
        )
        return LazyVGrid(columns: columns, spacing: MealPlanMetrics.gutter) {
            ForEach(slots) { slot in
                if let day = slot.day {
                    cell(for: day)
                } else {
                    Color.clear
                        .frame(height: MealPlanMetrics.monthCell)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - One day

    private func cell(for day: Date) -> some View {
        let reading = MealPlanDay.reading(for: day, in: readings)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 3) {
                Text(Self.dayNumberFormatter.string(from: day))
                    .font(reading.isEmpty ? .edFootnote : .edFootnoteStrong)
                    .foregroundStyle(reading.isEmpty ? Tokens.mutedSoft : Tokens.ink)
                    .monospacedDigit()
                Spacer(minLength: 0)
                MealPlanDayPips(reading: reading)
            }
            .padding(.vertical, Space.xs)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: MealPlanMetrics.monthCell)
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
        .accessibilityLabel(
            "\(Self.spokenDayFormatter.string(from: day)), \(MealPlanDayPips.spokenSummary(reading))"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Actions

    private func step(_ months: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            month = MealPlanCalendar.stepMonth(month, by: months, calendar: calendar)
        }
    }

    // MARK: - Formatters

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
