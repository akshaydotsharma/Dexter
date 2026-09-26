import SwiftUI

/// Dexter's compact day chip, for a day chosen inside a flowing row (#599,
/// #669).
///
/// ### Why not `DatePicker`
///
/// `DatePicker(.compact)` draws Apple's control, not ours: system blue, system
/// corner radii, system type, and a popover with its own chrome. Every other
/// field around it is a Dexter field, so the day was the odd one out.
///
/// ### Why it no longer opens a popover
///
/// It used to, and since #657 every other section sets a date with a calendar
/// that opens UNDER its row (`EdDateTimeField`). #669 brought Meals into line.
/// A column of fields takes `EdDateTimeField` itself; this chip is for the one
/// place that cannot, a flowing row of controls (the plan chat's suggestion
/// footer), where a full-width row would push its neighbours onto lines of
/// their own.
///
/// So the chip only reports and toggles `isOpen`. The CALLER draws
/// `EdDayPickerCalendar(drawsCard: false, fillsWidth: true)` under the row the
/// chip sits in. That is the same panel, in the same place relative to its
/// row, as the inline field; a flow layout simply cannot hold it as a child.
///
/// ### One field, one value
///
/// The chip shows the day in full ("Thu 17 Sep 2026") rather than as digits.
/// A plan is written in weekdays — "Thursday's dinner" — and a row of digits
/// makes the reader do the conversion every time.
struct EdDayPicker: View {
    @Binding var day: Date
    /// Whether the caller's calendar panel is open under the row.
    @Binding var isOpen: Bool

    /// What the field is for, spoken and shown above it by the caller.
    var accessibilityName: String = "Day"
    /// The hue of the calendar glyph. Defaults to the Meals accent because
    /// that is where this began; every caller passes its own section's.
    var tint: Color = Tokens.accent(for: .meals)
    /// True in a column of fields, where the chip matches the width of the
    /// ones above and below it. False in a flowing row, where a field that took
    /// the whole width would push its neighbours onto their own lines.
    var fillsWidth: Bool = true

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(Self.fieldFormatter.string(from: day))
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Spacer(minLength: Space.sm)
                // The same chevron as `EdDateTimeField`'s row, turning the
                // same way, so the chip reads as "opens underneath".
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
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
        .accessibilityHint(isOpen ? "Closes the calendar" : "Opens a calendar")
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

/// Dexter's one calendar, in the Dexter card grammar.
///
/// Drawn in place by `EdDateTimeField` and under `EdDayPicker`'s row, and in
/// a full-width surface by the Plan tab. Held as its own type so any caller
/// with a surface to put a calendar on can use it.
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

    /// Days that carry something, as device-local midnights (#605).
    ///
    /// Drawn by the WEIGHT of the numeral, never by an extra mark. The Plan tab
    /// needs to say which days have meals on them, and it used to say it with
    /// four coloured pips under the numeral — which is what forced that
    /// calendar's cells out of this one's geometry and made it the odd calendar
    /// in the app. Ink instead of `inkSoft` costs no space at all, so the cell
    /// stays 32pt and a circle stays a circle.
    ///
    /// Empty for every caller that has nothing to mark, which is all of them
    /// but the plan.
    var markedDays: Set<Date> = []

    /// True when this draws its own surface, border and popover chrome, which
    /// is what a POPOVER needs: it floats over the content and has to be a card
    /// in its own right (#613).
    ///
    /// False when a caller is putting it INSIDE a card of its own. The Plan tab
    /// does: its calendar sits in a full-width surface like the meal tiles under
    /// it, and a 300pt card drawn on top of that would be a card on a card —
    /// two borders and a seam where the two greys meet.
    ///
    /// Only the chrome is dropped. The 300pt content width stays either way, so
    /// the digits, the circles and the spacing are the same object in both
    /// modes.
    var drawsCard: Bool = true

    /// What a marked day says when it is read aloud, beyond its date.
    ///
    /// A closure rather than one string, because the interesting half of a
    /// marked day is what is ON it ("2 planned, no lunch or dinner"), and that
    /// differs per day. Returning nil, which is the default, leaves the spoken
    /// label as the date alone.
    var spokenDetail: (Date) -> String? = { _ in nil }

    /// True when the calendar is given a whole row and should fill it with the
    /// months either side of the one it is on (#621).
    ///
    /// The card is 300pt and a row is as wide as the window, so something is
    /// left over on every surface that is not a popover: 46pt down each side of
    /// a phone, far more on a Mac detail pane. Centring the grid made that space
    /// deliberate rather than accidental, which is where #611 left it, but it is
    /// still space doing nothing.
    ///
    /// With this on, the space holds the previous and next months, turned away
    /// and faded, with the step controls sitting on them. The centre month is
    /// the SAME grid at the SAME 268pt — see `EdMonthReel` for why that matters
    /// and why a neighbour is scenery rather than a control.
    ///
    /// False everywhere the calendar floats: a popover is exactly as wide as the
    /// card, so there is no space to fill and nothing to fill it with.
    var showsNeighbourMonths: Bool = false

    /// Whether the month spreads to the width it is given (#657).
    ///
    /// Off by default, which is what a POPOVER needs: it floats, so it has to
    /// decide its own width, and 300pt is the width every Dexter calendar has
    /// been drawn at since #230.
    ///
    /// On inside an editor card, where the container has already decided the
    /// width and a 300pt month leaves a margin down each side doing nothing.
    /// Only the SPACING between cells grows — a `Circle` inscribes itself in
    /// the smaller of its two dimensions, so a day stays a 32pt disc however
    /// wide its column gets. Capped, because past about 460pt the discs are so
    /// far apart that a week stops reading as a row.
    var fillsWidth: Bool = false

    @State private var month: Date = Date()
    @State private var seeded = false

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    var body: some View {
        let content = Group {
            if showsNeighbourMonths { reelBody } else { plainBody }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            month = MealCalendar.monthStart(of: day, calendar: calendar)
        }

        if drawsCard {
            content
                .background(
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .fill(Tokens.surface)
                )
                .paperBorder(Tokens.border, radius: Radius.lg)
                .presentationBackground(Tokens.surface)
                .presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }

    // MARK: - The two shapes it takes

    /// One month, at the fixed card width.
    ///
    /// The cells are flexible columns, so a calendar that took its container's
    /// width would spread its circles across a Mac window and stop reading as a
    /// month. 268pt of grid inside 16pt of padding is the width every Dexter
    /// calendar is drawn at, and it does not move — not here, and not in the
    /// reel, which repeats this exact page.
    private var plainBody: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            monthGrid(for: month, isInteractive: true)
            footer
        }
        .padding(Space.lg)
        .frame(
            width: fillsWidth ? nil : EdDayPickerMetrics.cardWidth,
            alignment: .leading
        )
        .frame(maxWidth: fillsWidth ? EdDayPickerMetrics.filledMaxWidth : nil)
    }

    /// The same month, with its neighbours either side of it.
    ///
    /// The month's name moves out of the header and onto each page, because a
    /// title over three months can only name one of them, and "which month is
    /// that one" is the first thing a reader asks of a neighbour. The step
    /// chevrons move with it, onto the neighbours themselves, which is where
    /// `EdMonthReel` draws them.
    ///
    /// The reel runs edge to edge — no horizontal padding — so a neighbour can
    /// reach the card's border and dissolve into it. The footer keeps the centre
    /// page's width so Today and Tomorrow stay under the month they act on
    /// rather than drifting out to the card's corner.
    private var reelBody: some View {
        VStack(spacing: Space.md) {
            EdMonthReel(month: $month) { pageMonth, isCentred in
                VStack(spacing: Space.md) {
                    Text(Self.monthFormatter.string(from: pageMonth))
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .accessibilityAddTraits(.isHeader)
                    monthGrid(for: pageMonth, isInteractive: isCentred)
                }
            }
            footer
                .frame(width: EdDayPickerMetrics.pageWidth)
        }
        .padding(.vertical, Space.lg)
        .frame(maxWidth: .infinity)
    }

    /// One month's squares, wherever they are drawn.
    ///
    /// The single place a month grid is described, so the popover's month and
    /// the five the reel turns cannot drift apart into two calendars again.
    private func monthGrid(for pageMonth: Date, isInteractive: Bool) -> some View {
        EdDayPickerMonthGrid(
            month: pageMonth,
            selection: day,
            tint: tint,
            bounds: bounds,
            markedDays: markedDays,
            spokenDetail: spokenDetail,
            isInteractive: isInteractive,
            // Six rows in the reel only. A popover holding one month may be as
            // short as that month is; a reel may not, or the card changes height
            // as a five-row month reaches the middle.
            fixedRows: showsNeighbourMonths ? EdDayPickerMetrics.reelRows : nil,
            onPick: pick
        )
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

    /// The footer's two shortcuts have to know the bounds too, so a day field
    /// that refuses the future does not offer "Tomorrow".
    private func isAllowed(_ date: Date) -> Bool {
        EdDayPickerMonthGrid.isAllowed(date, in: bounds, calendar: calendar)
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

}

/// One month's squares, drawn once and repeated (#621).
///
/// Split out of `EdDayPickerCalendar` so the reel can turn five of these without
/// a second description of what a day looks like existing anywhere. That split
/// is the whole safeguard against #605 happening again: the app had two
/// calendars because a second surface needed a month laid out slightly
/// differently and grew its own, and a month that is one type cannot fork.
struct EdDayPickerMonthGrid: View {

    /// The month to draw, as a device-local midnight of any day in it.
    let month: Date
    /// The chosen day, which may sit in another month entirely — a neighbour in
    /// the reel still shows its own selection, which is how you can see where
    /// you came from after a step.
    let selection: Date
    var tint: Color = Tokens.accent(for: .meals)
    var bounds: ClosedRange<Date>? = nil
    var markedDays: Set<Date> = []
    var spokenDetail: (Date) -> String? = { _ in nil }

    /// False for a month the reel is only showing.
    ///
    /// It drops the `Button` wrapper rather than just refusing the tap. A
    /// neighbour is already hit-testing off at the page level, so the buttons
    /// would be dead weight: five months of them is 210 controls built and laid
    /// out on every frame of a slide, and the cheapest control is the one that
    /// was never made (#442).
    var isInteractive: Bool = true

    /// Pad the grid out to this many rows. Nil draws the month at its own
    /// height, which is right for a popover holding one month.
    var fixedRows: Int? = nil

    var onPick: (Date) -> Void = { _ in }

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EdDayPickerMetrics.gutter), count: 7)
    }

    private var slots: [MealCalendarSlot] {
        let month = MealCalendar.slots(forMonthOf: self.month, calendar: calendar)
        guard let fixedRows else { return month }
        return EdMonthReelMath.padded(month, toRows: fixedRows)
    }

    var body: some View {
        VStack(spacing: Space.md) {
            weekdayRow
            grid
        }
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
            ForEach(slots) { slot in
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

    // MARK: - One day

    @ViewBuilder
    private func cell(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let allowed = Self.isAllowed(date, in: bounds, calendar: calendar)
        let isMarked = markedDays.contains(calendar.startOfDay(for: date))

        if isInteractive {
            Button {
                guard allowed else { return }
                onPick(date)
            } label: {
                face(isSelected: isSelected, isToday: isToday, allowed: allowed, isMarked: isMarked, date: date)
            }
            .buttonStyle(.plain)
            .disabled(!allowed)
            .accessibilityLabel(
                [Self.spokenFormatter.string(from: date), spokenDetail(calendar.startOfDay(for: date))]
                    .compactMap { $0 }
                    .joined(separator: ", ")
            )
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            face(isSelected: isSelected, isToday: isToday, allowed: allowed, isMarked: isMarked, date: date)
                .accessibilityHidden(true)
        }
    }

    private func face(isSelected: Bool, isToday: Bool, allowed: Bool, isMarked: Bool, date: Date) -> some View {
        ZStack {
            Circle().fill(isSelected ? tint : Color.clear)
            if isToday && !isSelected {
                Circle().strokeBorder(Tokens.borderStrong, lineWidth: 1)
            }
            Text(Self.dayFormatter.string(from: date))
                .font(isSelected || isMarked ? .edFootnoteStrong : .edFootnote)
                .foregroundStyle(numeralInk(isSelected: isSelected, isMarked: isMarked, allowed: allowed))
                .monospacedDigit()
        }
        .frame(height: EdDayPickerMetrics.cell)
        .contentShape(Circle())
    }

    /// A marked day is drawn in full ink, an ordinary one in `inkSoft`, and a
    /// day outside the bounds in `mutedSoft`. The selected day's fill decides
    /// its own contrast and outranks both.
    private func numeralInk(isSelected: Bool, isMarked: Bool, allowed: Bool) -> Color {
        if isSelected { return Tokens.accentFg }
        guard allowed else { return Tokens.mutedSoft }
        return isMarked ? Tokens.ink : Tokens.inkSoft
    }

    /// Static so the calendar's footer can ask the same question of the same
    /// bounds without owning a second copy of the rule.
    static func isAllowed(_ date: Date, in bounds: ClosedRange<Date>?, calendar: Calendar) -> Bool {
        guard let bounds else { return true }
        let start = calendar.startOfDay(for: date)
        return start >= calendar.startOfDay(for: bounds.lowerBound)
            && start <= calendar.startOfDay(for: bounds.upperBound)
    }

    // MARK: - Formatters

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

    /// The grid alone, inside the card's padding. One page of the reel, and the
    /// width the popover's month is drawn at, so the two are the same object.
    static let pageWidth: CGFloat = cardWidth - Space.lg * 2
    /// Gap between months in the reel.
    static let pageGutter: CGFloat = Space.lg
    /// Centre to centre, which is what one step moves.
    static let pageStep: CGFloat = pageWidth + pageGutter
    /// The widest a filled-width month is drawn at. Past this the day discs
    /// are far enough apart that a week stops reading as a row.
    static let filledMaxWidth: CGFloat = 460
    /// Rows every month in the reel is padded to. Six is the most a month can
    /// need, so no month is ever cut short to reach it.
    static let reelRows: Int = 6
    /// How much dimmer each page is than the one nearer the centre.
    static let neighbourFade: Double = 0.4
    /// How much smaller each page is than the one nearer the centre.
    static let neighbourShrink: CGFloat = 0.08
    /// How far a neighbouring month is turned, in degrees.
    ///
    /// Moderate on purpose. Past about 40 degrees a grid of numerals stops
    /// reading as a month and becomes texture, and the point of showing the
    /// neighbours is that you can see WHICH months they are.
    static let neighbourTilt: Double = 34
    /// How strong the vanishing point is. Higher is a wider lens: the turn reads
    /// at a smaller angle, at the cost of the near edge ballooning.
    static let reelPerspective: CGFloat = 0.6
    /// How far each page past the first neighbour is pulled back towards the
    /// centre, on top of its place in the row.
    ///
    /// A page is laid out 284pt from the last one and then TURNED, which leaves
    /// it about 135pt wide on screen instead of 268. So the first neighbour sits
    /// snugly against the centre month and every page after it opens a hole:
    /// measured on a 902pt Mac pane, the second month began 149pt past where the
    /// first one ended, which is the same dead space this whole change is about,
    /// moved one page out.
    ///
    /// Uniform spacing cannot fix that, because one page in the row is full
    /// width and the rest are half of it. The pull closes the difference, and it
    /// is applied as a function of the page's ANIMATED distance — nothing at the
    /// centre, nothing at one page out, growing from there — so it is zero
    /// exactly where a page is full width, it eases in as a page turns away, and
    /// the arrangement either side of a step is still identical.
    static let neighbourPull: CGFloat = 130
    /// How long one step takes. Long enough to be seen as a direction, short
    /// enough that holding the chevron steps at a usable rate.
    static let slideDuration: Double = 0.28
    /// How far the reel dissolves into the card edge, at most. Capped against
    /// the row's own width, so a phone does not fade away a third of itself.
    static let edgeFade: CGFloat = 28
}
