import XCTest
@testable import PersonalDashboard

/// The date arithmetic behind a recurring task (#524).
///
/// Pinned to a fixed Gregorian/Singapore calendar rather than `.current`, so a
/// rule's meaning is asserted rather than the machine's locale. Every case here
/// is one a rule can silently get wrong: a wrong answer still produces a task, on
/// a date nobody notices is off until the thing it was for has already happened.
final class RecurrenceRuleTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    /// 2026-09-12 is a Saturday, which is why it is the anchor for the weekly
    /// cases: it is not the start of anyone's week, so an off-by-one week shows up.
    private func day(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return calendar.startOfDay(for: formatter.date(from: text)!)
    }

    private func key(_ date: Date?) -> String? {
        date.map { RecurrenceRule.dayKey($0, calendar: calendar) }
    }

    private func rule(
        _ frequency: RecurrenceFrequency,
        every interval: Int = 1,
        weekdays: [Int] = [],
        dayOfMonth: Int = 1,
        monthOfYear: Int = 1,
        minutes: Int = 9 * 60,
        start: String,
        end: String? = nil
    ) -> RecurrenceRule {
        RecurrenceRule(
            frequency: frequency,
            interval: interval,
            weekdayMask: weekdays.reduce(0) { $0 | (1 << $1) },
            dayOfMonth: dayOfMonth,
            monthOfYear: monthOfYear,
            timeOfDayMinutes: minutes,
            startDay: day(start),
            endDay: end.map(day),
            calendar: calendar
        )
    }

    // MARK: - Daily

    func testDailyStartsOnItsStartDay() {
        XCTAssertEqual(key(rule(.daily, start: "2026-09-12").nextDay(after: nil)), "2026-09-12")
    }

    func testDailyStepsOneDay() {
        let next = rule(.daily, start: "2026-09-12").nextDay(after: day("2026-09-12"))
        XCTAssertEqual(key(next), "2026-09-13")
    }

    /// An interval counts from the START, not from the cursor. Counting from the
    /// cursor would let the rule drift every time a pass ran on an odd day.
    func testEveryThreeDaysCountsFromTheStart() {
        let rule = rule(.daily, every: 3, start: "2026-09-12")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-13"))), "2026-09-15")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-30"))), "2026-10-03")
    }

    // MARK: - Weekly
    //
    // Weekday indices are Sunday-based: 0 = Sun … 6 = Sat.

    func testWeeklyPicksTheNextSelectedWeekday() {
        let rule = rule(.weekly, weekdays: [1, 3, 5], start: "2026-09-12")   // Mon, Wed, Fri
        XCTAssertEqual(key(rule.nextDay(after: nil)), "2026-09-14")           // Mon
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-14"))), "2026-09-16")  // Wed
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-18"))), "2026-09-21")  // next Mon
    }

    /// An empty weekday set is not a rule that never fires: it falls back to the
    /// weekday the template starts on, so a template saved by a path that never
    /// touched the picker still comes around.
    func testWeeklyWithNoWeekdayFallsBackToTheStartWeekday() {
        let rule = rule(.weekly, start: "2026-09-12")                         // a Saturday
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-12"))), "2026-09-19")
    }

    /// The one that was wrong first time round. "Every 2 weeks on Monday" created
    /// on a Saturday has to fire on the Monday two days later. Anchoring the
    /// fortnight on the START DAY's week instead put the first occurrence a
    /// fortnight out, because that week's Monday was already behind the start.
    func testEveryTwoWeeksAnchorsOnTheFirstFiringDayNotTheStartWeek() {
        let rule = rule(.weekly, every: 2, weekdays: [1], start: "2026-09-12")
        XCTAssertEqual(key(rule.nextDay(after: nil)), "2026-09-14")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-14"))), "2026-09-28")
        // 21 Sep is a Monday in the OFF week, so a cursor just before it still
        // has to skip to the 28th.
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-20"))), "2026-09-28")
    }

    // MARK: - Monthly

    func testMonthlyWaitsForNextMonthWhenThisMonthsDayHasGone() {
        XCTAssertEqual(key(rule(.monthly, dayOfMonth: 1, start: "2026-09-12").nextDay(after: nil)), "2026-10-01")
    }

    func testMonthlyUsesThisMonthWhenItsDayIsStillAhead() {
        XCTAssertEqual(key(rule(.monthly, dayOfMonth: 20, start: "2026-09-12").nextDay(after: nil)), "2026-09-20")
    }

    /// A day past the end of a short month clamps to that month's last day, and
    /// then RECOVERS to the stored day in the next long one. Clamping the stored
    /// value instead would silently move a "last day of the month" rule to the 28th
    /// forever after one February.
    func testMonthlyClampsShortMonthsAndThenRecovers() {
        let rule = rule(.monthly, dayOfMonth: 31, start: "2026-10-31")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-10-31"))), "2026-11-30")
        XCTAssertEqual(key(rule.nextDay(after: day("2027-01-31"))), "2027-02-28")
        XCTAssertEqual(key(rule.nextDay(after: day("2027-02-28"))), "2027-03-31")
    }

    func testEveryTwoMonthsSkipsTheOddMonth() {
        let rule = rule(.monthly, every: 2, dayOfMonth: 15, start: "2026-09-01")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-15"))), "2026-11-15")
    }

    /// A cursor far behind the interval must still land on an ON month, not simply
    /// on the next one that happens to be due.
    func testEveryThreeMonthsFromALongStaleCursor() {
        let rule = rule(.monthly, every: 3, dayOfMonth: 5, start: "2026-01-05")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-12"))), "2026-10-05")
    }

    // MARK: - Yearly

    func testYearlyFiresThisYearThenNext() {
        let rule = rule(.yearly, dayOfMonth: 25, monthOfYear: 12, start: "2026-09-12")
        XCTAssertEqual(key(rule.nextDay(after: nil)), "2026-12-25")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-12-25"))), "2027-12-25")
    }

    func testYearlyWaitsForNextYearWhenItsDateHasGone() {
        let rule = rule(.yearly, dayOfMonth: 1, monthOfYear: 3, start: "2026-09-12")
        XCTAssertEqual(key(rule.nextDay(after: nil)), "2027-03-01")
    }

    /// 29 February on a common year. Same clamp-then-recover contract as the
    /// monthly case, four years apart.
    func testYearlyClampsTheLeapDayAndRecoversOnALeapYear() {
        let rule = rule(.yearly, dayOfMonth: 29, monthOfYear: 2, start: "2026-03-01")
        XCTAssertEqual(key(rule.nextDay(after: nil)), "2027-02-28")
        XCTAssertEqual(key(rule.nextDay(after: day("2027-02-28"))), "2028-02-29")
    }

    // MARK: - End date

    func testEndDateExhaustsTheRule() {
        let rule = rule(.daily, start: "2026-09-12", end: "2026-09-13")
        XCTAssertEqual(key(rule.nextDay(after: day("2026-09-12"))), "2026-09-13")
        XCTAssertNil(rule.nextDay(after: day("2026-09-13")))
    }

    // MARK: - Time of day

    /// The time is a time of day, not an instant and not a UTC wall-clock anchor
    /// (#168, #506). 18:30 means 18:30 on the device, which is what makes a rule
    /// survive a timezone change without moving.
    func testDueDateAppliesTheRulesTimeOfDay() {
        let rule = rule(.daily, minutes: 18 * 60 + 30, start: "2026-09-12")
        let due = rule.dueDate(on: day("2026-09-12"))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 30)
        XCTAssertEqual(parts.day, 12)
    }

    // MARK: - Keys

    func testDayKeyRoundTrips() {
        let original = day("2027-02-28")
        let text = RecurrenceRule.dayKey(original, calendar: calendar)
        XCTAssertEqual(text, "2027-02-28")
        XCTAssertEqual(RecurrenceRule.day(fromKey: text, calendar: calendar), original)
    }

    func testDayKeyRejectsNonsense() {
        XCTAssertNil(RecurrenceRule.day(fromKey: "not-a-day", calendar: calendar))
    }

    // MARK: - Words

    func testSummaryNamesTheRule() {
        XCTAssertEqual(rule(.daily, start: "2026-09-12").summary, "Every day at 09:00")
        XCTAssertEqual(rule(.daily, every: 3, start: "2026-09-12").summary, "Every 3 days at 09:00")
        XCTAssertEqual(rule(.monthly, dayOfMonth: 1, start: "2026-09-12").summary, "Monthly on the 1st at 09:00")
        XCTAssertEqual(rule(.monthly, every: 2, dayOfMonth: 23, start: "2026-09-12").summary,
                       "Every 2 months on the 23rd at 09:00")
    }

    func testOrdinalHandlesTheTeens() {
        XCTAssertEqual(RecurrenceRule.ordinal(1), "1st")
        XCTAssertEqual(RecurrenceRule.ordinal(2), "2nd")
        XCTAssertEqual(RecurrenceRule.ordinal(3), "3rd")
        XCTAssertEqual(RecurrenceRule.ordinal(11), "11th")
        XCTAssertEqual(RecurrenceRule.ordinal(12), "12th")
        XCTAssertEqual(RecurrenceRule.ordinal(13), "13th")
        XCTAssertEqual(RecurrenceRule.ordinal(21), "21st")
        XCTAssertEqual(RecurrenceRule.ordinal(31), "31st")
    }
}
