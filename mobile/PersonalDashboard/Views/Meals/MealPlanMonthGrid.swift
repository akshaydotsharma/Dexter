import SwiftUI

/// The month carousel, as the Plan tab's month scope (#599).
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
/// ### Why three months and not one
///
/// The card spans the whole row, and one 460pt month inside it left most of that
/// row empty. The neighbours fill it with the only thing that belongs there:
/// where the step buttons are about to take you. A plan is written across a
/// month boundary more often than not — this week's shopping, next week's trip —
/// so the month you are not on is rarely irrelevant.
///
/// They are decoration, not controls. A faded month is clipped by the card edge,
/// so some of its days are half-drawn or missing entirely, and a square you can
/// only half see is not a square you should be able to book a dinner on. Both
/// neighbours are hit-testing off and hidden from the accessibility tree, which
/// also keeps a reader from walking 90 more days it cannot act on.
///
/// ### The slide
///
/// A step animates the reel by exactly one page, and then swaps the month and
/// resets the offset in the same non-animated transaction. The arrangement
/// either side of that swap is identical — the month that was centred is now the
/// left neighbour in both readings — so the jump is invisible, and the reel can
/// run forever in either direction without ever holding more than three months.
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

    /// How far the reel is dragged from its resting place. Non-zero only during
    /// a step.
    @State private var slide: CGFloat = 0
    /// Held so a second tap during the animation cannot start a step from a
    /// half-slid reel, which would land the offset somewhere between pages.
    @State private var isSliding = false
    /// The card's own width, measured. Seeded small so the first frame cannot
    /// force the card wider than a phone.
    @State private var cardWidth: CGFloat = 320

    private var calendar: Calendar { Calendar.current }

    /// Width of one month. Capped, because a month that widens without limit is
    /// worse than a narrow one: seven flexible columns across a 2000pt window
    /// put 280pt between a numeral and its neighbour, and a calendar is read by
    /// proximity.
    private var pageWidth: CGFloat {
        min(MealPlanMetrics.maxWidth, max(cardWidth * MealPlanMetrics.pageFraction, 200))
    }

    private var pageStep: CGFloat { pageWidth + MealPlanMetrics.pageGutter }

    /// Six rows always, so a 5-row month does not shorten the card and make the
    /// whole page jump as the reel passes over it.
    private var gridHeight: CGFloat {
        6 * MealPlanMetrics.monthCell + 5 * MealPlanMetrics.gutter
    }

    var body: some View {
        reel
            .frame(width: cardWidth, alignment: .center)
            .clipped()
            .mask(edgeFade)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity)
            .background(widthReader)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
            .overlay(alignment: .leading) {
                stepButton(icon: "chevron.left", label: "Previous month") { step(-1) }
                    .padding(.leading, Space.sm)
            }
            .overlay(alignment: .trailing) {
                stepButton(icon: "chevron.right", label: "Next month") { step(1) }
                    .padding(.trailing, Space.sm)
            }
    }

    // MARK: - The reel

    private var reel: some View {
        HStack(spacing: MealPlanMetrics.pageGutter) {
            page(for: MealPlanCalendar.stepMonth(month, by: -1, calendar: calendar), isCurrent: false)
            page(for: month, isCurrent: true)
            page(for: MealPlanCalendar.stepMonth(month, by: 1, calendar: calendar), isCurrent: false)
        }
        .offset(x: slide)
    }

    private func page(for pageMonth: Date, isCurrent: Bool) -> some View {
        VStack(spacing: Space.sm) {
            Text(Self.monthFormatter.string(from: pageMonth))
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .accessibilityAddTraits(.isHeader)

            weekdayRow
            grid(for: pageMonth, isCurrent: isCurrent)
        }
        .frame(width: pageWidth)
        .opacity(isCurrent ? 1 : MealPlanMetrics.neighbourOpacity)
        // A neighbour sits slightly back, which is the second half of saying
        // "not this one". Opacity alone left the three months reading as one
        // continuous grid of numerals at narrow widths, because every column
        // was the same size and the same distance apart.
        .scaleEffect(isCurrent ? 1 : MealPlanMetrics.neighbourScale, anchor: .center)
        .allowsHitTesting(isCurrent)
        .accessibilityHidden(!isCurrent)
    }

    /// The card's edges dissolve rather than cut.
    ///
    /// A neighbouring month is clipped mid-week, and a hard edge makes that
    /// clip read as the end of the calendar — a column of numerals that stops
    /// against a wall looks like data that is missing rather than a month that
    /// continues. Fading it out says the reel goes on, which is the whole
    /// proposition of the control.
    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.10),
                .init(color: .black, location: 0.90),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Measures the card without taking part in sizing it. The card's width
    /// comes from the row it sits in, so reading it here cannot feed back into
    /// it.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { cardWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in cardWidth = new }
        }
    }

    // MARK: - Chrome

    /// A step control, on its own ground.
    ///
    /// It sits over a faded month rather than beside the title, so it carries a
    /// filled circle: a bare chevron on top of a half-visible grid of numerals
    /// reads as one more numeral.
    private func stepButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.inkSoft)
                .frame(width: 30, height: 30)
                .background(Tokens.surface2, in: Circle())
                .overlay(Circle().stroke(Tokens.border, lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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

    private func grid(for pageMonth: Date, isCurrent: Bool) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MealPlanMetrics.gutter),
            count: 7
        )
        return LazyVGrid(columns: columns, spacing: MealPlanMetrics.gutter) {
            ForEach(MealPlanCalendar.monthSlots(forMonthOf: pageMonth, calendar: calendar)) { slot in
                if let day = slot.day {
                    cell(for: day, isCurrent: isCurrent)
                } else {
                    Color.clear
                        .frame(height: MealPlanMetrics.monthCell)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: gridHeight, alignment: .top)
    }

    // MARK: - One day

    private func cell(for day: Date, isCurrent: Bool) -> some View {
        let reading = MealPlanDay.reading(for: day, in: readings)
        // Only the centred month can hold the selection. Without this the same
        // day would draw selected twice as it passed through the reel.
        let isSelected = isCurrent && calendar.isDate(day, inSameDayAs: selectedDay)
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

    /// Slide one page, then swap the month under cover of the finished slide.
    ///
    /// The two halves have to be one gesture to the eye: animate the offset,
    /// and once it has landed, move the month and zero the offset in a
    /// transaction with animation switched OFF. Animating that second half
    /// would slide the reel back the way it came.
    private func step(_ months: Int) {
        guard !isSliding else { return }
        isSliding = true

        withAnimation(.easeInOut(duration: MealPlanMetrics.slideDuration)) {
            slide = months > 0 ? -pageStep : pageStep
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                month = MealPlanCalendar.stepMonth(month, by: months, calendar: calendar)
                slide = 0
            }
            isSliding = false
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
