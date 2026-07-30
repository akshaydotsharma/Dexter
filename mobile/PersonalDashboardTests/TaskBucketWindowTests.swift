import XCTest
@testable import PersonalDashboard

/// Which section of the Tasks list a due date lands in (#418).
///
/// Worth its own file because the bug was invisible on every day except the ones
/// near the end of a week: `weekEnd` was `today + 7 days`, so on Friday 31 July a
/// task due Thursday 6 August read as **This Week**. Pure date arithmetic with a
/// locale-sensitive edge, which is exactly the shape that should not be sitting
/// untested inside a view.
final class TaskBucketWindowTests: XCTestCase {

    /// Fixed calendar so a test never depends on where the machine thinks it is.
    /// `firstWeekday` is varied deliberately below — that is half the point.
    private func calendar(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = firstWeekday
        return cal
    }

    /// A date at noon, so nothing here is decided by a start-of-day boundary.
    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, in cal: Calendar) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))!
    }

    // MARK: - The reported bug

    /// Friday 31 July 2026, the day it was reported. Thursday 6 August is next week.
    func testTaskNextThursdayIsLaterNotThisWeek() {
        let cal = calendar(firstWeekday: 1)
        let window = TaskBucketWindow(now: day(2026, 7, 31, in: cal), calendar: cal)

        XCTAssertEqual(window.bucket(for: day(2026, 8, 6, in: cal)), .later,
                       "Thursday 6 August is next week, whatever the section used to say")
    }

    /// The other half of the same day: Sunday still closes this week.
    func testSundayIsStillThisWeek() {
        let cal = calendar(firstWeekday: 1)
        let window = TaskBucketWindow(now: day(2026, 7, 31, in: cal), calendar: cal)

        XCTAssertEqual(window.bucket(for: day(2026, 8, 2, in: cal)), .thisWeek)
        XCTAssertEqual(window.bucket(for: day(2026, 8, 3, in: cal)), .later,
                       "Monday starts the next week")
    }

    /// Today and Tomorrow are unchanged, and they win over This Week for their days.
    func testTodayAndTomorrowOutrankThisWeek() {
        let cal = calendar(firstWeekday: 1)
        let window = TaskBucketWindow(now: day(2026, 7, 29, in: cal), calendar: cal)  // Wednesday

        XCTAssertEqual(window.bucket(for: day(2026, 7, 28, in: cal)), .overdue)
        XCTAssertEqual(window.bucket(for: day(2026, 7, 29, in: cal)), .today)
        XCTAssertEqual(window.bucket(for: day(2026, 7, 30, in: cal)), .tomorrow)
        XCTAssertEqual(window.bucket(for: day(2026, 7, 31, in: cal)), .thisWeek)
        XCTAssertEqual(window.bucket(for: day(2026, 8, 2, in: cal)), .thisWeek)
        XCTAssertEqual(window.bucket(for: day(2026, 8, 3, in: cal)), .later)
    }

    // MARK: - The locale trap

    /// The week must close on Sunday whatever the device's first weekday is.
    ///
    /// This user's region reports `firstWeekday = 1` (Sunday), which would end the
    /// week on SATURDAY: on a Friday that leaves This Week empty (Saturday is
    /// already Tomorrow) and drops Sunday into Later. Taking the locale's answer
    /// here would have swapped one wrong bucket for another.
    func testWeekEndsOnSundayUnderBothCalendarConventions() {
        for firstWeekday in [1, 2] {
            let cal = calendar(firstWeekday: firstWeekday)
            let window = TaskBucketWindow(now: day(2026, 7, 31, in: cal), calendar: cal)

            XCTAssertEqual(
                window.bucket(for: day(2026, 8, 2, in: cal)), .thisWeek,
                "firstWeekday \(firstWeekday): Sunday belongs to the week it ends"
            )
            XCTAssertEqual(
                window.bucket(for: day(2026, 8, 3, in: cal)), .later,
                "firstWeekday \(firstWeekday): Monday starts the next one"
            )
        }
    }

    // MARK: - Every day of a week

    /// Walk a whole week. For each "today", the boundary must be the next Monday and
    /// This Week must never reach past it — the property the old `+7` broke on five
    /// days out of seven.
    func testWeekEndIsAlwaysTheNextMonday() {
        let cal = calendar(firstWeekday: 1)
        let monday = day(2026, 7, 27, in: cal)
        let expectedStart = cal.startOfDay(for: day(2026, 8, 3, in: cal))

        // Mon 27 Jul 2026 through Sun 2 Aug: every one of them ends on Mon 3 Aug.
        for offset in 0..<7 {
            let today = cal.date(byAdding: .day, value: offset, to: monday)!
            let window = TaskBucketWindow(now: today, calendar: cal)

            XCTAssertEqual(window.weekEnd, expectedStart,
                           "the week containing day \(offset) should end at \(expectedStart)")
        }
    }

    // MARK: - Where a task typed into the section lands

    /// A task created in the This Week section must land in This Week. Seeding it
    /// `today + 3` (the old behaviour) puts it in Later from Thursday onward, so the
    /// row would disappear out of the section as it was created.
    func testSuggestedDayForThisWeekStaysInThisWeek() throws {
        let cal = calendar(firstWeekday: 1)
        for offset in 0..<5 {   // Mon 27 Jul through Fri 31 Jul
            let today = cal.date(byAdding: .day, value: offset, to: day(2026, 7, 27, in: cal))!
            let window = TaskBucketWindow(now: today, calendar: cal)
            let suggested = try XCTUnwrap(window.lastDayOfThisWeek,
                                          "day \(offset) should still have a This Week day")

            XCTAssertEqual(window.bucket(for: suggested), .thisWeek,
                           "a task typed into This Week on day \(offset) must stay there")
        }
    }

    /// From Saturday the section cannot hold anything, and says so rather than
    /// handing back a day in Tomorrow.
    func testThereIsNoThisWeekDayLeftAtTheWeekend() {
        let cal = calendar(firstWeekday: 1)
        XCTAssertNil(TaskBucketWindow(now: day(2026, 8, 1, in: cal), calendar: cal).lastDayOfThisWeek,
                     "Saturday: only Sunday is left and that is Tomorrow")
        XCTAssertNil(TaskBucketWindow(now: day(2026, 8, 2, in: cal), calendar: cal).lastDayOfThisWeek,
                     "Sunday: the week ends today")
    }
}
