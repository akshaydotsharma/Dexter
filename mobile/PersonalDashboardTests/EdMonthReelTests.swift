import XCTest
@testable import PersonalDashboard

/// The month reel's arithmetic (#621).
///
/// ### Why this is pinned rather than eyeballed
///
/// Every way a reel can be wrong is silent, in the same sense the grid
/// arithmetic is (see `MealsCalendarTests`). A reel that renders exactly as many
/// months as it can SHOW looks perfect standing still and pops a month into the
/// far edge on every step. A settle threshold that rounds the wrong way takes a
/// nudge into the next month under the user's thumb. A month grid that is not
/// padded to a fixed height shortens the card as a five-row month reaches the
/// middle, which moves the whole plan below it up and then down again.
///
/// None of the three looks broken in a screenshot, and all three are arithmetic,
/// so they belong here rather than in a hands-on pass.
final class EdMonthReelTests: XCTestCase {

    /// A fixed calendar, so a month is a month and not "whatever the machine
    /// that ran the suite was set to".
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)!
    }

    // MARK: - How many months the reel holds

    /// The margin that makes the month swap invisible.
    ///
    /// A step animates by one page and then moves the centre month with
    /// animation off. The page arriving at the far edge has to have been drawn
    /// ALREADY, one slot beyond what is visible, or it appears out of nothing at
    /// the instant the slide lands.
    func testTheReelAlwaysRendersOneMoreMonthThanItCanShow() {
        for width in [320, 361, 700, 900, 1400] as [CGFloat] {
            let visible = EdMonthReelMath.visiblePagesEachSide(forWidth: width)
            let rendered = EdMonthReelMath.renderedOffsets(forWidth: width)
            XCTAssertEqual(
                rendered.first, -(visible + 1),
                "at \(width)pt the reel must draw one month beyond the leftmost visible one"
            )
            XCTAssertEqual(
                rendered.last, visible + 1,
                "at \(width)pt the reel must draw one month beyond the rightmost visible one"
            )
        }
    }

    /// The centre month is always drawn, at every width, and exactly once.
    func testEveryWidthDrawsTheCentreMonthOnce() {
        for width in [0, 200, 361, 900, 2000] as [CGFloat] {
            let rendered = EdMonthReelMath.renderedOffsets(forWidth: width)
            XCTAssertEqual(rendered.filter { $0 == 0 }.count, 1, "at \(width)pt")
            XCTAssertEqual(rendered, rendered.sorted(), "at \(width)pt the reel must run in order")
        }
    }

    /// A phone shows one month each side: the card is ~361pt and a page is
    /// 268pt, so the space left over is a sliver rather than a month.
    func testAPhoneShowsOneMonthEachSide() {
        XCTAssertEqual(EdMonthReelMath.visiblePagesEachSide(forWidth: 361), 1)
    }

    /// A wide Mac pane shows two, which is what stops the same complaint
    /// reappearing one page further out.
    func testAWideWindowShowsTwoMonthsEachSide() {
        XCTAssertEqual(EdMonthReelMath.visiblePagesEachSide(forWidth: 900), 2)
    }

    /// Never three, however wide the window. Past two pages a month is under
    /// 20% opacity and turned as far as it will turn, so it costs a grid of
    /// forty-two cells and adds nothing to read.
    func testTheReelNeverShowsMoreThanTwoMonthsEachSide() {
        for width in [1400, 2000, 4000] as [CGFloat] {
            XCTAssertEqual(EdMonthReelMath.visiblePagesEachSide(forWidth: width), 2, "at \(width)pt")
        }
    }

    /// A container narrower than one page still holds a neighbour. It is
    /// entirely clipped, and the alternative is a reel that silently stops being
    /// a reel on the first frame, before the width has been measured.
    func testANarrowContainerStillHoldsANeighbour() {
        XCTAssertEqual(EdMonthReelMath.visiblePagesEachSide(forWidth: 100), 1)
        XCTAssertEqual(EdMonthReelMath.visiblePagesEachSide(forWidth: 0), 1)
    }

    // MARK: - Where a released drag lands

    /// Half a page commits. Anything less springs back, so a nudge cannot change
    /// the month under the user's thumb.
    func testADragPastHalfAPageCommitsAndAnythingLessSpringsBack() {
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: 0.49), 0)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: 0.5), 1)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: 0.9), 1)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: -0.49), 0)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: -0.5), -1)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: -0.9), -1)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: 0), 0)
    }

    /// One month per gesture, whatever the drag did. The reel only ever holds
    /// the months around the centre, so a two-page jump would land on a page
    /// that was never drawn.
    func testADragNeverCommitsMoreThanOneMonth() {
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: 5), 1)
        XCTAssertEqual(EdMonthReelMath.settleTarget(position: -5), -1)
    }

    // MARK: - Six rows, always

    /// A five-row month is padded to six.
    ///
    /// February 2027 starts on a Monday and has 28 days, so it fills exactly
    /// four rows on a Monday-first calendar. Drawn at its own height it would
    /// shorten the card as it reached the centre of the reel, and leave its
    /// weeks out of line with the months either side of it.
    func testAShortMonthIsPaddedToSixRows() {
        let slots = MealCalendar.slots(forMonthOf: date(2027, 2, 1), calendar: calendar)
        XCTAssertEqual(slots.count, 28, "February 2027 fills exactly four Monday-first rows")

        let padded = EdMonthReelMath.padded(slots, toRows: 6)
        XCTAssertEqual(padded.count, 42)
        XCTAssertEqual(padded.filter { $0.day != nil }.count, 28, "padding must not invent days")
        XCTAssertEqual(Set(padded.map(\.id)).count, 42, "every square needs its own identity")
    }

    /// The longest a month can be is six rows, so padding never cuts one short.
    func testASixRowMonthIsUnchanged() {
        // August 2026 starts on a Saturday and has 31 days: 5 leading blanks
        // plus 31 days runs into a sixth row.
        let slots = MealCalendar.slots(forMonthOf: date(2026, 8, 1), calendar: calendar)
        XCTAssertEqual(slots.count, 42)
        XCTAssertEqual(EdMonthReelMath.padded(slots, toRows: 6), slots)
    }

    /// Every month in the reel is the same height, which is the whole point of
    /// the padding: the card cannot change height as the reel turns.
    func testEveryMonthOfAYearPadsToTheSameHeight() {
        for month in 1...12 {
            let slots = MealCalendar.slots(forMonthOf: date(2026, month, 1), calendar: calendar)
            XCTAssertEqual(
                EdMonthReelMath.padded(slots, toRows: 6).count, 42,
                "month \(month) of 2026"
            )
        }
    }
}
