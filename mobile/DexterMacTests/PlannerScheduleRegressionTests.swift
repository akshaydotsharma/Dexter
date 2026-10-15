import XCTest
import SwiftData
@testable import DexterMac

@MainActor
final class PlannerScheduleRegressionTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return value
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func block(on day: Int) -> PlannerBlock {
        PlannerBlock(id: "plan", kind: .task, title: "Compare cities", day: date(day),
                     start: date(day, 18), end: date(day, 18, 30), durationMinutes: 30, taskUUID: "task")
    }

    func testMovingToNextDayDoesNotExposeTheOldDeadlineTile() {
        let task = PlannerTask(id: "task", title: "Compare cities", priority: .none, due: date(14, 18), completed: false)
        let old = PlannerEngine.day(date(14), events: [], blocks: [block(on: 15)], tasks: [task], now: date(15), calendar: calendar)
        let next = PlannerEngine.day(date(15), events: [], blocks: [block(on: 15)], tasks: [task], now: date(15), calendar: calendar)
        XCTAssertTrue(old.all.isEmpty, "the original due date must not render a second placement")
        XCTAssertEqual(next.all.count, 1)
        XCTAssertEqual(next.timed.first?.start, date(15, 18))
        XCTAssertEqual(next.timed.first?.end, date(15, 18, 30))
        XCTAssertFalse(next.all.contains { $0.overdueDays > 0 })
        XCTAssertEqual(task.due, date(14, 18), "moving a plan does not edit the Tasks deadline")
        let history = PlannerEngine.day(date(14), events: [], blocks: [block(on: 15)], tasks: [task], now: date(16), calendar: calendar)
        XCTAssertTrue(history.all.isEmpty, "the old deadline must not reappear when the planned day passes")
    }

    func testHistoricalPlanDoesNotHideANewFutureDeadline() {
        let task = PlannerTask(id: "task", title: "Compare cities", priority: .none, due: date(16, 18), completed: false)
        let future = PlannerEngine.day(date(16), events: [], blocks: [block(on: 14)], tasks: [task], now: date(15), calendar: calendar)
        XCTAssertEqual(future.timed.first?.id, "d-task")
    }

    func testRemovingAPlanRestoresDeadlineFallback() {
        let task = PlannerTask(id: "task", title: "Compare cities", priority: .none, due: date(14, 18), completed: false)
        let day = PlannerEngine.day(date(14), events: [], blocks: [], tasks: [task], now: date(15), calendar: calendar)
        XCTAssertEqual(day.timed.first?.start, date(14, 18))
    }

    func testReturnToPlanClearsDateAndReminderAndKeepsTaskAndHistory() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = PlanBlockService(store: store)
        let today = Calendar.current.startOfDay(for: Date())
        let start = today.addingTimeInterval(18 * 3600)
        let task = LocalTodo(title: "Compare cities", dueDate: start, remindMe: true)
        task.todoDescription = "Keep this note"
        task.priority = 1
        store.context.insert(task)
        let historical = try service.addManual(title: task.title, start: today.addingTimeInterval(-86400 + 3600), end: today.addingTimeInterval(-86400 + 7200))
        historical.taskUUID = task.clientUUID.uuidString
        historical.kind = PlanBlockKind.task.rawValue
        let plan = try service.planTask(taskUUID: task.clientUUID.uuidString, title: task.title, start: start, end: start.addingTimeInterval(1800))
        try service.returnToPlan(taskUUID: task.clientUUID.uuidString, blockID: plan.clientUUID)
        let persisted = try XCTUnwrap(store.context.fetch(FetchDescriptor<LocalTodo>()).first)
        XCTAssertNil(persisted.dueDate)
        XCTAssertFalse(persisted.remindMe)
        XCTAssertNil(persisted.deletedAt)
        XCTAssertFalse(persisted.completed)
        XCTAssertEqual(persisted.todoDescription, "Keep this note")
        XCTAssertEqual(persisted.priority, 1)
        XCTAssertNotNil(try service.block(id: plan.clientUUID)?.deletedAt)
        XCTAssertNil(try service.block(id: historical.clientUUID)?.deletedAt)
        XCTAssertEqual(plan.durationMinutes, 30, "retain the historical block metadata")
    }

    func testReturnOfDueOnlyTaskClearsDateWithoutCreatingAPlan() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = PlanBlockService(store: store)
        let task = LocalTodo(title: "Due only", dueDate: Date())
        store.context.insert(task)
        try store.context.save()
        try service.returnToPlan(taskUUID: task.clientUUID.uuidString)
        XCTAssertNil(task.dueDate)
        XCTAssertTrue(try service.liveBlocks().isEmpty)
    }

    func testReturnRefusesCompletedDeletedAndMissingTasks() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = PlanBlockService(store: store)
        for completed in [false, true] {
            let task = LocalTodo(title: "Keep", dueDate: date(15, 18))
            task.completed = completed
            if !completed { task.deletedAt = Date() }
            store.context.insert(task)
            try store.context.save()
            try service.returnToPlan(taskUUID: task.clientUUID.uuidString)
            XCTAssertEqual(task.dueDate, date(15, 18))
        }
        try service.returnToPlan(taskUUID: UUID().uuidString)
        XCTAssertTrue(try service.liveBlocks().isEmpty)
    }

    func testDateEditRoundTripKeepsTheChosenInstantAndLength() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = PlanBlockService(store: store)
        let plan = try service.addManual(title: "Compare cities", start: date(14, 18), end: date(14, 18, 30))
        // Same date-and-time composition as the editor's day binding.
        let time = calendar.dateComponents([.hour, .minute], from: plan.start!)
        let chosen = calendar.date(bySettingHour: time.hour!, minute: time.minute!, second: 0, of: date(15))!
        let end = chosen.addingTimeInterval(plan.end!.timeIntervalSince(plan.start!))
        try service.update(plan, title: plan.title, start: chosen, end: end, day: date(15), durationMinutes: 30)
        let saved = try XCTUnwrap(service.block(id: plan.clientUUID))
        XCTAssertEqual(saved.start, date(15, 18))
        XCTAssertEqual(saved.end, date(15, 18, 30))
        XCTAssertEqual(saved.day, WallClock.dayAnchor(from: chosen))
    }
}
