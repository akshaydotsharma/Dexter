import XCTest
@testable import PersonalDashboard

/// The midnight convention that lets a task be due on a DAY (#657).
final class TaskDueTimeTests: XCTestCase {

    private let calendar = Calendar.current

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - isSet

    func test_midnight_reads_as_no_time() {
        XCTAssertFalse(TaskDueTime.isSet(on: date(2026, 9, 24)))
    }

    func test_any_other_moment_reads_as_a_time() {
        XCTAssertTrue(TaskDueTime.isSet(on: date(2026, 9, 24, 0, 1)))
        XCTAssertTrue(TaskDueTime.isSet(on: date(2026, 9, 24, 14, 30)))
        XCTAssertTrue(TaskDueTime.isSet(on: date(2026, 9, 24, 23, 59)))
    }

    // MARK: - normalised

    func test_without_a_time_the_hour_is_dropped_to_midnight() {
        let written = TaskDueTime.normalised(date(2026, 9, 24, 14, 30), hasTime: false)
        XCTAssertEqual(written, date(2026, 9, 24))
        // And it reads back as what it was written to mean.
        XCTAssertFalse(TaskDueTime.isSet(on: written))
    }

    func test_with_a_time_the_hour_is_kept_at_minute_precision() {
        let messy = date(2026, 9, 24, 14, 30).addingTimeInterval(37.482)
        let written = TaskDueTime.normalised(messy, hasTime: true)
        XCTAssertEqual(written, date(2026, 9, 24, 14, 30))
        XCTAssertTrue(TaskDueTime.isSet(on: written))
    }

    /// The one case the convention cannot represent, asserted so it is a
    /// documented cost rather than a surprise.
    func test_a_deliberate_midnight_is_indistinguishable_from_no_time() {
        let written = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        XCTAssertFalse(TaskDueTime.isSet(on: written))
    }

    // MARK: - overdueAfter

    func test_a_timed_task_is_late_at_its_hour() {
        let due = date(2026, 9, 24, 14, 30)
        XCTAssertEqual(TaskDueTime.overdueAfter(due), due)
    }

    /// The whole reason `overdueAfter` exists. Judging a dayless task against
    /// its stored midnight would paint it red from 00:01 on the day it is due.
    func test_a_dayless_task_is_late_only_once_the_day_is_over() {
        let due = date(2026, 9, 24)
        XCTAssertEqual(TaskDueTime.overdueAfter(due), date(2026, 9, 25))

        let middleOfThatDay = date(2026, 9, 24, 13, 0)
        XCTAssertGreaterThan(TaskDueTime.overdueAfter(due), middleOfThatDay)

        let nextMorning = date(2026, 9, 25, 9, 0)
        XCTAssertLessThan(TaskDueTime.overdueAfter(due), nextMorning)
    }
}
