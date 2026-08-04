import XCTest
@testable import PersonalDashboard

/// Which tasks earn a pending reminder, and whether the flag survives a round trip
/// through the archive (#444).
///
/// Both halves are here because both are silent when wrong. A bad eligibility rule
/// produces a banner for a task you finished last week, or no banner at all for one
/// you armed — neither shows up in a build or in a screenshot. And the archive DTO
/// is what sync ships, so a field missing from it means a reminder armed on the
/// phone quietly does not exist on the Mac.
@MainActor
final class TaskReminderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var future: Date { now.addingTimeInterval(3600) }
    private var past: Date { now.addingTimeInterval(-3600) }

    // MARK: - Eligibility

    func testArmsWhenFlaggedWithAFutureDueDate() {
        XCTAssertTrue(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: nil, dueDate: future, now: now
        ))
    }

    /// The default. Every existing task and every task the AI creates lands here.
    func testDoesNotArmWhenNotFlagged() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: false, completed: false, deletedAt: nil, dueDate: future, now: now
        ))
    }

    /// The flag with nothing to fire against. Reachable from a peer on an older
    /// build, or from clearing a due date by a path that forgets the invariant.
    func testDoesNotArmWithoutADueDate() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: nil, dueDate: nil, now: now
        ))
    }

    /// The one that would be most annoying in practice: finishing something and
    /// then being told about it anyway.
    func testDoesNotArmForACompletedTask() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: true, deletedAt: nil, dueDate: future, now: now
        ))
    }

    func testDoesNotArmForASoftDeletedTask() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: now, dueDate: future, now: now
        ))
    }

    /// A moment that has gone cannot be scheduled, so it must not be counted as
    /// armed either — otherwise the reconcile keeps trying to add a request the OS
    /// will never hold.
    func testDoesNotArmForAPastDueDate() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: nil, dueDate: past, now: now
        ))
    }

    /// The boundary itself. Exactly-now has passed by the time anything could fire.
    func testDoesNotArmWhenDueExactlyNow() {
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: nil, dueDate: now, now: now
        ))
    }

    // MARK: - The fire instant (#444 follow-up)

    /// The reported bug. The picker only shows hours and minutes, but the `Date`
    /// behind it keeps the seconds it was seeded with, so a reminder set for 4:28 PM
    /// was scheduled for 4:28:44 and read as arriving late for no visible reason.
    ///
    /// Real numbers from the store: the task was due `2026-08-04 16:28:44`.
    func testFireInstantDropsTheSecondsThePickerNeverShowed() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let due = cal.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 16, minute: 28, second: 44
        ))!

        let fire = TaskReminderScheduler.fireDate(for: due)
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: fire)

        XCTAssertEqual(parts.second, 0, "4:28 PM means the moment 4:28 begins")
        XCTAssertEqual(parts.minute, 28)
        XCTAssertEqual(fire, due.addingTimeInterval(-44))
    }

    /// Truncating must not move a reminder into a different minute.
    func testFireInstantLeavesAnAlreadyExactTimeAlone() {
        let exact = Calendar.current.date(
            from: DateComponents(year: 2026, month: 8, day: 4, hour: 9, minute: 5, second: 0)
        )!
        XCTAssertEqual(TaskReminderScheduler.fireDate(for: exact), exact)
    }

    /// The trap the truncation opens if the eligibility check is left behind:
    /// a due date whose seconds are still ahead of now, but whose minute has
    /// already begun. Arming that would schedule a moment in the past, which the
    /// OS accepts and then never delivers — a reminder that is armed and silent.
    func testDoesNotArmWhenOnlyTheStraySecondsAreStillInTheFuture() {
        let cal = Calendar.current
        let minuteStart = cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: now))!
        let dueLaterThisMinute = minuteStart.addingTimeInterval(50)
        let nowEarlierThisMinute = minuteStart.addingTimeInterval(20)

        XCTAssertGreaterThan(dueLaterThisMinute, nowEarlierThisMinute, "precondition: raw due date is still ahead")
        XCTAssertFalse(TaskReminderScheduler.shouldArm(
            remindMe: true, completed: false, deletedAt: nil,
            dueDate: dueLaterThisMinute, now: nowEarlierThisMinute
        ), "the minute it would fire in has already started, so there is nothing to schedule")
    }

    // MARK: - The row affordance

    /// The bell is keyed on the same pairing the scheduler requires, so a flag with
    /// no date never advertises a reminder that cannot exist.
    func testArmedReminderNeedsBothFlagAndDate() {
        XCTAssertTrue(todo(remindMe: true, dueDate: future).hasArmedReminder)
        XCTAssertFalse(todo(remindMe: true, dueDate: nil).hasArmedReminder)
        XCTAssertFalse(todo(remindMe: false, dueDate: future).hasArmedReminder)
    }

    // MARK: - Archive round trip (this is also the sync payload)

    func testArchiveCarriesTheFlag() throws {
        let dto = DataArchive.TaskDTO(
            clientUUID: UUID(),
            title: "Call the bank",
            description: nil,
            completed: false,
            dueDate: future,
            tag: nil,
            position: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil,
            priority: 0,
            address: nil,
            googleMapsLink: nil,
            remindMe: true
        )

        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(DataArchive.TaskDTO.self, from: data)

        XCTAssertEqual(decoded.remindMe, true, "a reminder armed here must exist on the other device")
    }

    /// An archive written before #444 has no such key. It must still decode, and it
    /// must restore as disarmed rather than failing the whole import.
    func testArchiveWithoutTheFieldStillDecodes() throws {
        let json = """
        {
          "clientUUID": "\(UUID().uuidString)",
          "title": "Older archive",
          "completed": false,
          "createdAt": 0,
          "updatedAt": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DataArchive.TaskDTO.self, from: json)

        XCTAssertNil(decoded.remindMe)
        XCTAssertFalse(
            TaskReminderScheduler.shouldArm(
                remindMe: decoded.remindMe ?? false,
                completed: decoded.completed,
                deletedAt: decoded.deletedAt,
                dueDate: decoded.dueDate,
                now: now
            ),
            "a task restored from an older archive is disarmed, which is the default"
        )
    }

    // MARK: - Helpers

    private func todo(remindMe: Bool, dueDate: Date?) -> Todo {
        Todo(
            id: UUID(),
            title: "T",
            description: nil,
            completed: false,
            dueDate: dueDate,
            tag: nil,
            position: nil,
            version: 0,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil,
            address: "",
            googleMapsLink: "",
            priority: 0,
            remindMe: remindMe
        )
    }
}
