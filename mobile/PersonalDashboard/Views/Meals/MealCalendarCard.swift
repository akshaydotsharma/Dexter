import SwiftUI

/// Fixed metrics for the History month grid (#559, rings in #679).
///
/// Held here rather than as literals in the view for the same reason every other
/// metrics table in this app exists: the ring, its stroke and the disc inside it
/// are read together, and a change to one that is not a change to the others is
/// the kind of drift nobody notices until a ring touches its numeral.
enum MealCalendarMetrics {
    /// Height of one day square. Just taller than the ring, so a row of closed
    /// rings reads as a row of separate days and not as a chain.
    static let cell: CGFloat = 40
    /// Outer diameter of the calorie ring. The popover leaves about 40 pt a
    /// column, so 36 pt is the largest ring that keeps a visible gap between
    /// neighbours without clipping at the column edge.
    static let ring: CGFloat = 36
    /// Stroke width of the ring and its track. Thick enough to read as the
    /// Fitness ring at this size, thin enough to leave the numeral a clear field.
    static let ringLine: CGFloat = 3.5
    /// Diameter of the today disc and the selected disc. The ring's inner
    /// diameter is `ring - 2 * ringLine` (29 pt), so a 25 pt disc leaves a 2 pt
    /// gap all round and the disc never merges into the arc.
    static let disc: CGFloat = 25
    /// Gap between squares. Small: the grid should read as a block of days, not
    /// as forty-two separate cards.
    static let gutter: CGFloat = Space.xs
    /// The grid stops widening past this. On a Mac detail pane a full-width
    /// calendar gives 150 pt squares holding a two-digit number.
    static let maxWidth: CGFloat = 460
}

/// The month grid in History (#559).
///
/// ### Why each day carries a ring (#679)
///
/// The first grid printed the counted calories under each numeral and drew a
/// grey bar scaled against the heaviest day in view, on the argument that hue on
/// this surface belongs to verdicts and nothing else. The user did not read it
/// that way: a column of four-digit figures is a table to be read, not a month
/// to be glanced at. #679 asked for the Apple Fitness reading instead, a ring
/// around each day that closes as the day approaches its target.
///
/// So the ring's fill is counted calories over the calorie target in force on
/// that day, and it is drawn in the section accent. That spends hue on quantity,
/// which the old doc comment ruled out, and it is a deliberate reversal: the
/// ring is one colour for every day, so it still makes no claim about a day
/// until the day goes over. An over day draws its arc in `danger`, because a
/// closed ring looks the same at 100% and at 180% and only colour can tell them
/// apart. Under and on-track stay in the accent; the arc's length already says
/// how far the day got, and the full verdict still arrives on the day card. A day
/// with no target in force falls back to the heaviest day in view, so a log kept
/// before targets existed still reads as a comparison.
///
/// ### Why an unlogged day is empty rather than zero
///
/// A blank day means the log was not kept. A low day means it was. That
/// difference is the entire value of keeping one, so a day with no meals gets no
/// ring and no track, and its numeral drops to `mutedSoft`. A logged day whose
/// counted total is genuinely zero still draws its faint track with no arc, so
/// the two states can never be confused.
///
/// ### Why today is a disc and nothing is a rectangle (#679)
///
/// Today used to carry a hairline rounded rectangle, which the user found both
/// hard to spot and out of place beside the rings. It is now a filled accent
/// disc inside its ring, the way the system calendar marks today. The selected
/// day, when it is not today, gets a quiet `surface2` disc, so selection and
/// today stay two different marks and neither is a box.
struct MealCalendarCard: View {

    /// The month on screen, device-local midnight of its first day.
    @Binding var month: Date
    /// The day the breakdown below is showing.
    @Binding var selectedDay: Date
    /// Every day that holds meals, keyed by stored day anchor.
    let readings: [Date: MealDayReading]
    /// Every calorie target record, sorted by `effectiveFrom` ascending, so each
    /// ring measures its day against the target that was in force THAT day
    /// (#679). Empty means every ring falls back to the heaviest day in view.
    var targets: [MealTargets] = []
    /// Injected so a test or a preview can pin "now". The view never reads the
    /// clock itself.
    var today: Date = Date()
    /// Called after a day in the grid is tapped, so the host can close itself.
    /// NOT called by the Today button (#679): Today is navigation, and the user
    /// asked for the popover to stay open on today rather than vanish the moment
    /// it got there.
    var onPickDay: (() -> Void)? = nil

    /// Which way the last month change moved, so the outgoing month slides off
    /// one side and the incoming one arrives from the other.
    @State private var slideEdge: Edge = .trailing

    private var calendar: Calendar { Calendar.current }

    /// Always six weeks, never five: a month that needs only five rows is padded
    /// with a blank one, so the popover keeps ONE height as the months are
    /// stepped through (#679). With whole-week padding alone, stepping between a
    /// five-row and a six-row month resized the popover mid-animation, which is
    /// what read as a flicker.
    private var slots: [MealCalendarSlot] {
        MealCalendar.fixedSlots(forMonthOf: month, calendar: calendar)
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

    /// Month leading, then Today, then the two chevrons trailing, the order the
    /// system pickers and `TaskCalendarPopover` use (#679). The title moved off
    /// centre so the three controls sit together under one thumb.
    private var header: some View {
        HStack(spacing: Space.xs) {
            ZStack(alignment: .leading) {
                Text(Self.monthFormatter.string(from: month))
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .id(month)
                    .transition(monthTransition)
            }
            .clipped()

            todayButton

            stepButton(
                icon: "chevron.left",
                label: "Previous month",
                enabled: true
            ) { step(-1) }

            stepButton(
                icon: "chevron.right",
                label: "Next month",
                enabled: canStepForward
            ) { step(1) }
        }
    }

    /// Whether the Today button has anything to do: it is dimmed only when
    /// today is already the selected day AND its month is already on screen.
    private var canJumpToToday: Bool {
        !calendar.isDate(selectedDay, inSameDayAs: today)
            || MealCalendar.monthStart(of: month, calendar: calendar)
                != MealCalendar.monthStart(of: today, calendar: calendar)
    }

    /// One tap back to today (#679). Kept visible when there is nothing to do,
    /// dimmed rather than removed, so the header does not change shape as the
    /// months are stepped through.
    private var todayButton: some View {
        Button(action: jumpToToday) {
            Text("Today")
                .font(.edCaption)
                .foregroundStyle(canJumpToToday ? Tokens.accentMeals : Tokens.mutedSoft)
                .padding(.horizontal, Space.sm)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(canJumpToToday ? Tokens.accentMeals.opacity(0.12) : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canJumpToToday)
        .accessibilityLabel("Go to today")
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
        // The whole month is one view keyed on `month`, so a step REPLACES the
        // grid with a sliding transition rather than re-filling the same 42
        // squares in place. Re-filling in place is what made every ring morph
        // from the old month's value to the new one while the numerals swapped
        // under it.
        return ZStack {
            LazyVGrid(columns: columns, spacing: MealCalendarMetrics.gutter) {
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
            .id(month)
            .transition(monthTransition)
        }
        .clipped()
    }

    /// The incoming month pushes the outgoing one off the opposite edge, the
    /// way the system calendar pages.
    private var monthTransition: AnyTransition {
        .push(from: slideEdge)
    }

    private static let monthAnimation: Animation = .smooth(duration: 0.3)

    // MARK: - One day

    private func cell(for day: Date) -> some View {
        let reading = MealCalendar.reading(for: day, in: readings)
        let selectable = MealCalendar.isSelectable(day, today: today, calendar: calendar)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let target = calorieTarget(on: day)
        let progress = MealCalendar.ringProgress(
            calories: reading.calories,
            target: target,
            heaviest: heaviest
        )
        let over = MealCalendar.isOver(calories: reading.calories, target: target)

        return Button {
            guard selectable else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = calendar.startOfDay(for: day)
            }
            onPickDay?()
        } label: {
            ZStack {
                if let progress {
                    MealDayRing(progress: progress, tint: over ? Tokens.danger : Tokens.accentMeals)
                }

                // Today's disc wins over the selection disc: today selected is
                // simply today, and a second mark on the same square would make
                // the two read as one.
                if isToday {
                    Circle()
                        .fill(Tokens.accentMeals)
                        .frame(width: MealCalendarMetrics.disc, height: MealCalendarMetrics.disc)
                } else if isSelected {
                    Circle()
                        .fill(Tokens.surface2)
                        .overlay(Circle().stroke(Tokens.borderStrong, lineWidth: 1))
                        .frame(width: MealCalendarMetrics.disc, height: MealCalendarMetrics.disc)
                }

                Text(Self.dayNumberFormatter.string(from: day))
                    .font(reading.isLogged || isToday ? .edFootnoteStrong : .edFootnote)
                    .foregroundStyle(numeralInk(selectable: selectable, logged: reading.isLogged, isToday: isToday))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: MealCalendarMetrics.cell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityLabel(accessibilityLabel(day: day, reading: reading, target: target, selectable: selectable))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The calorie target in force on a device-local day, or nil when no target
    /// record exists or it holds no usable figure.
    private func calorieTarget(on day: Date) -> Double? {
        guard let record = MealTargets.inForce(on: day, among: targets), record.calories > 0 else {
            return nil
        }
        return record.calories
    }

    private func numeralInk(selectable: Bool, logged: Bool, isToday: Bool) -> Color {
        if isToday { return Tokens.accentFg }
        guard selectable else { return Tokens.mutedSoft.opacity(0.5) }
        return logged ? Tokens.ink : Tokens.mutedSoft
    }

    private func accessibilityLabel(
        day: Date,
        reading: MealDayReading,
        target: Double?,
        selectable: Bool
    ) -> String {
        let date = Self.spokenDayFormatter.string(from: day)
        guard selectable else { return "\(date), not yet" }
        switch reading {
        case .unlogged:
            return "\(date), not logged"
        case .logged(let calories):
            guard let target else { return "\(date), \(MealFormat.calories(calories)) kcal" }
            // The ring's colour is the only sighted cue for an over day, so
            // VoiceOver hears it in words.
            let over = MealCalendar.isOver(calories: calories, target: target) ? ", over target" : ""
            return "\(date), \(MealFormat.calories(calories)) of \(MealFormat.calories(target)) kcal\(over)"
        }
    }

    // MARK: - Actions

    private func jumpToToday() {
        // Today is never earlier than the month on screen, so it arrives from
        // the trailing edge like a forward step.
        slideEdge = .trailing
        withAnimation(Self.monthAnimation) {
            month = MealCalendar.monthStart(of: today, calendar: calendar)
            selectedDay = calendar.startOfDay(for: today)
        }
    }

    private func step(_ months: Int) {
        slideEdge = months > 0 ? .trailing : .leading
        withAnimation(Self.monthAnimation) {
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

/// One day's calorie ring, Apple Fitness style (#679): a faint full-circle track
/// and a round-capped arc that starts at 12 o'clock and runs clockwise.
///
/// The stroke is drawn on a circle inset by half its width, so the ring's OUTER
/// edge is exactly `MealCalendarMetrics.ring` and never clips at the column edge.
/// A progress of 0 draws the track alone, which is how a logged day with nothing
/// counted stays distinct from an unlogged day, which draws no ring at all.
private struct MealDayRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        let line = MealCalendarMetrics.ringLine
        let inner = MealCalendarMetrics.ring - line
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: line)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: inner, height: inner)
        .accessibilityHidden(true)
    }
}
