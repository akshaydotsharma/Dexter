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

    /// Where the reel is, in pages, measured from `month` at the centre.
    ///
    /// ONE animated number drives the whole carousel: the horizontal offset, and
    /// every page's turn, scale and fade. That is what makes the slide read as a
    /// wheel rather than as a slide with two states. If the turn were bound to
    /// "is this the centre page" instead, it would be true or false with nothing
    /// in between, so a month would travel flat across the card and then snap
    /// side-on at the end of its journey.
    @State private var position: CGFloat = 0
    /// Held so a second tap during the animation cannot start a step from a
    /// half-turned reel, which would land the position between pages.
    @State private var isSliding = false
    /// The card's own width, measured. Seeded small so the first frame cannot
    /// force the card wider than a phone.
    @State private var cardWidth: CGFloat = 320

    private var calendar: Calendar { Calendar.current }

    /// Width of one month.
    ///
    /// Capped at the top, because a month that widens without limit is worse
    /// than a narrow one: seven flexible columns across a 2000pt window put
    /// 280pt between a numeral and its neighbour, and a calendar is read by
    /// proximity.
    ///
    /// Floored at the bottom by the card minus one peek, which is what makes
    /// this work on a phone. At a plain fraction of a 370pt card the centre
    /// month got 229pt and the neighbours took the rest, and their rows of pips
    /// ran straight into the centre month's — one continuous line of circles
    /// across the card, which is the exact opposite of what the pips are for.
    /// The wheel is a luxury of a wide window; on a narrow one the month you are
    /// on takes the room and the neighbours are a hint at the edge.
    private var pageWidth: CGFloat {
        let peeked = cardWidth - MealPlanMetrics.minimumPeek * 2
        let fractional = cardWidth * MealPlanMetrics.pageFraction
        return min(MealPlanMetrics.maxWidth, max(peeked, fractional, 200))
    }

    private var pageStep: CGFloat { pageWidth + MealPlanMetrics.pageGutter }

    /// Six rows always, so a 5-row month does not shorten the card and make the
    /// whole page jump as the reel passes over it.
    private var gridHeight: CGFloat {
        6 * MealPlanMetrics.monthCell + 5 * MealPlanMetrics.gutter
    }

    var body: some View {
        VStack(spacing: 0) {
            reel
                .frame(width: cardWidth, alignment: .center)
                .clipped()
                .mask(edgeFade)
                .padding(.vertical, Space.md)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    stepButton(icon: "chevron.left", label: "Previous month") { step(-1) }
                        .padding(.leading, Space.sm)
                }
                .overlay(alignment: .trailing) {
                    stepButton(icon: "chevron.right", label: "Next month") { step(1) }
                        .padding(.trailing, Space.sm)
                }

            todayRow
        }
        .frame(maxWidth: .infinity)
        .background(widthReader)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Today

    /// "Today" as a named destination, not as a date to hunt for (#605).
    ///
    /// The reel steps forward without limit, which is the whole proposition of a
    /// plan calendar and also the thing that makes getting back expensive: three
    /// taps out and the current month is somewhere behind you with nothing
    /// pointing at it. Every other day control in this app already carries this
    /// shortcut — see `EdDayPickerCalendar.footer` — so the Plan calendar was
    /// the one place a user had to page home by hand.
    ///
    /// It does TWO things, and both are needed. Selecting today without moving
    /// the reel would leave the selection on a month that is not on screen, and
    /// moving the reel without selecting would land you on the right month with
    /// the wrong day still driving the tiles below.
    ///
    /// It is DISABLED when the calendar is already on today rather than removed,
    /// so it can never be a control that does nothing and the card can never
    /// change height under the tiles below it. Taking the row away moved the
    /// whole day's plan up the screen every time today was selected, which is a
    /// bigger interruption than a faded word in a corner.
    private var todayRow: some View {
        HStack(spacing: Space.sm) {
            Spacer(minLength: 0)
            Button("Today", action: goToToday)
                .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                .disabled(isOnToday)
                .opacity(isOnToday ? 0.35 : 1)
                .accessibilityHint("Selects today and returns the calendar to this month")
        }
        .padding(.horizontal, Space.sm)
        .padding(.bottom, Space.sm)
    }

    /// True when both halves of "today" already hold: the day is selected AND
    /// the month it lives in is the one on screen. Either one being false is a
    /// reason to offer the control.
    private var isOnToday: Bool {
        calendar.isDate(selectedDay, inSameDayAs: today)
            && calendar.isDate(month, equalTo: today, toGranularity: .month)
    }

    private func goToToday() {
        guard !isSliding else { return }
        let start = calendar.startOfDay(for: today)
        withAnimation(.easeOut(duration: 0.18)) {
            selectedDay = start
            month = MealPlanCalendar.monthStart(of: start, calendar: calendar)
            position = 0
        }
    }

    // MARK: - The reel

    private var reel: some View {
        HStack(spacing: MealPlanMetrics.pageGutter) {
            ForEach(Self.pageOffsets, id: \.self) { offset in
                page(
                    for: MealPlanCalendar.stepMonth(month, by: offset, calendar: calendar),
                    at: CGFloat(offset) - position
                )
            }
        }
        // The HStack puts page n at n page-steps; moving the whole reel back by
        // the position lands page n at (n - position) steps, which is exactly
        // the `distance` each page is drawn from.
        .offset(x: -position * pageStep)
    }

    /// One month, turned by how far it is from the centre.
    ///
    /// `distance` is in pages: 0 is the month you are on, -1 is the one to the
    /// left, and a step walks it smoothly between the two.
    private func page(for pageMonth: Date, at distance: CGFloat) -> some View {
        // Past one page the treatment stops deepening. A month two steps out is
        // off the card anyway, and letting it keep turning would fold it into a
        // line during the slide.
        let reach = min(abs(distance), 1)
        let isCentred = reach < 0.02

        return VStack(spacing: Space.sm) {
            Text(Self.monthFormatter.string(from: pageMonth))
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .accessibilityAddTraits(.isHeader)

            weekdayRow
            grid(for: pageMonth, isCentred: isCentred)
        }
        .frame(width: pageWidth)
        .opacity(1 - reach * (1 - MealPlanMetrics.neighbourOpacity))
        .scaleEffect(1 - reach * (1 - MealPlanMetrics.neighbourScale), anchor: .center)
        // The turn. A neighbour faces INWARD, hinged on the edge nearest the
        // centre, so the wheel curves away from the reader on both sides rather
        // than flat months being pushed sideways. The anchor flips as a page
        // crosses the centre, which cannot be seen: the angle is zero there.
        .rotation3DEffect(
            .degrees(Double(clamped(distance)) * MealPlanMetrics.neighbourTilt),
            axis: (x: 0, y: 1, z: 0),
            anchor: distance > 0 ? .leading : .trailing,
            perspective: MealPlanMetrics.reelPerspective
        )
        // Only the centred month is a control. A turned month is foreshortened
        // and half clipped, and a square you can only half see is not one you
        // should be able to book a dinner on.
        .allowsHitTesting(isCentred)
        .accessibilityHidden(!isCentred)
    }

    private func clamped(_ distance: CGFloat) -> CGFloat {
        max(-1, min(1, distance))
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

    private func grid(for pageMonth: Date, isCentred: Bool) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MealPlanMetrics.gutter),
            count: 7
        )
        return LazyVGrid(columns: columns, spacing: MealPlanMetrics.gutter) {
            ForEach(MealPlanCalendar.monthSlots(forMonthOf: pageMonth, calendar: calendar)) { slot in
                if let day = slot.day {
                    cell(for: day, isCentred: isCentred)
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

    private func cell(for day: Date, isCentred: Bool) -> some View {
        let reading = MealPlanDay.reading(for: day, in: readings)
        // Only the centred month can hold the selection. Without this the same
        // day would draw selected twice as it passed through the reel.
        let isSelected = isCentred && calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDate(day, inSameDayAs: today)

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = calendar.startOfDay(for: day)
            }
        } label: {
            VStack(spacing: 2) {
                numeralDisc(for: day, reading: reading, isSelected: isSelected, isToday: isToday)
                Spacer(minLength: 0)
                MealPlanDayPips(reading: reading)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .frame(height: MealPlanMetrics.monthCell)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(Self.spokenDayFormatter.string(from: day)), \(MealPlanDayPips.spokenSummary(reading))"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The day's numeral, in the disc every Dexter calendar draws it in (#605).
    ///
    /// A filled circle in the section accent for the day you are on, a ring for
    /// today, nothing otherwise — the grammar `EdDayPickerCalendar`,
    /// `TripCalendarPopover` and `TaskCalendarPopover` already share. This grid
    /// used to draw both states as bordered ROUNDED RECTANGLES over the whole
    /// square, which made it the only calendar in the app where a day was not a
    /// circle, and which left the selected day and today separated by a stroke
    /// weight rather than by a shape.
    ///
    /// Selected and today are drawn as one OR the other, never both. Today
    /// while selected is already the loudest thing on the grid; a ring around a
    /// filled disc would add a second mark to say something the fill has said.
    private func numeralDisc(
        for day: Date,
        reading: MealPlanReading,
        isSelected: Bool,
        isToday: Bool
    ) -> some View {
        ZStack {
            if isSelected {
                Circle().fill(Tokens.accent(for: .meals))
            } else if isToday {
                Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1)
            }
            Text(Self.dayNumberFormatter.string(from: day))
                .font(reading.isEmpty && !isSelected ? .edFootnote : .edFootnoteStrong)
                .foregroundStyle(numeralInk(reading: reading, isSelected: isSelected))
                .monospacedDigit()
        }
        .frame(width: MealPlanMetrics.dayDisc, height: MealPlanMetrics.dayDisc)
    }

    /// A day with blocks on it is drawn in ink and one without in `mutedSoft`,
    /// which is the reading that survives the disc: the fill says where you are,
    /// the weight says where the plan is.
    private func numeralInk(reading: MealPlanReading, isSelected: Bool) -> Color {
        if isSelected { return Tokens.accentFg }
        return reading.isEmpty ? Tokens.mutedSoft : Tokens.ink
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
            position = months > 0 ? 1 : -1
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                month = MealPlanCalendar.stepMonth(month, by: months, calendar: calendar)
                position = 0
            }
            isSliding = false
        }
    }

    /// The months the reel holds, as offsets from the centre.
    private static let pageOffsets: [Int] = [-1, 0, 1]

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
