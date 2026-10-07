import XCTest
@testable import PersonalDashboard

/// #693: which tiles move on the grid, and which All Day pills drag onto it.
/// Dexter owns tasks and manual blocks; calendar events stay read-only.
final class PlannerMoveRulesTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_790_000_000)

    private func item(_ origin: PlannerItem.Origin, source: PlannerSource, timed: Bool,
                      task: String? = nil, completed: Bool = false) -> PlannerItem {
        PlannerItem(
            id: UUID().uuidString, title: "x", detail: "", source: source,
            start: timed ? nine : nil, end: timed ? nine.addingTimeInterval(1800) : nil,
            durationMinutes: timed ? 30 : 0, origin: origin, taskUUID: task,
            priority: .none, overdueDays: 0, completed: completed
        )
    }

    func testDexterTilesMoveAndCalendarEventsDoNot() {
        XCTAssertTrue(PlannerDayColumn.isMovable(item(.block("b"), source: .manual, timed: true)))
        XCTAssertTrue(PlannerDayColumn.isMovable(item(.block("b"), source: .task, timed: true, task: "t")))
        XCTAssertTrue(PlannerDayColumn.isMovable(item(.taskDue, source: .task, timed: true, task: "t")))
        XCTAssertFalse(PlannerDayColumn.isMovable(item(.event(calendarID: "c"), source: .work, timed: true)))
        XCTAssertFalse(PlannerDayColumn.isMovable(item(.event(calendarID: "c"), source: .personal, timed: true)))
    }

    func testOnlyDayLessDexterTasksDragFromAllDay() {
        XCTAssertTrue(PlannerAllDayRow.isDraggable(item(.taskDue, source: .task, timed: false, task: "t")))
        XCTAssertTrue(PlannerAllDayRow.isDraggable(item(.block("b"), source: .task, timed: false, task: "t")),
                      "a task planned to the day with no hour")
        XCTAssertFalse(PlannerAllDayRow.isDraggable(item(.event(calendarID: "c"), source: .work, timed: false)),
                       "an all-day calendar event")
        XCTAssertFalse(PlannerAllDayRow.isDraggable(item(.block("b"), source: .manual, timed: false)),
                       "a manual block with no hour")
        XCTAssertFalse(PlannerAllDayRow.isDraggable(item(.taskDue, source: .task, timed: false, task: "t", completed: true)))
        XCTAssertFalse(PlannerAllDayRow.isDraggable(item(.taskDue, source: .task, timed: true, task: "t")),
                       "a timed task is on the grid already")
    }
}
