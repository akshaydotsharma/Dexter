import XCTest
import SwiftData
@testable import PersonalDashboard

/// What Delete means for a Planner tile (#687 round 6), and that each choice
/// writes what it says: a planned task offers "remove the plan" AND "delete
/// the task", and the two must not be confused.
@MainActor
final class PlannerDeletionTests: XCTestCase {

    private var store: SwiftDataStore!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private let dayStart = Calendar.current.startOfDay(for: Date())

    private func item(_ origin: PlannerItem.Origin, task: String? = nil, source: PlannerSource = .manual) -> PlannerItem {
        PlannerItem(
            id: "i", title: "Thing", detail: "", source: source,
            start: dayStart.addingTimeInterval(10 * 3600), end: dayStart.addingTimeInterval(11 * 3600),
            durationMinutes: 60, origin: origin, taskUUID: task,
            priority: .none, overdueDays: 0, completed: false
        )
    }

    // MARK: - Choices

    func testAManualBlockHasOneMeaning() {
        XCTAssertEqual(PlannerDeletion.choices(for: item(.block("b"))), [.deleteBlock])
    }

    func testAPlannedTaskOffersRemoveThePlanAndDeleteTheTask() {
        let choices = PlannerDeletion.choices(for: item(.block("b"), task: "t", source: .task))
        XCTAssertEqual(choices, [.removePlan, .deleteTask], "the safe choice first")
        XCTAssertFalse(PlannerDeleteChoice.removePlan.isDestructive, "removing a plan destroys nothing")
        XCTAssertTrue(PlannerDeleteChoice.deleteTask.isDestructive)
        XCTAssertTrue(PlannerDeleteChoice.removePlan.buttonTitle.contains("keep the task"))
    }

    func testATaskShownByItsDueTimeCanOnlyBeDeleted() {
        XCTAssertEqual(PlannerDeletion.choices(for: item(.taskDue, task: "t", source: .task)), [.deleteTask])
    }

    func testACalendarEventHasNoDelete() {
        XCTAssertTrue(PlannerDeletion.choices(for: item(.event(calendarID: "c"), source: .work)).isEmpty)
    }

    func testTheMenuMatchesTheChoices() {
        let block = PlannerTileMenu.entries(for: item(.block("b")), event: nil).compactMap(\.command)
        XCTAssertEqual(block, [.edit, .delete])
        let event = PlannerTileMenu.entries(for: item(.event(calendarID: "c"), source: .work), event: nil)
        XCTAssertTrue(event.isEmpty, "no event, no menu")
    }

    // MARK: - Writes

    private func makeTask(_ title: String) throws -> LocalTodo {
        let t = LocalTodo(title: title)
        store.context.insert(t)
        try store.context.save()
        return t
    }

    private func liveBlocks() throws -> [LocalPlanBlock] {
        try store.context.fetch(FetchDescriptor<LocalPlanBlock>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    func testRemoveThePlanKeepsTheTask() async throws {
        let task = try makeTask("Draft OKRs")
        let id = task.clientUUID.uuidString
        let block = try PlanBlockService(store: store).planTask(
            taskUUID: id, title: task.title,
            start: dayStart.addingTimeInterval(36 * 3600), end: dayStart.addingTimeInterval(37 * 3600)
        )
        let tile = item(.block(block.clientUUID), task: id, source: .task)
        try await PlannerDeletion.perform(.removePlan, for: tile, store: store)
        XCTAssertTrue(try liveBlocks().isEmpty, "the plan is gone")
        XCTAssertNil(task.deletedAt, "the task stays")
    }

    func testDeleteTheTaskSoftDeletesItAndEveryPlanOfIt() async throws {
        let task = try makeTask("Book flights")
        let id = task.clientUUID.uuidString
        let service = PlanBlockService(store: store)
        let block = try service.planTask(
            taskUUID: id, title: task.title,
            start: dayStart.addingTimeInterval(36 * 3600), end: dayStart.addingTimeInterval(37 * 3600)
        )
        // An older plan of the same task, from before today, must go too.
        let old = try service.addManual(title: "old", start: dayStart.addingTimeInterval(-40 * 3600), end: dayStart.addingTimeInterval(-39 * 3600))
        old.kind = block.kind
        old.taskUUID = id
        let other = try service.addManual(title: "Gym", start: dayStart.addingTimeInterval(40 * 3600), end: dayStart.addingTimeInterval(41 * 3600))
        try store.context.save()

        try await PlannerDeletion.perform(.deleteTask, for: item(.block(block.clientUUID), task: id, source: .task), store: store)
        XCTAssertNotNil(task.deletedAt, "the task is soft-deleted, so the delete syncs")
        XCTAssertEqual(try liveBlocks().map(\.clientUUID), [other.clientUUID], "every plan of the task goes; other blocks stay")
    }

    func testDeleteBlockDeletesOnlyThatBlock() async throws {
        let service = PlanBlockService(store: store)
        let a = try service.addManual(title: "A", start: dayStart.addingTimeInterval(9 * 3600), end: dayStart.addingTimeInterval(10 * 3600))
        let b = try service.addManual(title: "B", start: dayStart.addingTimeInterval(11 * 3600), end: dayStart.addingTimeInterval(12 * 3600))
        try await PlannerDeletion.perform(.deleteBlock, for: item(.block(a.clientUUID)), store: store)
        XCTAssertEqual(try liveBlocks().map(\.clientUUID), [b.clientUUID])
        XCTAssertNotNil(a.deletedAt, "a soft delete, so it reaches a peer")
    }
}
