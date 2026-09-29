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

    /// #683. A deliberate 12:00 AM used to be stored at exactly midnight and so
    /// read back as "no time". It is now stored one second past midnight, which
    /// keeps it a TIME while staying inside the 12:00 AM minute.
    func test_a_deliberate_midnight_reads_back_as_a_time() {
        let written = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        XCTAssertTrue(TaskDueTime.isSet(on: written))
        XCTAssertEqual(written, date(2026, 9, 24).addingTimeInterval(TaskDueTime.deliberateMidnightOffset))
        // Still the same minute, so every display prints 12:00 AM on that day.
        XCTAssertEqual(WallClock.minutePrecision(written), date(2026, 9, 24))
        XCTAssertEqual(calendar.component(.day, from: written), 24)
    }

    /// Stray seconds inside the midnight minute (a picker seeded with them)
    /// land on the same sentinel, not on midnight.
    func test_seconds_inside_the_midnight_minute_still_read_as_a_time() {
        let messy = date(2026, 9, 24).addingTimeInterval(42.7)
        let written = TaskDueTime.normalised(messy, hasTime: true)
        XCTAssertEqual(written, date(2026, 9, 24).addingTimeInterval(TaskDueTime.deliberateMidnightOffset))
        XCTAssertTrue(TaskDueTime.isSet(on: written))
    }

    /// The editor re-saves what it read. A 12:00 AM task opened and saved again
    /// must not drift, and a dayless one must stay dayless.
    func test_resaving_is_stable_for_both_midnight_meanings() {
        let timed = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        let reopenedTimed = TaskDueTime.isSet(on: timed)
        XCTAssertEqual(TaskDueTime.normalised(timed, hasTime: reopenedTimed), timed)

        let dayless = TaskDueTime.normalised(date(2026, 9, 24), hasTime: false)
        let reopenedDayless = TaskDueTime.isSet(on: dayless)
        XCTAssertFalse(reopenedDayless)
        XCTAssertEqual(TaskDueTime.normalised(dayless, hasTime: reopenedDayless), dayless)
    }

    /// Switching Time off on a 12:00 AM task drops it back to the day.
    func test_turning_time_off_on_a_midnight_task_makes_it_dayless() {
        let timed = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        let dayless = TaskDueTime.normalised(timed, hasTime: false)
        XCTAssertEqual(dayless, date(2026, 9, 24))
        XCTAssertFalse(TaskDueTime.isSet(on: dayless))
    }

    /// Row and calendar print hours and minutes, so the one second never shows.
    func test_a_deliberate_midnight_prints_as_12_00_am() {
        let written = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        let style = Date.FormatStyle.dateTime.hour().minute().locale(Locale(identifier: "en_US"))
        XCTAssertEqual(written.formatted(style), date(2026, 9, 24).formatted(style))
        XCTAssertTrue(written.formatted(style).hasPrefix("12:00"))
    }

    /// The reminder fires at the start of the minute, so at midnight itself.
    @MainActor
    func test_a_deliberate_midnight_reminder_fires_at_midnight() {
        let written = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        XCTAssertEqual(TaskReminderScheduler.fireDate(for: written), date(2026, 9, 24))
    }

    /// A 12:00 AM task is late from its minute, not from the end of the day.
    func test_a_deliberate_midnight_is_late_at_midnight() {
        let written = TaskDueTime.normalised(date(2026, 9, 24), hasTime: true)
        XCTAssertEqual(TaskDueTime.overdueAfter(written), written)
    }

    // MARK: - repairedDeliberateMidnight (rows written before #683)

    func test_an_armed_midnight_row_is_repaired_to_a_time() {
        let repaired = TaskDueTime.repairedDeliberateMidnight(date(2026, 10, 8), remindMe: true)
        XCTAssertEqual(repaired, TaskDueTime.normalised(date(2026, 10, 8), hasTime: true))
        XCTAssertTrue(TaskDueTime.isSet(on: repaired!))
    }

    func test_an_unarmed_midnight_row_stays_dayless() {
        XCTAssertNil(TaskDueTime.repairedDeliberateMidnight(date(2026, 10, 8), remindMe: false))
    }

    func test_timed_and_dateless_rows_are_left_alone() {
        XCTAssertNil(TaskDueTime.repairedDeliberateMidnight(date(2026, 10, 8, 9, 30), remindMe: true))
        XCTAssertNil(TaskDueTime.repairedDeliberateMidnight(nil, remindMe: true))
        let sentinel = TaskDueTime.normalised(date(2026, 10, 8), hasTime: true)
        XCTAssertNil(TaskDueTime.repairedDeliberateMidnight(sentinel, remindMe: true))
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
