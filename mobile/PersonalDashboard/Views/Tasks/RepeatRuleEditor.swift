import SwiftUI

/// The editable shape of a recurrence rule (#524), held by whichever form is
/// collecting it.
///
/// A plain value type, not the `RecurringTask` model: the new-task editor
/// collects a rule for a template that does not exist yet, and cancelling has to
/// leave nothing behind. `RecurringTaskEditorSheet` seeds one from a stored
/// template and writes it back on save.
struct RecurrenceDraft: Equatable {
    var frequency: RecurrenceFrequency = .weekly
    var interval: Int = 1
    var weekdayMask: Int = 0
    var dayOfMonth: Int = 1
    var monthOfYear: Int = 1
    /// Device-local; only its hour and minute are stored.
    var timeOfDay: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var leadDays: Int = 3
    var startDate: Date = Date()
    var hasEndDate: Bool = false
    var endDate: Date = Date()

    var timeOfDayMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
        return (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
    }

    var resolvedEndDate: Date? { hasEndDate ? endDate : nil }

    /// Seed a draft that fits the day the form is being opened on, so a weekly
    /// rule starts with today's weekday ticked and a monthly one with today's
    /// date. Better than a fixed Sunday/1st, which someone has to correct every
    /// time.
    static func seeded(from reference: Date = Date()) -> RecurrenceDraft {
        let calendar = Calendar.current
        var draft = RecurrenceDraft()
        draft.startDate = reference
        draft.endDate = calendar.date(byAdding: .month, value: 1, to: reference) ?? reference
        draft.weekdayMask = 1 << (calendar.component(.weekday, from: reference) - 1)
        draft.dayOfMonth = calendar.component(.day, from: reference)
        draft.monthOfYear = calendar.component(.month, from: reference)
        return draft
    }

    /// Read a stored template back into an editable draft.
    static func from(template: RecurringTask) -> RecurrenceDraft {
        let calendar = Calendar.current
        var draft = RecurrenceDraft()
        draft.frequency = template.frequencyEnum
        draft.interval = max(1, template.interval)
        draft.weekdayMask = template.weekdayMask
        draft.dayOfMonth = template.dayOfMonth
        draft.monthOfYear = template.monthOfYear
        draft.timeOfDay = calendar.date(
            bySettingHour: template.timeOfDayMinutes / 60,
            minute: template.timeOfDayMinutes % 60,
            second: 0,
            of: Date()
        ) ?? Date()
        draft.leadDays = template.leadDays
        // Day fields come out of storage as UTC anchors and have to be read back
        // through `deviceDay` before a picker or a formatter touches them (#506).
        draft.startDate = WallClock.deviceDay(from: template.startDate)
        draft.hasEndDate = template.endDate != nil
        draft.endDate = template.endDate.map { WallClock.deviceDay(from: $0) }
            ?? (calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date())
        return draft
    }

    /// Whether this draft describes a rule the service will accept. Mirrors
    /// `RecurringTaskService.validate`, so the Save button and the service agree
    /// about what is savable rather than the user meeting an error on tap.
    var isValid: Bool {
        if interval < 1 { return false }
        if frequency == .weekly, weekdayMask == 0 { return false }
        if !(1...31).contains(dayOfMonth) { return false }
        return true
    }

    /// The rule in words, for a preview line under the controls.
    var summary: String {
        RecurrenceRule(
            frequency: frequency,
            interval: interval,
            weekdayMask: weekdayMask,
            dayOfMonth: dayOfMonth,
            monthOfYear: monthOfYear,
            timeOfDayMinutes: timeOfDayMinutes,
            startDay: startDate,
            endDay: resolvedEndDate
        ).summary
    }

    /// The first date this rule would produce, for the same preview line.
    var firstDate: Date? {
        let rule = RecurrenceRule(
            frequency: frequency,
            interval: interval,
            weekdayMask: weekdayMask,
            dayOfMonth: dayOfMonth,
            monthOfYear: monthOfYear,
            timeOfDayMinutes: timeOfDayMinutes,
            startDay: startDate,
            endDay: resolvedEndDate
        )
        guard let day = rule.nextDay(after: nil) else { return nil }
        return rule.dueDate(on: day)
    }
}

/// The repeat controls, shared by the template editor and the new-task editor so
/// a rule cannot be described two different ways depending on where it was made.
///
/// Renders only the fields the chosen frequency actually uses: a weekly rule
/// shows the weekday picker, a monthly one a day of the month, a yearly one a
/// month and day. Showing all of them at once would ask for values that mean
/// nothing for the selected rule.
struct RepeatRuleEditor: View {
    @Binding var draft: RecurrenceDraft
    /// Hidden on the new-task editor, which starts a template today by
    /// definition, and shown when editing an existing one.
    var showsStartDate: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            frequencyRow
            Divider().background(Tokens.divider)
            intervalRow

            if draft.frequency == .weekly {
                Divider().background(Tokens.divider)
                weekdayRow
            }
            if draft.frequency == .monthly {
                Divider().background(Tokens.divider)
                dayOfMonthRow
            }
            if draft.frequency == .yearly {
                Divider().background(Tokens.divider)
                monthAndDayRow
            }

            Divider().background(Tokens.divider)
            timeRow
            Divider().background(Tokens.divider)
            leadRow

            if showsStartDate {
                Divider().background(Tokens.divider)
                startRow
            }
            Divider().background(Tokens.divider)
            endRow
            Divider().background(Tokens.divider)
            previewRow
        }
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: - Rows

    private var frequencyRow: some View {
        HStack {
            Text("Repeats")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            Picker("Repeats", selection: $draft.frequency.animation()) {
                ForEach(RecurrenceFrequency.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Tokens.accentTasks)
        }
        .padding(Space.md)
    }

    private var intervalRow: some View {
        HStack {
            Text("Every")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            Text("\(draft.interval) \(draft.frequency.unit(plural: draft.interval != 1))")
                .font(.edBodyMedium)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
            Stepper(value: $draft.interval, in: 1...52) { EmptyView() }
                .labelsHidden()
                .fixedSize()
        }
        .padding(Space.md)
    }

    /// The weekday picker, rendered in the device's own first-weekday order. The
    /// STORED mask is Sunday-based whatever this shows, so a rule does not change
    /// meaning when the device moves to a locale whose weeks start on Monday.
    private var weekdayRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("On")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            HStack(spacing: Space.xs) {
                ForEach(orderedWeekdays, id: \.self) { index in
                    weekdayChip(index)
                }
            }
            if draft.weekdayMask == 0 {
                Text("Pick at least one day.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }
        }
        // Every other row is an HStack with a Spacer, so it fills the card and its
        // label sits flush left. This one sizes to its content, and the enclosing
        // VStack's default centre alignment then put "On" in the middle of the card
        // while "Repeats" and "At" were against the edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
    }

    private func weekdayChip(_ index: Int) -> some View {
        let selected = draft.weekdayMask & (1 << index) != 0
        return Button {
            draft.weekdayMask ^= (1 << index)
        } label: {
            Text(RecurrenceRule.shortWeekdayNames[index].prefix(1))
                .font(.edCaption)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Tokens.paper : Tokens.inkSoft)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(selected ? Tokens.accentTasks : Tokens.paper2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RecurrenceRule.shortWeekdayNames[index])
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 0 = Sunday … 6 = Saturday, rotated so the device's first weekday leads.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { ($0 + first) % 7 }
    }

    private var dayOfMonthRow: some View {
        HStack {
            Text("On the")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            Picker("Day of month", selection: $draft.dayOfMonth) {
                ForEach(1...31, id: \.self) { day in
                    Text(RecurrenceRule.ordinal(day)).tag(day)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Tokens.accentTasks)
        }
        .padding(Space.md)
        .overlay(alignment: .bottomLeading) {
            if draft.dayOfMonth > 28 {
                Text("Short months use their last day.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, 2)
            }
        }
    }

    private var monthAndDayRow: some View {
        HStack {
            Text("On")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            Picker("Month", selection: $draft.monthOfYear) {
                ForEach(1...12, id: \.self) { month in
                    Text(RecurrenceRule.monthNames[month - 1]).tag(month)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Tokens.accentTasks)
            Picker("Day", selection: $draft.dayOfMonth) {
                ForEach(1...31, id: \.self) { day in
                    Text("\(day)").tag(day)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Tokens.accentTasks)
        }
        .padding(Space.md)
    }

    private var timeRow: some View {
        HStack {
            Text("At")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            DatePicker("", selection: $draft.timeOfDay, displayedComponents: [.hourAndMinute])
                .paperDatePickerOnMac()
                .labelsHidden()
                .tint(Tokens.accentTasks)
        }
        .padding(Space.md)
    }

    /// How far ahead the task appears. Spelled out rather than left as a number,
    /// because "3" on its own does not say what it does to the list.
    private var leadRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("Show me")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                Text(leadLabel)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Stepper(value: $draft.leadDays, in: 0...30) {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("The task appears in your list this far before it is due, so there is time to do it.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
    }

    private var leadLabel: String {
        switch draft.leadDays {
        case 0:  return "on the day"
        case 1:  return "1 day early"
        default: return "\(draft.leadDays) days early"
        }
    }

    private var startRow: some View {
        HStack {
            Text("Starting")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
            DatePicker("", selection: $draft.startDate, displayedComponents: [.date])
                .paperDatePickerOnMac()
                .labelsHidden()
                .tint(Tokens.accentTasks)
        }
        .padding(Space.md)
    }

    private var endRow: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Until a date")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                Toggle("", isOn: $draft.hasEndDate.animation())
                    .labelsHidden()
                    .tint(Tokens.accentTasks)
            }
            .padding(Space.md)

            if draft.hasEndDate {
                Divider().background(Tokens.divider)
                HStack {
                    DatePicker("", selection: $draft.endDate, in: draft.startDate..., displayedComponents: [.date])
                        .paperDatePickerOnMac()
                        .labelsHidden()
                        .tint(Tokens.accentTasks)
                    Spacer(minLength: 0)
                }
                .padding(Space.md)
            }
        }
    }

    /// What the rule actually means, as a sentence plus the first date it lands
    /// on. A rule is easy to describe wrongly and hard to check by reading the
    /// controls back, so the form says what it understood.
    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(draft.summary)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let first = draft.firstDate {
                Text("First one: \(first.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            } else {
                Text("This rule never comes around. Check the dates.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(Tokens.paper2)
    }
}
