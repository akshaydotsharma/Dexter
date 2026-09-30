import XCTest
@testable import PersonalDashboard

/// The one-line quick add (#687): parsed on the device with plain rules.
final class PlannerQuickAddTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return c
    }()

    /// Tuesday 29 September 2026.
    private var tuesday: Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 29))!
    }

    private func parse(_ s: String) -> PlannerQuickAdd.Result {
        PlannerQuickAdd.parse(s, on: tuesday, calendar: cal)
    }

    private func hm(_ d: Date?) -> String? {
        guard let d else { return nil }
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func weekday(_ d: Date) -> Int { cal.component(.weekday, from: d) }

    func testTheDesignExample() {
        let r = parse("Call bank 3:30pm 15m")
        XCTAssertEqual(r.title, "Call bank")
        XCTAssertEqual(hm(r.start), "15:30")
        XCTAssertEqual(r.durationMinutes, 15)
        XCTAssertEqual(hm(r.end), "15:45")
        XCTAssertEqual(r.day, tuesday)
    }

    func testAnHourWithMeridiem() {
        let r = parse("Gym 7am 1h")
        XCTAssertEqual(r.title, "Gym")
        XCTAssertEqual(hm(r.start), "07:00")
        XCTAssertEqual(r.durationMinutes, 60)
    }

    func testTwentyFourHourTime() {
        let r = parse("Deep work 14:00 90 mins")
        XCTAssertEqual(r.title, "Deep work")
        XCTAssertEqual(hm(r.start), "14:00")
        XCTAssertEqual(r.durationMinutes, 90)
    }

    func testARangeSetsStartAndLength() {
        let r = parse("Focus PRD 10-11:30am")
        XCTAssertEqual(r.title, "Focus PRD")
        XCTAssertEqual(hm(r.start), "10:00")
        XCTAssertEqual(r.durationMinutes, 90)
    }

    func testARangeAcrossNoonBorrowsTheOtherMeridiem() {
        let r = parse("Workshop 11-1pm")
        XCTAssertEqual(hm(r.start), "11:00")
        XCTAssertEqual(r.durationMinutes, 120)
    }

    func testARangeWithTo() {
        let r = parse("Offsite 2 to 4pm")
        XCTAssertEqual(r.title, "Offsite")
        XCTAssertEqual(hm(r.start), "14:00")
        XCTAssertEqual(r.durationMinutes, 120)
    }

    func testHoursAndMinutesLength() {
        XCTAssertEqual(parse("Write 1h30 at 2pm").durationMinutes, 90)
        XCTAssertEqual(parse("Write 1h 30m at 2pm").durationMinutes, 90)
        XCTAssertEqual(parse("Write 1.5h at 2pm").durationMinutes, 90)
    }

    func testALengthDoesNotEatTheTimeAfterIt() {
        let r = parse("Review 1h 3:30pm")
        XCTAssertEqual(r.durationMinutes, 60)
        XCTAssertEqual(hm(r.start), "15:30")
        XCTAssertEqual(r.title, "Review")
    }

    func testAtWithABareHourReadsWorkingHours() {
        XCTAssertEqual(hm(parse("Call Mum at 3").start), "15:00", "1 to 6 read as the afternoon")
        XCTAssertEqual(hm(parse("Standup at 9").start), "09:00")
    }

    func testABareNumberIsNotATime() {
        let r = parse("Read 3 chapters")
        XCTAssertNil(r.start)
        XCTAssertEqual(r.title, "Read 3 chapters")
    }

    func testNoonAndTwelveHourEdges() {
        XCTAssertEqual(hm(parse("Lunch noon").start), "12:00")
        XCTAssertEqual(hm(parse("Lunch 12pm").start), "12:00")
        XCTAssertEqual(hm(parse("Late call 12am").start), "00:00")
    }

    func testNoTimeMeansTheDayWithNoHourAndThirtyMinutes() {
        let r = parse("Clean inbox")
        XCTAssertNil(r.start)
        XCTAssertFalse(r.isTimed)
        XCTAssertEqual(r.durationMinutes, 30)
        XCTAssertEqual(r.title, "Clean inbox")
    }

    func testALengthWithNoTimeIsADayBlockOfThatLength() {
        let r = parse("Taxes 2h")
        XCTAssertNil(r.start)
        XCTAssertEqual(r.durationMinutes, 120)
        XCTAssertEqual(r.title, "Taxes")
    }

    func testTomorrowMovesTheDay() {
        let r = parse("Dentist tomorrow 9:15am 45m")
        XCTAssertEqual(r.title, "Dentist")
        XCTAssertEqual(weekday(r.day), 4)
        XCTAssertEqual(hm(r.start), "09:15")
        XCTAssertEqual(cal.component(.day, from: r.start!), 30)
    }

    func testAWeekdayMeansTheNextOneOrToday() {
        XCTAssertEqual(cal.component(.day, from: parse("Retro fri 4pm").day), 2, "Friday 2 October")
        XCTAssertEqual(cal.component(.day, from: parse("Plan tue").day), 29, "Tuesday is today")
        XCTAssertEqual(cal.component(.day, from: parse("Call on monday").day), 5)
    }

    func testDanglingConnectivesLeaveTheTitle() {
        XCTAssertEqual(parse("Call bank at 3:30pm for 15m").title, "Call bank")
    }

    func testEmptyTitleFallsBack() {
        XCTAssertEqual(parse("3pm 30m").title, "Block")
    }

    func testMinuteOfDay() {
        XCTAssertEqual(PlannerQuickAdd.minuteOfDay(hour: 12, minute: 0, meridiem: "am"), 0)
        XCTAssertEqual(PlannerQuickAdd.minuteOfDay(hour: 12, minute: 30, meridiem: "pm"), 12 * 60 + 30)
        XCTAssertEqual(PlannerQuickAdd.minuteOfDay(hour: 8, minute: 0, meridiem: ""), 8 * 60)
        XCTAssertEqual(PlannerQuickAdd.minuteOfDay(hour: 5, minute: 0, meridiem: ""), 17 * 60)
    }
}

/// Calendar tagging defaults (#687).
final class PlannerCalendarTaggingTests: XCTestCase {
    func testWorkDomainIsWorkAndConsumerMailIsPersonal() {
        XCTAssertEqual(PlannerCalendarTagging.defaultTag(sourceTitle: "akshay.sharma@envisso.com", calendarTitle: "Calendar", isExchange: false), .work)
        XCTAssertEqual(PlannerCalendarTagging.defaultTag(sourceTitle: "akshay@gmail.com", calendarTitle: "akshay@gmail.com", isExchange: false), .personal)
        XCTAssertEqual(PlannerCalendarTagging.defaultTag(sourceTitle: "iCloud", calendarTitle: "Home", isExchange: false), .personal)
    }

    func testExchangeAndAWorkTitleAreWork() {
        XCTAssertEqual(PlannerCalendarTagging.defaultTag(sourceTitle: "Outlook", calendarTitle: "Calendar", isExchange: true), .work)
        XCTAssertEqual(PlannerCalendarTagging.defaultTag(sourceTitle: "iCloud", calendarTitle: "Work", isExchange: false), .work)
    }

    func testEmailDomain() {
        XCTAssertEqual(PlannerCalendarTagging.emailDomain(in: "Akshay <a.s@Envisso.com>"), "envisso.com")
        XCTAssertNil(PlannerCalendarTagging.emailDomain(in: "no email"))
    }
}
