import XCTest
import SwiftData
@testable import PersonalDashboard

/// The write side of the Planner (#687): blocks persist, are soft-deleted, are
/// carried by the backup archive and by the sync oplog, and a task has one live
/// plan at a time.
@MainActor
final class PlanBlockPersistenceTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: PlanBlockService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = PlanBlockService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    private func rows() throws -> [LocalPlanBlock] {
        try store.context.fetch(FetchDescriptor<LocalPlanBlock>())
    }

    private func taskRows() throws -> [LocalTodo] {
        try store.context.fetch(FetchDescriptor<LocalTodo>())
    }

    private func todayAt(_ h: Int, _ m: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval((h * 60 + m) * 60))
    }

    // MARK: - Coverage

    /// A model in the store but in no backup and no oplog is the #449 gap.
    func testPlanBlocksAreCarriedByTheArchiveAndSync() {
        XCTAssertTrue(SwiftDataStore.schemaModels.contains { ObjectIdentifier($0) == ObjectIdentifier(LocalPlanBlock.self) }, "not in the schema")
        XCTAssertTrue(DataArchive.exportedModels.contains("LocalPlanBlock"), "LocalPlanBlock is in no backup")
        XCTAssertTrue(SyncRecordMapper.syncedEntities.contains("LocalPlanBlock"), "LocalPlanBlock does not sync")
        XCTAssertNotNil(DataExportService.counts(for: .empty)["LocalPlanBlock"])
        XCTAssertNotNil(DataImportService.actualCounts(for: .empty)["LocalPlanBlock"])
    }

    // MARK: - Writes

    func testQuickAddCreatesATimedManualBlock() throws {
        let parsed = PlannerQuickAdd.parse("Call bank 3:30pm 15m", on: Date())
        let row = try service.add(parsed)
        XCTAssertEqual(row.kindEnum, .manual)
        XCTAssertEqual(row.title, "Call bank")
        XCTAssertEqual(row.start, todayAt(15, 30))
        XCTAssertEqual(row.end, todayAt(15, 45))
        XCTAssertEqual(row.durationMinutes, 15)
        XCTAssertEqual(row.day, WallClock.todayAnchor(), "the day is a UTC anchor (#506)")
        XCTAssertEqual(try rows().count, 1)
    }

    func testADayOnlyBlockHasNoHour() throws {
        let row = try service.addManual(title: "Taxes", day: Date(), durationMinutes: 120)
        XCTAssertFalse(row.isTimed)
        XCTAssertEqual(row.durationMinutes, 120)
        XCTAssertTrue(WallClock.isDayAnchored(row.day))
    }

    func testOptInCreatesOneLinkedTaskWithoutDeadline() throws {
        let start = todayAt(10, 0)
        let end = todayAt(11, 0)
        let block = try service.addManual(title: "  Write proposal  ", start: start, end: end, notes: "Outline", addAsTask: true)
        let tasks = try store.context.fetch(FetchDescriptor<LocalTodo>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(try rows().count, 1)
        XCTAssertEqual(block.kindEnum, .task)
        XCTAssertEqual(block.taskUUID, tasks[0].clientUUID.uuidString)
        XCTAssertEqual(block.title, tasks[0].title)
        XCTAssertEqual(tasks[0].todoDescription, "Outline")
        XCTAssertNil(tasks[0].dueDate)
        XCTAssertEqual(block.start, start)
        XCTAssertEqual(block.end, end)
    }

    func testDayOnlyOptInKeepsPlannedDayAndLength() throws {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Date())!
        let block = try service.addManual(title: "Review budget", day: day, durationMinutes: 75, addAsTask: true)
        let tasks = try store.context.fetch(FetchDescriptor<LocalTodo>())
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].dueDate)
        XCTAssertEqual(block.taskUUID, tasks[0].clientUUID.uuidString)
        XCTAssertEqual(block.day, WallClock.dayAnchor(from: day))
        XCTAssertNil(block.start)
        XCTAssertEqual(block.durationMinutes, 75)
    }

    func testDefaultCreateRemainsPlannerOnly() throws {
        let block = try service.addManual(title: "Focus", start: todayAt(10, 0), end: todayAt(11, 0))
        XCTAssertEqual(block.kindEnum, .manual)
        XCTAssertTrue(block.taskUUID.isEmpty)
        XCTAssertTrue(try store.context.fetch(FetchDescriptor<LocalTodo>()).isEmpty)
    }

    func testTaskOptionRoundTripRetainsTaskIdentityAndMetadata() throws {
        let start = todayAt(10, 0)
        let end = todayAt(11, 0)
        let block = try service.addManual(title: "Review plan", start: start, end: end, notes: "Planner note")
        try service.update(block, title: block.title, start: start, end: end, day: start,
                           durationMinutes: 60, notes: block.notes, addAsTask: true)
        let task = try XCTUnwrap(taskRows().first)
        let id = task.clientUUID
        task.title = "Task edit"
        task.todoDescription = "Task-only note"
        task.priority = 2
        task.completed = true
        task.dueDate = Calendar.current.date(byAdding: .day, value: 3, to: start)
        task.remindMe = true
        try store.context.save()

        try service.update(block, title: task.title, start: start, end: end, day: start,
                           durationMinutes: 60, notes: block.notes, addAsTask: false)
        XCTAssertEqual(block.kindEnum, .manual)
        XCTAssertEqual(block.taskUUID, id.uuidString)
        XCTAssertEqual(block.title, "Task edit")
        XCTAssertNotNil(task.deletedAt)
        XCTAssertTrue(task.completed)
        XCTAssertEqual(task.todoDescription, "Task-only note")

        try service.update(block, title: "Hidden edit", start: nil, end: nil, day: start,
                           durationMinutes: 90, notes: "Changed planner note", addAsTask: false)
        try service.update(block, title: "Hidden edit", start: nil, end: nil, day: start,
                           durationMinutes: 90, notes: block.notes, addAsTask: true)
        XCTAssertEqual(block.kindEnum, .task)
        XCTAssertNil(task.deletedAt)
        XCTAssertEqual(task.title, "Hidden edit")
        XCTAssertEqual(task.todoDescription, "Task-only note")
        XCTAssertEqual(task.priority, 2)
        XCTAssertTrue(task.completed)
        XCTAssertNotNil(task.dueDate)
        XCTAssertTrue(task.remindMe)
        XCTAssertEqual(block.durationMinutes, 90)
        XCTAssertNil(block.start)

        try service.update(block, title: "Hidden edit", start: nil, end: nil, day: start,
                           durationMinutes: 90, addAsTask: false)
        try service.update(block, title: "Hidden edit", start: nil, end: nil, day: start,
                           durationMinutes: 90, addAsTask: true)
        XCTAssertEqual(try taskRows().count, 1)
        XCTAssertEqual(task.clientUUID, id)
        XCTAssertEqual(try rows().count, 1)
    }

    func testToggleChangesEveryLiveBlockButNotDeletedHistory() throws {
        let first = try service.addManual(title: "Write report", start: todayAt(9, 0), end: todayAt(10, 0), addAsTask: true)
        let uuid = first.taskUUID
        let second = LocalPlanBlock(kind: .task, title: first.title, day: first.day,
                                    start: todayAt(13, 0), end: todayAt(14, 0), taskUUID: uuid)
        let deleted = LocalPlanBlock(kind: .task, title: "Old plan", day: first.day,
                                     taskUUID: uuid, deletedAt: Date())
        store.context.insert(second)
        store.context.insert(deleted)
        try store.context.save()

        try service.update(first, title: first.title, start: first.start, end: first.end,
                           day: todayAt(9, 0), durationMinutes: 60, addAsTask: false)
        XCTAssertEqual(first.kindEnum, .manual)
        XCTAssertEqual(second.kindEnum, .manual)
        XCTAssertEqual(deleted.kindEnum, .task)
        XCTAssertEqual(second.start, todayAt(13, 0))
        XCTAssertNotNil(try taskRows().first?.deletedAt)

        try service.update(first, title: "Morning draft", start: first.start, end: first.end,
                           day: todayAt(9, 0), durationMinutes: 60, addAsTask: false)
        try service.update(second, title: "Afternoon draft", start: second.start, end: second.end,
                           day: todayAt(13, 0), durationMinutes: 60, addAsTask: false)
        XCTAssertEqual(first.title, "Morning draft", "saving one hidden block must not rename another")
        XCTAssertEqual(second.title, "Afternoon draft")

        try service.update(second, title: second.title, start: second.start, end: second.end,
                           day: todayAt(13, 0), durationMinutes: 60, addAsTask: true)
        XCTAssertEqual(first.kindEnum, .task)
        XCTAssertEqual(second.kindEnum, .task)
        XCTAssertEqual(deleted.kindEnum, .task)
        XCTAssertNil(try taskRows().first?.deletedAt)
        XCTAssertEqual(try taskRows().count, 1)
    }

    func testDueOnlyTaskCanBecomeManualPlanWithoutLosingTaskRecord() throws {
        let task = LocalTodo(title: "Due task", dueDate: todayAt(17, 0))
        store.context.insert(task)
        try store.context.save()
        let row = try service.saveTaskTime(taskUUID: task.clientUUID.uuidString, title: task.title,
                                           start: todayAt(10, 0), end: todayAt(11, 0),
                                           day: Date(), durationMinutes: 60, notes: "Plan note", addAsTask: false)
        XCTAssertEqual(row.kindEnum, .manual)
        XCTAssertEqual(row.taskUUID, task.clientUUID.uuidString)
        XCTAssertNotNil(task.deletedAt)
        XCTAssertEqual(task.dueDate, todayAt(17, 0))
        XCTAssertEqual(try rows().count, 1)
    }

    func testHiddenLinkedBlockStaysOneManualTileWithCompletion() throws {
        let start = todayAt(10, 0)
        let end = todayAt(11, 0)
        let block = try service.addManual(title: "Finish report", start: start, end: end, addAsTask: true)
        let task = try XCTUnwrap(taskRows().first)
        task.completed = true
        task.dueDate = todayAt(17, 0)
        try store.context.save()

        func day(includeTask: Bool) -> PlannerDay {
            let snapshot = PlannerBlock(id: block.clientUUID, kind: block.kindEnum, title: block.title,
                                        day: WallClock.deviceDay(from: block.day), start: block.start,
                                        end: block.end, durationMinutes: block.durationMinutes,
                                        taskUUID: block.taskUUID, completed: task.completed)
            let tasks = includeTask ? [PlannerTask(id: task.clientUUID.uuidString, title: task.title,
                                                   priority: .none, due: task.dueDate, completed: task.completed)] : []
            return PlannerEngine.day(start, events: [], blocks: [snapshot], tasks: tasks, now: start)
        }

        XCTAssertEqual(day(includeTask: true).all.count, 1, "a task plan suppresses its due tile")
        try service.update(block, title: task.title, start: start, end: end, day: start,
                           durationMinutes: 60, addAsTask: false)
        let hidden = day(includeTask: false).all
        XCTAssertEqual(hidden.count, 1)
        XCTAssertEqual(hidden.first?.source, .manual)
        XCTAssertNil(hidden.first?.taskUUID, "a hidden task is not actionable from the manual tile")
        XCTAssertEqual(hidden.first?.completed, true)
        try service.update(block, title: block.title, start: start, end: end, day: start,
                           durationMinutes: 60, addAsTask: true)
        XCTAssertEqual(day(includeTask: true).all.count, 1)
    }

    func testFillPlacesEveryTaskInOneSave() throws {
        let made = try service.placeTasks([
            (taskUUID: "t1", title: "Reply Tim", start: todayAt(11, 30), end: todayAt(11, 45)),
            (taskUUID: "t2", title: "Review PRD", start: todayAt(11, 45), end: todayAt(12, 45)),
        ])
        XCTAssertEqual(made.count, 2)
        let all = try rows().sorted { $0.start! < $1.start! }
        XCTAssertEqual(all.map(\.taskUUID), ["t1", "t2"])
        XCTAssertEqual(all.map(\.kindEnum), [.task, .task])
        XCTAssertEqual(all.map(\.durationMinutes), [15, 60])
    }

    func testPlanningATaskTwiceMovesItsPlanInsteadOfDuplicating() throws {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let first = try service.planTask(taskUUID: "t", title: "OKRs", toDay: tomorrow, durationMinutes: 120)
        let second = try service.planTask(taskUUID: "t", title: "OKRs", start: todayAt(14, 0), end: todayAt(15, 0))
        XCTAssertEqual(first.clientUUID, second.clientUUID)
        let live = try rows().filter { $0.deletedAt == nil }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].start, todayAt(14, 0))
        XCTAssertEqual(live[0].day, WallClock.todayAnchor())
    }

    func testDeleteIsSoft() throws {
        let row = try service.addManual(title: "Focus", start: todayAt(10, 0), end: todayAt(11, 0))
        try service.delete(row)
        XCTAssertEqual(try rows().count, 1)
        XCTAssertNotNil(try rows().first?.deletedAt)
        XCTAssertTrue(try service.liveBlocks().isEmpty)
    }

    func testMoveToADayDropsTheHour() throws {
        let row = try service.addManual(title: "Focus", start: todayAt(10, 0), end: todayAt(11, 0))
        let friday = Calendar.current.date(byAdding: .day, value: 3, to: Date())!
        try service.move(row, toDay: friday)
        XCTAssertNil(row.start)
        XCTAssertEqual(row.day, WallClock.dayAnchor(from: friday))
        XCTAssertEqual(row.durationMinutes, 60, "the length survives the move")
    }

    // MARK: - Backup and sync round trips

    func testAnArchiveRoundTripRestoresBlocks() async throws {
        let timed = try service.addManual(title: "Focus", start: todayAt(10, 0), end: todayAt(11, 0))
        let day = try service.planTask(taskUUID: "t9", title: "OKRs", toDay: Date(), durationMinutes: 90)

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        let preview = try importer.preview(url: archiveURL)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.planBlocks]?.new, 2)
        try importer.commit(preview: preview)

        let back = try empty.context.fetch(FetchDescriptor<LocalPlanBlock>())
        let byID = Dictionary(uniqueKeysWithValues: back.map { ($0.clientUUID, $0) })
        XCTAssertEqual(byID[timed.clientUUID]?.start, timed.start)
        XCTAssertEqual(byID[timed.clientUUID]?.end, timed.end)
        XCTAssertEqual(byID[timed.clientUUID]?.title, "Focus")
        XCTAssertEqual(byID[day.clientUUID]?.kindEnum, .task)
        XCTAssertEqual(byID[day.clientUUID]?.taskUUID, "t9")
        XCTAssertEqual(byID[day.clientUUID]?.durationMinutes, 90)
        XCTAssertEqual(byID[day.clientUUID]?.day, day.day)
        XCTAssertNil(byID[day.clientUUID]?.start)
    }

    /// A peer's block arrives through the same path `SyncApplier` uses, and a
    /// day written as a device-local midnight is snapped onto its anchor.
    func testAnInboundSyncedBlockIsAppliedAndReAnchored() throws {
        var payload = DataArchive.Payload.empty
        let singaporeMidnight = ISO8601DateFormatter().date(from: "2026-09-28T16:00:00Z")!
        payload.planBlocks = [DataArchive.PlanBlockDTO(
            clientUUID: "pb1", kind: "manual", title: "From the Mac", day: singaporeMidnight, durationMinutes: 45
        )]
        let records = try SyncRecordMapper.records(from: payload)
        XCTAssertEqual(records.filter { $0.entity == "LocalPlanBlock" }.map(\.recordID), ["pb1"])

        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload
        )
        let preview = DataImportService.Preview(
            manifest: manifest, archiveURL: URL(fileURLWithPath: "/dev/null"), entries: [:], counts: [:]
        )
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)

        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.title, "From the Mac")
        XCTAssertEqual(row.durationMinutes, 45)
        XCTAssertEqual(row.day, WallClock.dayAnchor(fromISO: "2026-09-29"))
    }

    // MARK: - Notes (#687 round 3)

    func testNotesPersistAndRoundTripThroughTheArchive() async throws {
        let row = try service.addManual(title: "Focus", start: todayAt(10, 0), end: todayAt(11, 0), notes: "  Bring the draft PRD  ")
        XCTAssertEqual(row.notes, "Bring the draft PRD")
        try service.update(row, title: "Focus", start: row.start, end: row.end, day: Date(), durationMinutes: 60, notes: "Room 4B")
        XCTAssertEqual(row.notes, "Room 4B")
        try service.update(row, title: "Focus 2", start: row.start, end: row.end, day: Date(), durationMinutes: 60)
        XCTAssertEqual(row.notes, "Room 4B", "nil notes leaves them alone")

        let url = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        try importer.commit(preview: try importer.preview(url: url))
        let back = try XCTUnwrap(try empty.context.fetch(FetchDescriptor<LocalPlanBlock>()).first)
        XCTAssertEqual(back.notes, "Room 4B")
    }

    /// An archive or a peer written before notes existed carries no key. The
    /// whole record must still decode, with empty notes.
    func testABlockWrittenBeforeNotesStillDecodes() throws {
        let json = """
        {"clientUUID":"pb-old","kind":"manual","title":"Old","day":"2026-09-29T00:00:00Z",
         "durationMinutes":30,"taskUUID":"","createdAt":"2026-09-29T01:00:00Z","updatedAt":"2026-09-29T01:00:00Z"}
        """
        let dto = try DataArchive.makeDecoder().decode(DataArchive.PlanBlockDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.notes)
        var payload = DataArchive.Payload.empty
        payload.planBlocks = [dto]
        let manifest = DataArchive.Manifest(schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload)
        let preview = DataImportService.Preview(manifest: manifest, archiveURL: URL(fileURLWithPath: "/dev/null"), entries: [:], counts: [:])
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)
        XCTAssertEqual(try rows().first?.notes, "")
    }

    func testNotesTravelInTheSyncRecord() throws {
        var payload = DataArchive.Payload.empty
        payload.planBlocks = [DataArchive.PlanBlockDTO(clientUUID: "pb2", title: "Synced", notes: "From the Mac")]
        let record = try XCTUnwrap(try SyncRecordMapper.records(from: payload).first { $0.entity == "LocalPlanBlock" })
        XCTAssertTrue(String(describing: record.json).contains("From the Mac"), "the notes are in the synced record")
        var edited = payload
        edited.planBlocks = [DataArchive.PlanBlockDTO(clientUUID: "pb2", title: "Synced", notes: "Edited")]
        let editedRecord = try XCTUnwrap(try SyncRecordMapper.records(from: edited).first { $0.entity == "LocalPlanBlock" })
        XCTAssertNotEqual(record.contentHash, editedRecord.contentHash, "a notes edit changes the hash, so it is sent")
        let manifest = DataArchive.Manifest(schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload)
        let preview = DataImportService.Preview(manifest: manifest, archiveURL: URL(fileURLWithPath: "/dev/null"), entries: [:], counts: [:])
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)
        XCTAssertEqual(try rows().first?.notes, "From the Mac")
    }

    // MARK: - Task length (#687 fix)

    /// Saving a timed task that has no block creates one with the chosen
    /// length, and the Planner then remembers that length for the task.
    func testSavingATimedTaskCreatesItsBlockWithTheNewLength() throws {
        let row = try service.planTask(taskUUID: "t-deck", title: "Send deck", start: todayAt(17, 0), end: todayAt(18, 30))
        XCTAssertEqual(row.kindEnum, .task)
        XCTAssertEqual(row.durationMinutes, 90)
        let blocks = try rows().map {
            PlannerBlock(id: $0.clientUUID, kind: $0.kindEnum, title: $0.title, day: WallClock.deviceDay(from: $0.day),
                         start: $0.start, end: $0.end, durationMinutes: $0.durationMinutes, taskUUID: $0.taskUUID)
        }
        let task = PlannerTask(id: "t-deck", title: "Send deck", priority: .p0, due: todayAt(17, 0), completed: false)
        let day = PlannerEngine.day(Date(), events: [], blocks: blocks, tasks: [task], now: todayAt(8, 0))
        XCTAssertEqual(day.timed.count, 1, "the block replaces the 30 minute due tile")
        XCTAssertEqual(day.timed.first?.durationMinutes, 90)
    }

    func testResizingAPlannedTaskUpdatesItsBlock() throws {
        let row = try service.planTask(taskUUID: "t", title: "OKRs", start: todayAt(14, 0), end: todayAt(14, 30))
        try service.update(row, title: row.title, start: todayAt(14, 0), end: todayAt(16, 0), day: Date(), durationMinutes: 120)
        XCTAssertEqual(row.durationMinutes, 120)
        XCTAssertEqual(row.end, todayAt(16, 0))
        XCTAssertEqual(try rows().count, 1, "updated in place, not duplicated")
        // Planning it again (say to another day) keeps the remembered length.
        let again = try service.planTask(taskUUID: "t", title: "OKRs", start: todayAt(15, 0), end: todayAt(17, 0))
        XCTAssertEqual(again.clientUUID, row.clientUUID)
        XCTAssertEqual(again.durationMinutes, 120)
    }

    func testANewLengthTravelsInTheSyncRecord() throws {
        let row = try service.planTask(taskUUID: "t", title: "OKRs", start: todayAt(14, 0), end: todayAt(14, 30))
        func record() throws -> SyncRecord {
            let payload = try DataExportService(modelContext: store.context).buildPayload()
            return try XCTUnwrap(try SyncRecordMapper.records(from: payload).first { $0.recordID == row.clientUUID })
        }
        let before = try record()
        try service.update(row, title: row.title, start: todayAt(14, 0), end: todayAt(15, 45), day: Date(), durationMinutes: 105)
        let after = try record()
        XCTAssertNotEqual(before.contentHash, after.contentHash, "the new length is sent to the other device")
        XCTAssertTrue(String(describing: after.json).contains("105"))
    }
}
