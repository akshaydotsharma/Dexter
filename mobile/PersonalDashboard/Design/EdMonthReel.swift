import SwiftUI

/// The month carousel that `EdDayPickerCalendar` draws when a caller gives it a
/// whole row to fill (#621).
///
/// ### What this is, and what it is not
///
/// It is NOT a second calendar. Every page it turns is the same
/// `EdDayPickerMonthGrid` the popover draws: the same 268pt grid, the same 32pt
/// circles, the same ring for today and the same accent fill for the day you are
/// on. #605 deleted a calendar that had its own cell, its own marks and its own
/// paging, and nothing here brings that back. The reel adds one thing only —
/// the months either side of the one you are on — and it adds it by repeating
/// the control, not by replacing it.
///
/// ### Why the neighbours are there at all
///
/// A calendar is 268pt wide and a card is as wide as the window. On a phone that
/// left 46pt of dead space down each side; on a Mac detail pane it left a small
/// grid marooned in the middle of a wide surface. The only thing that belongs in
/// that space is where the chevrons are about to take you, and a plan is written
/// across a month boundary more often than not: this week's shopping, next
/// week's trip.
///
/// So the neighbours are not decoration in the sense of being arbitrary. They
/// carry the marked days too, which means "which days next month already have
/// meals on them" is answered without a step.
///
/// ### They are scenery, not controls
///
/// A neighbour is turned, faded and clipped by the card edge, so some of its
/// days are half drawn and some are not drawn at all. A square you can only half
/// see is not a square you should be able to book a dinner on. Every page but
/// the centred one is hit-testing off and hidden from the accessibility tree,
/// which also stops a reader walking ninety days it cannot act on.
///
/// ### The slide
///
/// One animated number drives the whole thing: `position`, in pages. It sets the
/// reel's offset and every page's turn, scale and fade, which is what makes a
/// step read as a wheel rather than as two states with a slide between them.
///
/// A step animates by exactly one page, then swaps the centre month and zeroes
/// the offset in the same non-animated transaction. The arrangement either side
/// of that swap is identical, so the jump cannot be seen, and the reel runs
/// forever in both directions while never holding more than a few months.
///
/// The swap is only invisible because one more page is rendered on each side
/// than can be seen — see `EdMonthReelMath.renderedOffsets(forWidth:)`. Without
/// that margin the month arriving at the far edge would pop into an empty slot
/// the instant the animation landed.
struct EdMonthReel<Page: View>: View {

    /// The centre month, as a device-local midnight of its first day.
    @Binding var month: Date

    /// One page. The flag is true for the centred month only, so a caller can
    /// draw a live grid in the middle and a dead one either side.
    @ViewBuilder var page: (Date, Bool) -> Page

    /// Where the reel is, in pages, measured from `month` at the centre.
    @State private var position: CGFloat = 0
    /// Held so a second tap during the animation cannot start a step from a
    /// half-turned reel, which would land the position between pages.
    @State private var isSliding = false
    /// Latched on the first drag that is more horizontal than vertical. Without
    /// it, a vertical flick to scroll the page would also nudge the reel.
    @State private var isDragging = false
    /// The row's own width, measured. Seeded at one card so the first frame
    /// cannot propose a width wider than a phone.
    @State private var containerWidth: CGFloat = EdDayPickerMetrics.cardWidth

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        reel
            .frame(width: containerWidth, alignment: .center)
            .clipped()
            .mask(edgeFade)
            .frame(maxWidth: .infinity)
            .background(widthReader)
            .contentShape(Rectangle())
            .gesture(swipe)
            .overlay(alignment: .leading) {
                stepButton("chevron.left", "Previous month") { step(-1) }
                    .padding(.leading, Space.sm)
            }
            .overlay(alignment: .trailing) {
                stepButton("chevron.right", "Next month") { step(1) }
                    .padding(.trailing, Space.sm)
            }
    }

    // MARK: - The reel

    private var reel: some View {
        HStack(spacing: EdDayPickerMetrics.pageGutter) {
            ForEach(EdMonthReelMath.renderedOffsets(forWidth: containerWidth), id: \.self) { offset in
                pageView(at: offset)
            }
        }
        // The HStack puts page n at n page-steps; moving the whole reel back by
        // the position lands page n at (n - position) steps, which is exactly
        // the distance each page is drawn from.
        .offset(x: -position * EdDayPickerMetrics.pageStep)
    }

    /// One month, turned by how far it is from the centre.
    private func pageView(at offset: Int) -> some View {
        let distance = CGFloat(offset) - position
        // Past one page the turn stops deepening. A month two steps out is
        // nearly off the card anyway, and letting it keep rotating would fold it
        // into a line during the slide. Depth carries on for one more page, so a
        // wide window reads as a wheel rather than as two flat rows of months.
        let reach = min(abs(distance), 1)
        let depth = min(abs(distance), 2)
        let isCentred = reach < 0.02

        return page(month(at: offset), isCentred)
            .frame(width: EdDayPickerMetrics.pageWidth)
            .opacity(1 - Double(depth) * EdDayPickerMetrics.neighbourFade)
            .scaleEffect(1 - depth * EdDayPickerMetrics.neighbourShrink, anchor: .center)
            // A neighbour faces INWARD, hinged on the edge nearest the centre,
            // so the wheel curves away from the reader on both sides rather than
            // flat months being pushed sideways. The anchor flips as a page
            // crosses the centre, which cannot be seen: the angle is zero there.
            .rotation3DEffect(
                .degrees(Double(max(-1, min(1, distance))) * EdDayPickerMetrics.neighbourTilt),
                axis: (x: 0, y: 1, z: 0),
                anchor: distance > 0 ? .leading : .trailing,
                perspective: EdDayPickerMetrics.reelPerspective
            )
            // Closes the hole a turned page leaves behind it. See
            // `EdDayPickerMetrics.neighbourPull` — this is applied AFTER the
            // rotation, so it moves the page as drawn rather than the box the
            // rotation is measured from.
            .offset(x: -pull(for: distance))
            .allowsHitTesting(isCentred)
            .accessibilityHidden(!isCentred)
    }

    /// How far a page is pulled back towards the centre. Zero for the centre
    /// month and its two immediate neighbours, growing by one pull per page
    /// after that, and signed so both sides close inwards.
    private func pull(for distance: CGFloat) -> CGFloat {
        let past = max(0, abs(distance) - 1)
        return (distance < 0 ? -1 : 1) * past * EdDayPickerMetrics.neighbourPull
    }

    private func month(at offset: Int) -> Date {
        guard let moved = calendar.date(byAdding: .month, value: offset, to: month) else { return month }
        return MealCalendar.monthStart(of: moved, calendar: calendar)
    }

    /// The card's edges dissolve rather than cut.
    ///
    /// A neighbouring month is clipped mid-week, and a hard edge makes that clip
    /// read as the end of the calendar: a column of numerals stopping against a
    /// wall looks like data that is missing rather than a month that continues.
    /// Fading it out says the reel goes on, which is the whole proposition.
    private var edgeFade: some View {
        let fade = min(EdDayPickerMetrics.edgeFade, containerWidth * 0.12)
        let stop = containerWidth > 0 ? fade / containerWidth : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: stop),
                .init(color: .black, location: 1 - stop),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Measures the row without taking part in sizing it. The width comes from
    /// the card this sits in, so reading it here cannot feed back into it.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in containerWidth = new }
        }
    }

    // MARK: - Chrome

    /// A step control, on its own ground.
    ///
    /// It sits over a faded month rather than beside a title, so it carries a
    /// filled disc: a bare chevron on top of a half-visible grid of numerals
    /// reads as one more numeral.
    ///
    /// On a phone this disc is most of what the side space holds, which is the
    /// point. The neighbour behind it is a sliver there, and a sliver on its own
    /// is a smudge; a sliver with the control that reaches it sitting on top is
    /// an edge you understand.
    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
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

    // MARK: - Actions

    /// Drag the reel by hand.
    ///
    /// Latched on the first movement that is more horizontal than vertical, and
    /// ignored otherwise, because this control lives inside a vertical
    /// `ScrollView`: without the test, a flick down the page would drag the
    /// months sideways on the way past.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isSliding else { return }
                if !isDragging {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    isDragging = true
                }
                position = max(-1, min(1, -value.translation.width / EdDayPickerMetrics.pageStep))
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                settle(on: EdMonthReelMath.settleTarget(position: position))
            }
    }

    private func step(_ months: Int) {
        guard !isSliding, !isDragging else { return }
        settle(on: months)
    }

    /// Slide to a page, then swap the month under cover of the finished slide.
    ///
    /// The two halves have to be one gesture to the eye: animate the offset, and
    /// once it has landed, move the month and zero the offset in a transaction
    /// with animation switched OFF. Animating that second half would slide the
    /// reel back the way it came.
    private func settle(on target: Int) {
        guard target != 0 else {
            withAnimation(.easeOut(duration: 0.2)) { position = 0 }
            return
        }
        isSliding = true
        withAnimation(.easeInOut(duration: EdDayPickerMetrics.slideDuration)) {
            position = CGFloat(target)
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                month = self.month(at: target)
                position = 0
            }
            isSliding = false
        }
    }
}

/// The arithmetic behind `EdMonthReel`, as free functions (#621).
///
/// Held apart from the view for the reason every other calendar table in this
/// app gives: the ways it can be wrong are SILENT. A reel that renders exactly
/// as many months as it can show pops a month into the far edge on every step,
/// and a settle threshold that rounds the wrong way takes a half-hearted drag
/// into the next month. Neither looks broken in a screenshot.
enum EdMonthReelMath {

    /// How many months can be seen on each side of the centred one.
    ///
    /// Capped at two. Past that a page is under 20% opacity and turned as far as
    /// it will turn, so it adds width without adding anything to read.
    static func visiblePagesEachSide(forWidth width: CGFloat) -> Int {
        let half = (width - EdDayPickerMetrics.pageWidth) / 2
        let pages = Int(ceil(half / EdDayPickerMetrics.pageStep))
        return min(2, max(1, pages))
    }

    /// The months the reel holds, as offsets from the centre.
    ///
    /// One more on each side than can be seen. That margin is what makes the
    /// month swap at the end of a step invisible: the page arriving at the far
    /// edge was already drawn, one slot out, before the swap happened.
    static func renderedOffsets(forWidth width: CGFloat) -> [Int] {
        let reach = visiblePagesEachSide(forWidth: width) + 1
        return Array(-reach...reach)
    }

    /// Where a released drag lands. Half a page commits; anything less springs
    /// back, so a nudge cannot change the month under the user's thumb.
    static func settleTarget(position: CGFloat) -> Int {
        if position >= 0.5 { return 1 }
        if position <= -0.5 { return -1 }
        return 0
    }

    /// Pad a month's squares out to a fixed number of rows.
    ///
    /// Six rows always in the reel. A five-row month drawn at its natural height
    /// would shorten the card as it reached the centre, which moves everything
    /// below the calendar up and then down again on every step, and it would
    /// leave the neighbours' weeks out of line with the centre month's.
    static func padded(_ slots: [MealCalendarSlot], toRows rows: Int) -> [MealCalendarSlot] {
        var padded = slots
        let wanted = rows * 7
        while padded.count < wanted {
            padded.append(MealCalendarSlot(index: padded.count, day: nil))
        }
        return padded
    }
}
