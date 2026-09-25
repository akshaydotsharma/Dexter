import XCTest
@testable import PersonalDashboard

/// The rules for missed, streak and rate (#661), against the pure ledger.
///
/// Every day here is a UTC anchor built with `day(_:_:_:)`. 2026-09-20 is a
/// Sunday, which the weekday tests lean on.
final class HabitLedgerTests: XCTestCase {

    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    // MARK: - Fixtures

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        WallClock.dayAnchor(fromISO: String(format: "%04d-%02d-%02d", y, m, d))!
    }

    private func daily(start: Date, target: Int = 1) -> HabitRule {
        HabitRule(schedule: .daily, weekdayMask: 0b111_1111, targetCount: target, startDay: start)
    }

    private let done = HabitDayEntry(count: 1, status: .done)
    private let skip = HabitDayEntry(count: 0, status: .skipped)


    /// Due past days with nothing logged, counted through the ledger's own
    /// `state`. The app no longer shows this number (#661: a day is done or
    /// empty), but the rule behind it still ends streaks and still counts in
    /// the rate, so the tests keep checking it.
    private func notDoneCount(_ rule: HabitRule, entries: [Date: HabitDayEntry], from: Date, today: Date) -> Int {
        var count = 0
        var d = max(HabitLedger.key(from), HabitLedger.key(rule.startDay))
        while d < HabitLedger.key(today) {
            if HabitLedger.state(rule, entry: entries[d], on: d, today: today) == .missed { count += 1 }
            d = HabitLedger.adding(1, to: d)
        }
        return count
    }

    // MARK: - Missed

    /// Missed needs all four: scheduled, on or after the start, before today,
    /// and nothing done or skipped. Each other case is neutral.
    func testMissedOnlyOnScheduledPastDaysOnOrAfterTheStart() {
        let start = day(2026, 9, 15)
        let today = day(2026, 9, 20)
        let rule = daily(start: start)
        let entries = [day(2026, 9, 16): done]

        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 14), today: today), .notStarted,
                       "a day before the habit existed is never missed")
        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: start, today: today), .missed,
                       "the start day itself is due")
        XCTAssertEqual(HabitLedger.state(rule, entry: entries[day(2026, 9, 16)], on: day(2026, 9, 16), today: today), .done)
        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 21), today: today), .future)
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 1), today: today), 4,
                       "15, 17, 18, 19 are missed; the 16th is done and today is still open")
    }

    /// Today stays pending until it ends: it is not missed, it does not break a
    /// streak, and it does not lower the rate.
    func testTodayIsPendingNotMissed() {
        let today = day(2026, 9, 20)
        let rule = daily(start: day(2026, 9, 17))
        let entries = [day(2026, 9, 17): done, day(2026, 9, 18): done, day(2026, 9, 19): done]

        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: today, today: today), .pending)
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 3,
                       "an open today must not zero a three-day streak")
        let rate = HabitLedger.rate(rule, entries: entries, from: day(2026, 9, 1), today: today)
        XCTAssertEqual(rate.done, 3)
        XCTAssertEqual(rate.counted, 3, "today is out of the rate until it is done")
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 1), today: today), 0)

        var withToday = entries
        withToday[today] = done
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: withToday, today: today), 4)
        XCTAssertEqual(HabitLedger.rate(rule, entries: withToday, from: day(2026, 9, 1), today: today).counted, 4)
    }

    // MARK: - Skipped

    /// A skip keeps the streak alive (it is stepped over, not counted) and is
    /// left out of both halves of the rate.
    func testASkippedDayIsNeutralForStreakAndRate() {
        let today = day(2026, 9, 20)
        let rule = daily(start: day(2026, 9, 15))
        let entries = [
            day(2026, 9, 15): done,
            day(2026, 9, 16): done,
            day(2026, 9, 17): skip,
            day(2026, 9, 18): done,
            day(2026, 9, 19): done,
            today: done,
        ]

        XCTAssertEqual(HabitLedger.state(rule, entry: skip, on: day(2026, 9, 17), today: today), .skipped)
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 5,
                       "the skip must not break the run, and must not add to it")
        XCTAssertEqual(HabitLedger.bestStreak(rule, entries: entries, today: today), 5)
        let rate = HabitLedger.rate(rule, entries: entries, from: day(2026, 9, 15), today: today)
        XCTAssertEqual(rate.done, 5)
        XCTAssertEqual(rate.counted, 5, "the skipped day is out of the denominator")
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 15), today: today), 0)
    }

    /// Replacing that skip with nothing turns it into a miss and splits the run.
    func testTheSameDayWithoutTheSkipBreaksTheStreak() {
        let today = day(2026, 9, 20)
        let rule = daily(start: day(2026, 9, 15))
        let entries = [
            day(2026, 9, 15): done, day(2026, 9, 16): done,
            day(2026, 9, 18): done, day(2026, 9, 19): done, today: done,
        ]
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 3)
        XCTAssertEqual(HabitLedger.bestStreak(rule, entries: entries, today: today), 3)
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 15), today: today), 1)
    }

    // MARK: - Weekday schedule

    /// Mon / Wed / Fri. The days between are unscheduled: never missed, and a
    /// streak steps over them.
    func testAWeekdayScheduleOnlyCountsItsOwnDays() {
        let mwf = (1 << 1) | (1 << 3) | (1 << 5)
        let rule = HabitRule(schedule: .weekdays, weekdayMask: mwf, targetCount: 1, startDay: day(2026, 9, 14))
        let today = day(2026, 9, 20)   // Sunday
        let entries = [day(2026, 9, 14): done, day(2026, 9, 16): done, day(2026, 9, 18): done]

        XCTAssertEqual(HabitLedger.weekdayIndex(of: day(2026, 9, 20)), 0, "20 Sep 2026 is a Sunday")
        XCTAssertEqual(HabitLedger.weekdayIndex(of: day(2026, 9, 14)), 1, "14 Sep 2026 is a Monday")
        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 15), today: today), .unscheduled)
        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: today, today: today), .unscheduled,
                       "a Sunday is not due, so it is not even pending")
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 14), today: today), 0)
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 3)

        var missedFriday = entries
        missedFriday[day(2026, 9, 18)] = nil
        XCTAssertEqual(notDoneCount(rule, entries: missedFriday, from: day(2026, 9, 14), today: today), 1)
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: missedFriday, today: today), 0)
    }

    // MARK: - Partial count

    /// 8 glasses. Five is partial: not done, so a past partial ends a streak and
    /// counts against the rate, but it is not "missed", because something was
    /// logged. Today's partial is still open and costs nothing.
    func testAPartialCountIsNotDoneAndNotMissed() {
        let today = day(2026, 9, 20)
        let rule = daily(start: day(2026, 9, 17), target: 8)
        let entries = [
            day(2026, 9, 17): HabitDayEntry(count: 8, status: .done),
            day(2026, 9, 18): HabitDayEntry(count: 5, status: .done),
            day(2026, 9, 19): HabitDayEntry(count: 9, status: .done),
            today: HabitDayEntry(count: 3, status: .done),
        ]

        XCTAssertEqual(HabitLedger.state(rule, entry: entries[day(2026, 9, 18)], on: day(2026, 9, 18), today: today),
                       .partial(count: 5, target: 8))
        XCTAssertEqual(HabitLedger.state(rule, entry: entries[day(2026, 9, 19)], on: day(2026, 9, 19), today: today),
                       .done, "past the target is still done")
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 1,
                       "today's open partial is neutral; the 18th's partial ends the run at the 19th")
        XCTAssertEqual(notDoneCount(rule, entries: entries, from: day(2026, 9, 17), today: today), 0)
        let rate = HabitLedger.rate(rule, entries: entries, from: day(2026, 9, 17), today: today)
        XCTAssertEqual(rate.done, 2)
        XCTAssertEqual(rate.counted, 3, "a past partial counts; today's does not")
    }

    // MARK: - Timezone

    /// A check-in made late on Sunday evening in Singapore is filed under
    /// Sunday, and it still reads as Sunday, done, once the device is in
    /// Rome or New York. The only zone-dependent step is turning "now" into
    /// today's anchor.
    func testATimezoneShiftKeepsTheDay() {
        // 22:30 on Sunday 20 September in Singapore is 14:30Z.
        let lateSundayInSingapore = ISO8601DateFormatter().date(from: "2026-09-20T14:30:00Z")!
        let written = HabitLedger.todayAnchor(now: lateSundayInSingapore, timeZone: TimeZone(identifier: "Asia/Singapore")!)
        XCTAssertEqual(written, day(2026, 9, 20))
        XCTAssertTrue(WallClock.isDayAnchored(written))

        // The same instant in New York is still Sunday morning; in Auckland it
        // is already Monday. The WRITE uses the writer's zone, as it must.
        XCTAssertEqual(
            HabitLedger.todayAnchor(now: lateSundayInSingapore, timeZone: TimeZone(identifier: "Pacific/Auckland")!),
            day(2026, 9, 21)
        )

        let rule = daily(start: day(2026, 9, 14))
        let entries = [written: done]
        for zone in ["Asia/Singapore", "Europe/Rome", "America/New_York", "Pacific/Honolulu"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            XCTAssertEqual(HabitLedger.weekdayIndex(of: written), 0, "the day is still a Sunday in \(zone)")
            XCTAssertEqual(
                HabitLedger.state(rule, entry: entries[HabitLedger.key(written)], on: written, today: day(2026, 9, 21)),
                .done,
                "the check-in moved off its day in \(zone)"
            )
            let shown = Calendar.current.dateComponents([.day], from: WallClock.deviceDay(from: written)).day
            XCTAssertEqual(shown, 20, "the grid would print a different date in \(zone)")
        }
        XCTAssertEqual(
            HabitCheckInID.make(habitUUID: "ABC", day: written), "abc-20260920",
            "the row id is read from UTC components, so every device names the day the same"
        )
    }

    // MARK: - Best streak and summary

    func testBestStreakFindsTheLongestRunAnywhere() {
        let today = day(2026, 9, 20)
        let rule = daily(start: day(2026, 9, 1))
        var entries: [Date: HabitDayEntry] = [:]
        for d in 2...6 { entries[day(2026, 9, d)] = done }   // 5 in a row
        for d in 10...11 { entries[day(2026, 9, d)] = done } // 2 in a row
        entries[today] = done

        XCTAssertEqual(HabitLedger.bestStreak(rule, entries: entries, today: today), 5)
        XCTAssertEqual(HabitLedger.currentStreak(rule, entries: entries, today: today), 1)
    }

    /// A due day with nothing logged is shown as EMPTY, never as "missed", and
    /// it reads "not done" to VoiceOver. The rule is unchanged: it still ends
    /// the streak and still counts in the rate.
    func testANotDoneDayIsEmptyButStillCounts() {
        let today = day(2026, 9, 23)
        let rule = daily(start: day(2026, 9, 20))
        let entries = [day(2026, 9, 20): done, day(2026, 9, 22): done]   // the 21st is not done

        XCTAssertEqual(HabitDayState.missed.label, "not done")
        XCTAssertFalse(HabitDayState.missed.label.lowercased().contains("miss"))
        let summary = HabitLedger.summary(rule, entries: entries, today: today)
        XCTAssertEqual(summary.currentStreak, 1, "the not-done 21st ends the run at the 22nd")
        XCTAssertEqual(summary.rateDone, 2)
        XCTAssertEqual(summary.rateCounted, 3, "the not-done day is in the denominator")
    }

    /// The section shows seven days, so the rate is over those same seven days
    /// and nothing older. Misses before the window must not pull it down.
    func testTheRateCoversTheSevenDaysOnScreen() {
        let today = day(2026, 9, 25)
        let rule = daily(start: day(2026, 9, 1))
        var entries: [Date: HabitDayEntry] = [:]
        // 1-18: nothing (18 misses, all outside the window).
        // 19-24: done, done, skipped, done, missed, done. Today: open.
        for d in [19, 20, 22, 24] { entries[day(2026, 9, d)] = done }
        entries[day(2026, 9, 21)] = skip

        let summary = HabitLedger.summary(rule, entries: entries, today: today)
        XCTAssertEqual(summary.rateDone, 4)
        XCTAssertEqual(summary.rateCounted, 5, "19-24 less the skip; today is still open")
        XCTAssertEqual(summary.rate ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(
            HabitLedger.days(endingOn: today, count: 7),
            (19...25).map { day(2026, 9, $0) },
            "the strip is the last seven days ending today, today on the right"
        )
    }

    // MARK: - Extra days

    /// A done check on a day that is not due is an extra day. It never counts
    /// as a miss when empty, does not break a streak, does not extend it, and
    /// stays out of the rate. (Decision: an extra day is NEUTRAL for the streak.)
    func testAnExtraDayIsNeutral() {
        let mwf = (1 << 1) | (1 << 3) | (1 << 5)
        let rule = HabitRule(schedule: .weekdays, weekdayMask: mwf, targetCount: 1, startDay: day(2026, 9, 14))
        let today = day(2026, 9, 19)   // Saturday
        var entries = [day(2026, 9, 14): done, day(2026, 9, 16): done, day(2026, 9, 18): done]
        let before = HabitLedger.summary(rule, entries: entries, today: today)

        entries[day(2026, 9, 15)] = done   // Tuesday: not due
        entries[today] = done              // Saturday: not due
        XCTAssertEqual(HabitLedger.state(rule, entry: entries[day(2026, 9, 15)], on: day(2026, 9, 15), today: today), .extra)
        XCTAssertTrue(HabitDayState.extra.isChecked)
        let after = HabitLedger.summary(rule, entries: entries, today: today)
        XCTAssertEqual(after.currentStreak, before.currentStreak, "an extra day neither extends nor breaks the streak")
        XCTAssertEqual(after.rateDone, before.rateDone)
        XCTAssertEqual(after.rateCounted, before.rateCounted, "an extra day is outside the rate")
        XCTAssertEqual(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 17), today: today), .unscheduled,
                       "an empty day that is not due is never missed")
    }

    func testEveryDayUpToTodayIsLoggable() {
        let rule = daily(start: day(2026, 9, 25))
        let today = day(2026, 9, 25)
        XCTAssertTrue(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 20), today: today).isLoggable,
                      "a day before the start can be backfilled")
        XCTAssertTrue(HabitLedger.state(rule, entry: nil, on: today, today: today).isLoggable)
        XCTAssertFalse(HabitLedger.state(rule, entry: nil, on: day(2026, 9, 26), today: today).isLoggable)
    }

    // MARK: - Months

    func testAMonthCountsDoneAndSkipped() {
        let rule = daily(start: day(2026, 8, 1))
        let today = day(2026, 9, 25)
        var entries: [Date: HabitDayEntry] = [:]
        for d in 1...31 where ![5, 6, 7].contains(d) { entries[day(2026, 8, d)] = done }
        entries[day(2026, 8, 7)] = skip   // 5th and 6th stay empty: missed

        let august = HabitLedger.monthSummary(rule, entries: entries, month: day(2026, 8, 15), today: today)
        XCTAssertEqual(august.done, 28)
        XCTAssertEqual(august.skipped, 1)
        XCTAssertEqual(august.counted, 30, "the skip is out of the rate")
        XCTAssertEqual(august.rate ?? -1, 28.0 / 30.0, accuracy: 0.0001)
    }

    func testTheCurrentMonthCountsOnlyUpToToday() {
        let rule = daily(start: day(2026, 9, 1))
        let today = day(2026, 9, 10)
        var entries: [Date: HabitDayEntry] = [:]
        for d in 1...8 { entries[day(2026, 9, d)] = done }   // 9th missed, today open

        let september = HabitLedger.monthSummary(rule, entries: entries, month: today, today: today)
        XCTAssertEqual(september.done, 8)
        XCTAssertEqual(
            notDoneCount(rule, entries: entries, from: day(2026, 9, 1), today: today), 1,
            "only the 9th is not done; the 11th to the 30th have not happened"
        )
        XCTAssertEqual(september.counted, 9, "today is still open")
    }

    func testAMonthBeforeTheStartHasNoMisses() {
        let rule = daily(start: day(2026, 9, 10))
        let july = HabitLedger.monthSummary(rule, entries: [:], month: day(2026, 7, 1), today: day(2026, 9, 25))
        XCTAssertEqual(july, HabitMonthSummary())
        XCTAssertNil(july.rate)
    }

    func testMonthNavigationBounds() {
        let rule = daily(start: day(2026, 9, 10))
        let entries = [day(2026, 6, 3): done]
        XCTAssertEqual(HabitLedger.earliestMonth(rule, entries: entries), day(2026, 6, 1),
                       "the earliest check-in wins over a later start day")
        XCTAssertEqual(HabitLedger.month(-1, from: day(2026, 3, 31)), day(2026, 2, 1))
        XCTAssertEqual(HabitLedger.daysInMonth(of: day(2026, 2, 14)).count, 28)
        XCTAssertEqual(HabitLedger.daysInMonth(of: day(2026, 9, 14)).first, day(2026, 9, 1))
    }

    func testANewHabitHasNoRateYet() {
        let today = day(2026, 9, 20)
        let summary = HabitLedger.summary(daily(start: today), entries: [:], today: today)
        XCTAssertNil(summary.rate, "a habit started today has nothing to judge yet")
        XCTAssertEqual(summary.currentStreak, 0)
    }

    func testGroupingKeysByHabitAndAnchoredDay() {
        let d = day(2026, 9, 20)
        let grouped = HabitLedger.group([
            (habitUUID: "a", day: d, entry: done),
            (habitUUID: "a", day: day(2026, 9, 19), entry: skip),
            (habitUUID: "b", day: d, entry: done),
        ])
        XCTAssertEqual(grouped["a"]?.count, 2)
        XCTAssertEqual(grouped["b"]?[d], done)
    }
}
