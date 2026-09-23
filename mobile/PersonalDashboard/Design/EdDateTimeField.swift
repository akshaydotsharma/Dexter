import SwiftUI

/// Dexter's date-and-time field: a switch that opens a calendar in place (#657).
///
/// ### What it replaces
///
/// Setting a date used to cost two taps and hand the screen to a different app.
/// A toggle revealed Apple's compact `DatePicker`, and tapping that pill opened
/// Apple's own popover calendar over the sheet: system blue, system radii,
/// system type, floating above a column of Dexter fields. Half the surfaces did
/// not even have the toggle, so a date was a bare pill with no way to read what
/// it was for until you opened it.
///
/// ### The grammar it follows instead
///
/// Reminders already taught the phone this shape, and it is the right one: a
/// row that names the field and carries a switch, and a panel that opens
/// underneath the row rather than over it. Nothing is covered, the sheet you
/// were reading stays where it was, and the chosen value sits under the label
/// the whole time.
///
/// ### Two rows, one panel
///
/// A Date row and a Time row, each with its own switch, and exactly one panel
/// open between them. Switching Date on opens the calendar; switching Time on
/// shuts the calendar and opens the clock; pressing the Date row again shuts
/// the clock and brings the calendar back. That is the Reminders accordion,
/// and it is what keeps a card with a date, a time and a reminder in it
/// shorter than a phone.
///
/// The time was briefly a strip inside the calendar. It saved a row and cost
/// the thing the row was for: with the panel shut you could no longer switch a
/// time off, or see that there was one to switch, without opening the day.
///
/// A field that is a time and NOTHING else — an arrival, a repeat rule's hour —
/// has no date row above it, so its Time row is the whole field.
///
/// ### One calendar in the app
///
/// The panel is `EdDayPickerCalendar` with `drawsCard: false`, which is the
/// same calendar the Meals plan and the day field already draw. A third
/// calendar design does not enter the app.
///
/// ### The clock is still Apple's
///
/// Dexter has no time control of its own, and Reminders shows the system clock
/// too. It is drawn inside our panel, in the section's accent. Building
/// `EdTimePicker` is its own design job and its own ticket.
struct EdDateTimeField: View {

    /// The day, and the time when `hasTime` is on. One `Date` rather than two,
    /// because every caller stores one.
    @Binding var date: Date

    /// Whether the field carries a date at all.
    ///
    /// Nil for a date that cannot be absent — an expense happened on a day, a
    /// trip starts on one. The switch is then drawn on and does not move, and
    /// the row opens the calendar instead. Mandatory and optional dates read
    /// identically, which is the point: a user should not have to work out
    /// which kind of field they are looking at before they can use it.
    var hasDate: Binding<Bool>? = nil

    /// Whether the field carries a time. Nil for a time that cannot be absent,
    /// exactly as `hasDate`.
    var hasTime: Binding<Bool>? = nil

    /// False for a field that is a time and nothing else — an arrival, which
    /// takes its day from the item it belongs to.
    var showsDate: Bool = true
    /// False for a field that is a day and nothing else — a trip's start, a
    /// recurring expense's last posting.
    var showsTime: Bool = true

    var dateLabel: String = "Date"
    var timeLabel: String = "Time"
    var dateIcon: String = "calendar"
    var timeIcon: String = "clock"

    var tint: Color = Tokens.accentTasks

    /// The days that may be chosen. See `ClosedRange.upTo` / `.from` for the
    /// one-sided cases, which is what most callers have.
    var bounds: ClosedRange<Date>? = nil

    /// Whether the calendar fills its row with the months either side of the
    /// one it is on.
    ///
    /// Off by default, and measured rather than assumed. `#621` built the reel
    /// for a calendar given a WIDE row, and a field inside an editor card is
    /// not one: a phone card is about 358pt, the centre month takes 268 of it,
    /// and the 45pt left over on each side shows four faded numerals off the
    /// neighbouring months. That does not read as August and October, it reads
    /// as a column of stray digits down each edge. A centred month with a
    /// margin is the cleaner of the two, so the reel stays for the Plan tab,
    /// which has a real row to fill.
    var showsNeighbourMonths: Bool = false

    /// False when the caller already has a card to put this in, which the Mac
    /// editor groups do. A card drawn inside a card is two borders and a seam.
    var drawsCard: Bool = true

    /// Shared open state, for a card that holds more than one of these.
    ///
    /// A trip has a Start and an End in one card. Left to themselves the two
    /// fields each keep their own panel, so both calendars open at once and the
    /// card grows to about 600pt of month. Handing both fields the same binding
    /// makes them one accordion: opening a panel anywhere in the card shuts
    /// whichever panel was open.
    ///
    /// Nil for a card holding one field, which is nearly all of them.
    var openPanel: Binding<String?>? = nil

    /// Which panel is open. One at a time: two open panels make a sheet taller
    /// than a phone, and the second one is always below the fold anyway.
    @State private var localOpen: String? = nil

    private var open: Binding<String?> { openPanel ?? $localOpen }

    /// Panels are keyed by label rather than by case, because the key has to be
    /// unique across every field sharing one accordion, not just within one.
    private var dateKey: String { "\(dateLabel)|date" }
    private var timeKey: String { "\(timeLabel)|time" }

    private var calendar: Calendar { Calendar.current }

    private var dateIsOn: Bool { hasDate?.wrappedValue ?? true }
    private var timeIsOn: Bool { hasTime?.wrappedValue ?? true }

    var body: some View {
        VStack(spacing: 0) {
            if showsDate {
                row(
                    icon: dateIcon,
                    label: dateLabel,
                    value: Self.dayFormatter.string(from: date),
                    isOn: dateIsOn,
                    binding: hasDate,
                    panel: dateKey
                )
                if dateIsOn && open.wrappedValue == dateKey {
                    Divider().background(Tokens.divider)
                    EdDayPickerCalendar(
                        day: dayBinding,
                        tint: tint,
                        bounds: bounds,
                        drawsCard: false,
                        showsNeighbourMonths: showsNeighbourMonths,
                        fillsWidth: true
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            // Time hangs off the date. A field with no date on it has no moment
            // for a time to name, so the row is not offered rather than offered
            // and refused.
            if showsTime && (!showsDate || dateIsOn) {
                if showsDate {
                    Divider().background(Tokens.divider)
                }
                row(
                    icon: timeIcon,
                    label: timeLabel,
                    value: timeText,
                    isOn: timeIsOn,
                    binding: hasTime,
                    panel: timeKey
                )
                if timeIsOn && open.wrappedValue == timeKey {
                    Divider().background(Tokens.divider)
                    timeWheel
                }
            }
        }
        .background(cardBackground)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if drawsCard {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Tokens.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .stroke(Tokens.border, lineWidth: 0.5)
                )
        } else {
            Color.clear
        }
    }

    // MARK: - One row

    /// The label half of a row is a `Button`, and the switch is its sibling.
    ///
    /// They cannot be one control. A `Toggle` inside a `Button` label never
    /// sees the tap, and a row that was only a `Toggle` would leave a mandatory
    /// date with nothing to press. So the row opens the panel and the switch
    /// turns the field on, which is also how Reminders splits it.
    @ViewBuilder
    private func row(
        icon: String,
        label: String,
        value: String,
        isOn: Bool,
        binding: Binding<Bool>?,
        panel: String
    ) -> some View {
        if let binding {
            HStack(spacing: Space.md) {
                rowButton(icon: icon, label: label, value: value, isOn: isOn, panel: panel)
                edSwitch(binding, label: label, panel: panel)
            }
            .padding(Space.md)
        } else {
            // Mandatory. The switch is drawn on and takes no taps, so pressing
            // it opens the panel like the rest of the row rather than doing
            // nothing at all.
            rowButton(
                icon: icon,
                label: label,
                value: value,
                isOn: true,
                panel: panel,
                trailing: AnyView(fixedOnSwitch)
            )
            .padding(Space.md)
        }
    }

    private func rowButton(
        icon: String,
        label: String,
        value: String,
        isOn: Bool,
        panel: String,
        trailing: AnyView? = nil
    ) -> some View {
        Button {
            guard isOn else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                open.wrappedValue = (open.wrappedValue == panel) ? nil : panel
            }
        } label: {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Tokens.mutedSoft)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    // The chosen value lives under the label, where it is
                    // readable with the panel shut. A field you have to open to
                    // find out what it says is a field you open every time.
                    if isOn {
                        Text(value)
                            .font(.edCaption)
                            .foregroundStyle(tint)
                    }
                }
                Spacer(minLength: Space.sm)
                if isOn {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.mutedSoft)
                        .rotationEffect(.degrees(open.wrappedValue == panel ? 180 : 0))
                }
                if let trailing {
                    trailing
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? value : "Off")
        .accessibilityHint(isOn ? "Opens a picker" : "")
    }

    // MARK: - Switches

    /// A switch on both platforms.
    ///
    /// macOS draws a bare `Toggle` as a CHECKBOX, so the same field read as a
    /// switch on the phone and a tick box on the Mac. `.switch` is the same
    /// object in both places, which is what a shared control has to be.
    private func edSwitch(_ binding: Binding<Bool>, label: String, panel: String) -> some View {
        Toggle("", isOn: opening(binding, panel: panel))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(tint)
            .accessibilityLabel(label)
    }

    /// The switch's value, and the panel that goes with it.
    ///
    /// Deliberately a proxy binding rather than `.onChange(of:)` (#657). The
    /// two look equivalent and are not: `onChange` cannot tell a person moving
    /// the switch from the editor SEEDING it, so opening a task that already
    /// had a date and a time threw both panels open before the person had
    /// asked for anything. Every load is a change.
    ///
    /// A setter only runs when something is set, so a seeded value passes
    /// through it untouched and the field opens shut.
    private func opening(_ source: Binding<Bool>, panel: String) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { isOn in
                withAnimation(.easeInOut(duration: 0.2)) {
                    source.wrappedValue = isOn
                    if isOn {
                        // Switching a value on is a request to choose one, so
                        // its panel opens — and, being one panel between them,
                        // shuts whichever was open.
                        open.wrappedValue = panel
                    } else if open.wrappedValue == panel
                                || (panel == dateKey && open.wrappedValue == timeKey) {
                        // Switching the DATE off takes the time row with it, so
                        // it has to close the clock as well as the calendar.
                        // Only ever this field's own keys: with a shared
                        // accordion, a sibling's open panel is none of our
                        // business.
                        open.wrappedValue = nil
                    }
                }
            }
        )
    }

    /// The switch on a value that cannot be absent. Drawn on, takes no taps, so
    /// the press falls through to the row that opens the panel.
    private var fixedOnSwitch: some View {
        Toggle("", isOn: .constant(true))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(tint)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - The clock

    /// The wheel Reminders shows, drawn inside our panel in the section accent.
    @ViewBuilder
    private var timeWheel: some View {
        #if os(iOS)
        DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.wheel)
            .tint(tint)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(timeLabel)
        #else
        HStack {
            DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .paperDatePickerOnMac()
                .tint(tint)
                .accessibilityLabel(timeLabel)
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        #endif
    }

    // MARK: - What the rows say

    private var timeText: String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Bindings

    /// The day the calendar writes back, with the time already on the field
    /// kept (#657).
    ///
    /// `EdDayPickerCalendar` hands back a device-local midnight, because a day
    /// picker's whole answer is a day. Writing that straight into a field that
    /// also carries a time silently resets the time to 00:00 every time a day
    /// is tapped, which on a task due date would move the reminder to midnight.
    private var dayBinding: Binding<Date> {
        Binding(
            get: { date },
            set: { newDay in
                let time = calendar.dateComponents([.hour, .minute], from: date)
                date = calendar.date(
                    bySettingHour: time.hour ?? 0,
                    minute: time.minute ?? 0,
                    second: 0,
                    of: newDay
                ) ?? newDay
            }
        )
    }

    // MARK: - Formatters

    /// The same face the day field has always shown: a plan is written in
    /// weekdays, and a row of digits makes the reader convert it every time.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()
}

// MARK: - One-sided bounds

/// Most callers have half a range: an expense cannot be in the future, a
/// check-out cannot precede a check-in. `EdDayPickerCalendar` takes a closed
/// range, so these name the open end rather than making every call site spell
/// out `Date.distantPast`.
extension ClosedRange where Bound == Date {
    /// Any day up to and including `date`.
    static func upTo(_ date: Date) -> ClosedRange<Date> {
        Date.distantPast...date
    }

    /// Any day from `date` onwards.
    static func from(_ date: Date) -> ClosedRange<Date> {
        date...Date.distantFuture
    }
}
