import SwiftUI

/// Dexter's own day field, in place of the system date picker (#599).
///
/// ### Why not `DatePicker`
///
/// `DatePicker(.compact)` draws Apple's control, not ours: system blue, system
/// corner radii, system type, and a popover with its own chrome. It was the one
/// thing on the plan sheet that belonged to a different app. Every other field
/// on that sheet is a Dexter field, so the day was the odd one out in the one
/// place a user is most likely to be comparing them — a column of fields, read
/// top to bottom.
///
/// ### The grammar it follows instead
///
/// The `TripCalendarPopover` (#230) already established what a Dexter calendar
/// looks like: a 300pt card, an eyebrow weekday row, 32pt circular day cells,
/// an accent fill for the day that matters and a ring for today. This is that
/// calendar made selectable, so the two are the same object with the same
/// reading, and a third calendar design does not enter the app.
///
/// ### One field, one value
///
/// The field shows the day in full ("Thu 17 Sep 2026") rather than as digits.
/// A plan is written in weekdays — "Thursday's dinner" — and a row of digits
/// makes the reader do the conversion every time.
struct EdDayPicker: View {
    @Binding var day: Date

    /// What the field is for, spoken and shown above it by the caller.
    var accessibilityName: String = "Day"
    /// The hue the selected day is drawn in. Defaults to the Meals accent
    /// because that is where this began; every caller passes its own section's.
    var tint: Color = Tokens.accent(for: .meals)
    /// The days that may be chosen. Nil is any day, which a plan needs: the
    /// future is the part of it that matters.
    var bounds: ClosedRange<Date>? = nil
    /// True in a column of fields, where the day field matches the width of the
    /// ones above and below it. False in a flowing row, where a field that took
    /// the whole width would push its neighbours onto their own lines.
    var fillsWidth: Bool = true

    @State private var isOpen = false

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(Self.fieldFormatter.string(from: day))
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Self.spokenFormatter.string(from: day))
        .accessibilityHint("Opens a calendar")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            EdDayPickerCalendar(day: $day, tint: tint, bounds: bounds) { isOpen = false }
        }
    }

    private static let fieldFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    private static let spokenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()
}

/// The calendar inside `EdDayPicker`, in the Dexter card grammar.
///
/// Held as its own type so a caller that already has a surface to put a
/// calendar on — a sheet, a panel — can use it without the field.
struct EdDayPickerCalendar: View {
    @Binding var day: Date
    var tint: Color = Tokens.accent(for: .meals)
    /// The days that may be chosen. A day outside it is drawn but not tappable,
    /// because a month with holes in it is harder to read than a month with
    /// days you cannot take.
    var bounds: ClosedRange<Date>? = nil
    /// Called after a day is chosen. The picker closes on selection: choosing a
    /// day is the whole errand, and leaving the card open afterwards makes the
    /// user dismiss a thing they have finished with.
    var onPick: () -> Void = {}

    @State private var month: Date = Date()
    @State private var seeded = false

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EdDayPickerMetrics.gutter), count: 7)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            weekdayRow
            grid
            footer
        }
        .padding(Space.lg)
        .frame(width: EdDayPickerMetrics.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Tokens.surface)
        )
        .paperBorder(Tokens.border, radius: Radius.lg)
        .presentationBackground(Tokens.surface)
        .presentationCompactAdaptation(.popover)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            month = MealCalendar.monthStart(of: day, calendar: calendar)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text(Self.monthFormatter.string(from: month))
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
            Spacer(minLength: 0)
            stepButton("chevron.left", "Previous month") { step(-1) }
            stepButton("chevron.right", "Next month") { step(1) }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        LazyVGrid(columns: columns, spacing: EdDayPickerMetrics.gutter) {
            ForEach(Array(MealCalendar.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .eyebrow()
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: EdDayPickerMetrics.gutter) {
            ForEach(MealCalendar.slots(forMonthOf: month, calendar: calendar)) { slot in
                if let date = slot.day {
                    cell(date)
                } else {
                    Color.clear
                        .frame(height: EdDayPickerMetrics.cell)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// "Today" as a named destination, not as a date to hunt for.
    ///
    /// Every day field in this app is set to a day near now far more often than
    /// to an arbitrary one, and paging back to the current month to find it is
    /// the most repeated gesture a calendar asks for.
    private var footer: some View {
        HStack(spacing: Space.sm) {
            if isAllowed(today) {
                Button("Today") { pick(today) }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            if isAllowed(tomorrow) {
                Button("Tomorrow") { pick(tomorrow) }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - One day

    private func cell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: day)
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let allowed = isAllowed(date)

        return Button {
            pick(date)
        } label: {
            ZStack {
                Circle().fill(isSelected ? tint : Color.clear)
                if isToday && !isSelected {
                    Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1)
                }
                Text(Self.dayFormatter.string(from: date))
                    .font(isSelected ? .edFootnoteStrong : .edFootnote)
                    .foregroundStyle(
                        isSelected ? Tokens.accentFg : (allowed ? Tokens.inkSoft : Tokens.mutedSoft)
                    )
                    .monospacedDigit()
            }
            .frame(height: EdDayPickerMetrics.cell)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .accessibilityLabel(Self.spokenFormatter.string(from: date))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func isAllowed(_ date: Date) -> Bool {
        guard let bounds else { return true }
        let start = calendar.startOfDay(for: date)
        return start >= calendar.startOfDay(for: bounds.lowerBound)
            && start <= calendar.startOfDay(for: bounds.upperBound)
    }

    // MARK: - Actions

    private func pick(_ date: Date) {
        guard isAllowed(date) else { return }
        day = calendar.startOfDay(for: date)
        month = MealCalendar.monthStart(of: date, calendar: calendar)
        onPick()
    }

    private func step(_ months: Int) {
        guard let moved = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            month = MealCalendar.monthStart(of: moved, calendar: calendar)
        }
    }

    // MARK: - Formatters

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    private static let spokenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
}

/// Fixed metrics for the day picker, matching `TripCalendarPopover` so the two
/// Dexter calendars are one object at one size.
enum EdDayPickerMetrics {
    static let cardWidth: CGFloat = 300
    static let cell: CGFloat = 32
    static let gutter: CGFloat = 6
}
