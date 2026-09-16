import SwiftUI

/// The seven days of one week, as the Plan tab's week scope (#599).
///
/// ### Why a strip and not a second grid
///
/// A week has seven days and a month grid already draws seven across. Rendering
/// a week as a one-row month would make the two scopes look identical and leave
/// the switch between them doing nothing visible. A strip is a different object:
/// it is wider per day, it names the weekday on every cell, and it is what the
/// day panel below hangs off.
///
/// ### It can always step forward
///
/// Unlike the Tracking calendar, which stops at today because a meal you have
/// not eaten is not a log entry. Planning forward is the entire point here, so
/// neither arrow is ever disabled and there is no clamp — see the note on
/// `MealPlanCalendar`.
struct MealPlanWeekStrip: View {

    /// Any day inside the week on screen. Held apart from `selectedDay` so
    /// stepping to next week does not move the selection off the day the panel
    /// below is reading until the user picks one.
    @Binding var week: Date
    @Binding var selectedDay: Date
    /// Every planned day, keyed by stored day anchor.
    let readings: [Date: MealPlanReading]
    /// Injected so a test or a preview can pin "now". The view never reads the
    /// clock itself.
    var today: Date = Date()

    private var calendar: Calendar { Calendar.current }

    private var days: [Date] {
        MealPlanCalendar.weekDays(of: week, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            strip
        }
        .padding(Space.lg)
        .frame(maxWidth: MealPlanMetrics.maxWidth, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Space.sm) {
            stepButton(icon: "chevron.left", label: "Previous week") { step(-1) }

            Text(weekLabel)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)

            stepButton(icon: "chevron.right", label: "Next week") { step(1) }
        }
    }

    /// "8 – 14 Sep", collapsing the month when both ends share one and the year
    /// when it is this one. A week that straddles a month prints both.
    private var weekLabel: String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
        let sameYearAsToday = calendar.isDate(first, equalTo: today, toGranularity: .year)
        let tail = sameYearAsToday
            ? Self.dayMonth.string(from: last)
            : Self.dayMonthYear.string(from: last)
        let head = sameMonth
            ? Self.dayOnly.string(from: first)
            : Self.dayMonth.string(from: first)
        return "\(head) – \(tail)"
    }

    private func stepButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.inkSoft)
        .accessibilityLabel(label)
    }

    // MARK: - The seven

    private var strip: some View {
        HStack(spacing: MealPlanMetrics.gutter) {
            ForEach(days, id: \.timeIntervalSinceReferenceDate) { day in
                cell(for: day)
            }
        }
    }

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
                Text(Self.weekdayLetter.string(from: day))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(Self.dayOnly.string(from: day))
                    .font(reading.isEmpty ? .edFootnote : .edFootnoteStrong)
                    .foregroundStyle(reading.isEmpty ? Tokens.mutedSoft : Tokens.ink)
                    .monospacedDigit()
                Spacer(minLength: 0)
                MealPlanDayPips(reading: reading)
            }
            .padding(.vertical, Space.sm)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: MealPlanMetrics.weekCell)
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
            "\(Self.spokenDay.string(from: day)), \(MealPlanDayPips.spokenSummary(reading))"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Actions

    private func step(_ weeks: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            week = MealPlanCalendar.stepWeek(week, by: weeks, calendar: calendar)
        }
    }

    // MARK: - Formatters
    //
    // Every date reaching these is a device-local midnight, never a stored
    // anchor, so a device-local formatter is correct (#506).

    private static let weekdayLetter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let spokenDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
}
