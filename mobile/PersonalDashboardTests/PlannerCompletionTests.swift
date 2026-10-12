import XCTest
import SwiftData
@testable import PersonalDashboard

/// Mark complete / Mark incomplete from the Planner (#695): which tiles offer
/// it, that it writes through the Tasks section's own path, and that a
/// completed recurring occurrence releases its next one exactly as it does
/// when ticked in Tasks.
@MainActor
final class PlannerCompletionTests: XCTestCase {

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

    private func item(_ origin: PlannerItem.Origin, task: String? = nil, source: PlannerSource = .manual,
                      timed: Bool = true, completed: Bool = false) -> PlannerItem {
        PlannerItem(
            id: "i", title: "Thing", detail: "", source: source,
            start: timed ? dayStart.addingTimeInterval(10 * 3600) : nil,
            end: timed ? dayStart.addingTimeInterval(11 * 3600) : nil,
            durationMinutes: 60, origin: origin, taskUUID: task,
            priority: .none, overdueDays: 0, completed: completed
        )
    }

    private func event(_ decline: PlannerDeclineState = .none) -> PlannerEvent {
        PlannerEvent(id: "e", title: "Standup", location: "", calendarID: "c", calendarTitle: "Work",
                     source: .work, start: dayStart, end: dayStart.addingTimeInterval(1800), isAllDay: false,
                     decline: decline)
    }

    // MARK: - Which tiles offer it

    func testATimedTaskOffersMarkCompleteFirst() {
        let entries = PlannerTileMenu.entries(for: item(.taskDue, task: "t", source: .task), event: nil)
        XCTAssertEqual(entries.first?.command, .toggleComplete)
        XCTAssertEqual(entries.first?.title, "Mark complete")
    }

    func testACompletedTaskOffersMarkIncomplete() {
        let entries = PlannerTileMenu.entries(for: item(.taskDue, task: "t", source: .task, completed: true), event: nil)
        XCTAssertEqual(entries.first?.title, "Mark incomplete")
        XCTAssertEqual(entries.first?.command, .toggleComplete)
    }

    func testAPlannedTaskBlockAndAnAllDayPillOfferIt() {
        let block = PlannerTileMenu.entries(for: item(.block("b"), task: "t", source: .task), event: nil)
        XCTAssertEqual(block.compactMap(\.command), [.toggleComplete, .edit, .delete])
        let pill = PlannerTileMenu.entries(for: item(.taskDue, task: "t", source: .task, timed: false), event: nil)
        XCTAssertEqual(pill.first?.command, .toggleComplete)
    }

    func testAManualBlockWithNoTaskDoesNotOfferIt() {
        let commands = PlannerTileMenu.entries(for: item(.block("b")), event: nil).compactMap(\.command)
        XCTAssertFalse(commands.contains(.toggleComplete))
        XCTAssertEqual(commands, [.edit, .delete])
        XCTAssertNil(PlannerTileMenu.completeEntry(for: item(.block("b"), task: "")))
    }

    func testACalendarEventDoesNotOfferIt() {
        let ev = item(.event(calendarID: "c"), source: .work)
        let commands = PlannerTileMenu.entries(for: ev, event: event()).flatMap { [$0] + $0.children }.compactMap(\.command)
        XCTAssertFalse(commands.contains(.toggleComplete))
        XCTAssertFalse(PlannerTileMenu.canComplete(ev))
    }

    func testAToPlanRowOffersItFirst() {
        let open = PlannerTileMenu.toPlanEntries(for: PlannerTask(id: "t", title: "t", priority: .none, due: nil, completed: false))
        XCTAssertEqual(open.compactMap(\.command), [.toggleComplete, .edit, .delete])
        XCTAssertEqual(open.first?.title, "Mark complete")
    }

    // MARK: - The grid keeps a completed task on its day

    func testATaskCompletedOnItsDueDayStaysOnThatDayDimmed() {
        let cal = Calendar.current
        let tasks = [PlannerTask(id: "t", title: "Pay card", priority: .none, due: dayStart, completed: true)]
        let d = PlannerEngine.day(dayStart, events: [], blocks: [], tasks: tasks,
                                  now: dayStart.addingTimeInterval(10 * 3600), calendar: cal)
        XCTAssertEqual(d.allDay.map(\.title), ["Pay card"])
        XCTAssertTrue(d.allDay[0].completed, "drawn completed, so it can be undone from the Planner")
    }

    // MARK: - Writes

    private func makeTask(_ title: String) throws -> LocalTodo {
        let t = LocalTodo(title: title)
        store.context.insert(t)
        try store.context.save()
        return t
    }

    func testCompleteThenUndo() async throws {
        let task = try makeTask("Draft OKRs")
        let id = task.clientUUID.uuidString
        let changed = try await PlannerCompletion.set(id, completed: true, store: store)
        XCTAssertTrue(changed)
        XCTAssertTrue(task.completed)
        try await PlannerCompletion.set(id, completed: false, store: store)
        XCTAssertFalse(task.completed, "undo reopens it")
    }

    func testSettingTheSameStateTwiceDoesNotFlipItBack() async throws {
        let task = try makeTask("Draft OKRs")
        let id = task.clientUUID.uuidString
        try await PlannerCompletion.set(id, completed: true, store: store)
        let again = try await PlannerCompletion.set(id, completed: true, store: store)
        XCTAssertFalse(again)
        XCTAssertTrue(task.completed, "a second Mark complete from a stale tile must not reopen it")
    }

    func testCompletingARecurringOccurrenceReleasesTheNextOne() async throws {
        let today = Date(timeIntervalSince1970: 1_789_000_000)
        let recurring = RecurringTaskService(store: store)
        try recurring.create(title: "Take the bins out", frequency: .daily, leadDays: 3, startDate: today)
        recurring.materialize(reference: today)
        let open = try store.context.fetch(FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.completed == false }))
        XCTAssertEqual(open.count, 1)

        try await PlannerCompletion.set(open[0].clientUUID.uuidString, completed: true, store: store)
        let next = recurring.materialize(reference: Calendar.current.date(byAdding: .day, value: 1, to: today)!)
        XCTAssertEqual(next.count, 1, "the same release as completing it in Tasks")
    }
}
