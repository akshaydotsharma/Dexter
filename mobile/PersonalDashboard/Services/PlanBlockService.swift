import Foundation
import SwiftData

/// Every write the Planner makes (#687). Blocks live in `LocalPlanBlock`.
/// An opted-in create also writes one linked `LocalTodo` in the same save.
///
/// Each create mints its id once and inserts once. A same-id insert would be
/// collapsed by `@Attribute(.unique)` by REPLACING the row (#514), so nothing
/// here re-inserts an existing id: edits update the row in place.
@MainActor
struct PlanBlockService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> PlanBlockService { PlanBlockService(store: .shared) }

    // MARK: Reads

    func liveBlocks() throws -> [LocalPlanBlock] {
        try store.context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.day), SortDescriptor(\.createdAt)]
        ))
    }

    func block(id: String) throws -> LocalPlanBlock? {
        try store.context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.clientUUID == id }
        )).first
    }

    // MARK: Creates

    /// A manual block with an hour.
    @discardableResult
    func addManual(title: String, start: Date, end: Date, notes: String = "", addAsTask: Bool = false) throws -> LocalPlanBlock {
        let (s, e) = ordered(start, end)
        let row = LocalPlanBlock(
            kind: addAsTask ? .task : .manual,
            title: clean(title, fallback: "Block"),
            day: WallClock.dayAnchor(from: s),
            start: s, end: e,
            durationMinutes: PlannerEngine.minutes(from: s, to: e),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try insertNew(row, addAsTask: addAsTask)
        return row
    }

    /// A manual block planned to a day with no hour.
    @discardableResult
    func addManual(title: String, day: Date, durationMinutes: Int, notes: String = "", addAsTask: Bool = false) throws -> LocalPlanBlock {
        let row = LocalPlanBlock(
            kind: addAsTask ? .task : .manual,
            title: clean(title, fallback: "Block"),
            day: WallClock.dayAnchor(from: day),
            durationMinutes: max(5, durationMinutes),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        try insertNew(row, addAsTask: addAsTask)
        return row
    }

    /// Whatever the quick-add line parsed into.
    @discardableResult
    func add(_ parsed: PlannerQuickAdd.Result, addAsTask: Bool = false) throws -> LocalPlanBlock {
        if let start = parsed.start, let end = parsed.end {
            return try addManual(title: parsed.title, start: start, end: end, addAsTask: addAsTask)
        }
        return try addManual(title: parsed.title, day: parsed.day, durationMinutes: parsed.durationMinutes, addAsTask: addAsTask)
    }

    /// The planned day is not a task deadline. Insert both rows before saving,
    /// then discard both pending inserts if the save fails.
    private func insertNew(_ block: LocalPlanBlock, addAsTask: Bool) throws {
        var task: LocalTodo?
        if addAsTask {
            let newTask = LocalTodo(title: block.title, todoDescription: block.notes.isEmpty ? nil : block.notes)
            block.taskUUID = newTask.clientUUID.uuidString
            store.context.insert(newTask)
            task = newTask
        }
        store.context.insert(block)
        do {
            try store.context.save()
        } catch {
            store.context.delete(block)
            if let task { store.context.delete(task) }
            throw error
        }
    }

    /// Place tasks into slots, in one save, so a Fill is all or nothing.
    @discardableResult
    func placeTasks(_ placements: [(taskUUID: String, title: String, start: Date, end: Date)]) throws -> [LocalPlanBlock] {
        var rows: [LocalPlanBlock] = []
        for p in placements {
            let row = LocalPlanBlock(
                kind: .task,
                title: p.title,
                day: WallClock.dayAnchor(from: p.start),
                start: p.start, end: p.end,
                durationMinutes: PlannerEngine.minutes(from: p.start, to: p.end),
                taskUUID: p.taskUUID
            )
            store.context.insert(row)
            rows.append(row)
        }
        try store.context.save()
        return rows
    }

    /// Plan a task to a day with no hour. A task has at most one live plan from
    /// today on, so an earlier plan for it is moved rather than duplicated.
    @discardableResult
    func planTask(taskUUID: String, title: String, toDay day: Date, durationMinutes: Int) throws -> LocalPlanBlock {
        if let existing = try livePlan(forTask: taskUUID) {
            existing.day = WallClock.dayAnchor(from: day)
            existing.start = nil
            existing.end = nil
            existing.durationMinutes = max(5, durationMinutes)
            existing.title = title
            existing.updatedAt = Date()
            try store.context.save()
            return existing
        }
        let row = LocalPlanBlock(
            kind: .task, title: title,
            day: WallClock.dayAnchor(from: day),
            durationMinutes: max(5, durationMinutes),
            taskUUID: taskUUID
        )
        store.context.insert(row)
        try store.context.save()
        return row
    }

    /// Plan a task into one slot. Same one-live-plan rule as `planTask(toDay:)`.
    @discardableResult
    func planTask(taskUUID: String, title: String, start: Date, end: Date) throws -> LocalPlanBlock {
        let (s, e) = ordered(start, end)
        if let existing = try livePlan(forTask: taskUUID) {
            existing.day = WallClock.dayAnchor(from: s)
            existing.start = s
            existing.end = e
            existing.durationMinutes = PlannerEngine.minutes(from: s, to: e)
            existing.title = title
            existing.updatedAt = Date()
            try store.context.save()
            return existing
        }
        return try placeTasks([(taskUUID, title, s, e)])[0]
    }

    /// Save a task-due tile's new placement and its Tasks visibility together.
    /// There may be no plan row yet, so keep its insert in the same save.
    @discardableResult
    func saveTaskTime(taskUUID: String, title: String, start: Date?, end: Date?, day: Date, durationMinutes: Int, notes: String, addAsTask: Bool) throws -> LocalPlanBlock {
        let existing = try livePlan(forTask: taskUUID)
        let row = existing ?? LocalPlanBlock(kind: .task, title: title,
                                             day: WallClock.dayAnchor(from: day), taskUUID: taskUUID)
        if existing == nil { store.context.insert(row) }
        do {
            try update(row, title: title, start: start, end: end, day: day,
                       durationMinutes: durationMinutes, notes: notes, addAsTask: addAsTask)
        } catch {
            if existing == nil { store.context.delete(row) }
            throw error
        }
        return row
    }

    // MARK: Edits

    /// `notes` nil leaves the notes as they are; "" clears them (#488).
    /// `addAsTask` nil leaves the task link alone. Toggling changes all live
    /// plans of the same task, so no other block points to a hidden task.
    func update(_ block: LocalPlanBlock, title: String, start: Date?, end: Date?, day: Date, durationMinutes: Int, notes: String? = nil, addAsTask: Bool? = nil) throws {
        let context = store.context
        let now = Date()
        let newTitle = clean(title, fallback: block.title)
        let linkedID = block.taskUUID
        var linked = linkedID.isEmpty ? [block] : try context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.taskUUID == linkedID && $0.deletedAt == nil }
        ))
        if !linked.contains(where: { $0 === block }) { linked.append(block) }
        let snapshots = linked.map { BlockSnapshot($0) }
        var task = try linkedTask(for: block.taskUUID)
        let taskSnapshot = task.map { TaskSnapshot($0) }
        var insertedTask: LocalTodo?

        if let addAsTask {
            if addAsTask {
                if task == nil {
                    // A never-linked block creates its task once. A retained ID
                    // reuses that identity if an old task row is absent.
                    let uuid = UUID(uuidString: block.taskUUID) ?? UUID()
                    let taskNotes = (notes ?? block.notes).trimmingCharacters(in: .whitespacesAndNewlines)
                    let created = LocalTodo(clientUUID: uuid, title: newTitle,
                                            todoDescription: taskNotes.isEmpty ? nil : taskNotes)
                    context.insert(created)
                    insertedTask = created
                    task = created
                    block.taskUUID = uuid.uuidString
                } else if task?.deletedAt != nil {
                    task?.deletedAt = nil
                    task?.title = newTitle
                    task?.updatedAt = now
                }
                for row in linked {
                    row.kind = PlanBlockKind.task.rawValue
                    row.updatedAt = now
                }
            } else {
                let wasVisible = (task.map { $0.deletedAt == nil } ?? false) || linked.contains { $0.kindEnum == .task }
                let displayedTitle = task?.title ?? block.title
                if let task, task.deletedAt == nil {
                    task.deletedAt = now
                    task.updatedAt = now
                }
                if wasVisible {
                    for row in linked {
                        row.kind = PlanBlockKind.manual.rawValue
                        row.title = row === block ? newTitle : displayedTitle
                        row.updatedAt = now
                    }
                }
            }
        }

        block.title = newTitle
        if let notes { block.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let start, let end {
            let (s, e) = ordered(start, end)
            block.start = s
            block.end = e
            block.day = WallClock.dayAnchor(from: s)
            block.durationMinutes = PlannerEngine.minutes(from: s, to: e)
        } else {
            block.start = nil
            block.end = nil
            block.day = WallClock.dayAnchor(from: day)
            block.durationMinutes = max(5, durationMinutes)
        }
        block.updatedAt = now
        do {
            try context.save()
        } catch {
            snapshots.forEach { $0.restore() }
            if let taskSnapshot { taskSnapshot.restore() }
            if let insertedTask { context.delete(insertedTask) }
            throw error
        }
        if addAsTask != nil, task != nil {
            Task { await TaskReminderScheduler.reconcile(store: store) }
        }
    }

    private func linkedTask(for taskUUID: String) throws -> LocalTodo? {
        guard let uuid = UUID(uuidString: taskUUID) else { return nil }
        return try store.context.fetch(FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.clientUUID == uuid })).first
    }

    private struct BlockSnapshot {
        let row: LocalPlanBlock
        let kind: String
        let title: String
        let notes: String
        let day: Date
        let start: Date?
        let end: Date?
        let durationMinutes: Int
        let taskUUID: String
        let updatedAt: Date

        init(_ row: LocalPlanBlock) {
            self.row = row
            kind = row.kind; title = row.title; notes = row.notes; day = row.day
            start = row.start; end = row.end; durationMinutes = row.durationMinutes
            taskUUID = row.taskUUID; updatedAt = row.updatedAt
        }

        func restore() {
            row.kind = kind; row.title = title; row.notes = notes; row.day = day
            row.start = start; row.end = end; row.durationMinutes = durationMinutes
            row.taskUUID = taskUUID; row.updatedAt = updatedAt
        }
    }

    private struct TaskSnapshot {
        let row: LocalTodo
        let title: String
        let deletedAt: Date?
        let updatedAt: Date

        init(_ row: LocalTodo) {
            self.row = row; title = row.title; deletedAt = row.deletedAt; updatedAt = row.updatedAt
        }

        func restore() {
            row.title = title; row.deletedAt = deletedAt; row.updatedAt = updatedAt
        }
    }

    /// Move a block to another day with no hour ("To Fri" on an overloaded day).
    func move(_ block: LocalPlanBlock, toDay day: Date) throws {
        block.day = WallClock.dayAnchor(from: day)
        block.start = nil
        block.end = nil
        block.updatedAt = Date()
        try store.context.save()
    }

    /// Soft delete, so the removal reaches a peer as an upsert.
    func delete(_ block: LocalPlanBlock) throws {
        block.deletedAt = Date()
        block.updatedAt = Date()
        try store.context.save()
    }

    /// Soft-delete every live plan of a task, on any day (#687 round 6: the
    /// task itself was deleted, so nothing may keep placing it).
    func unplanAll(taskUUID: String) throws {
        let rows = try store.context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.taskUUID == taskUUID && $0.deletedAt == nil }
        ))
        guard !rows.isEmpty else { return }
        let now = Date()
        for row in rows {
            row.deletedAt = now
            row.updatedAt = now
        }
        try store.context.save()
    }

    /// Returning a scheduled task to To plan clears both its placement and
    /// its deadline. Save the task and all plan tombstones together, so the
    /// due-date fallback cannot immediately put it back on the grid.
    func returnToPlan(taskUUID: String, blockID: String? = nil) throws {
        guard let task = try linkedTask(for: taskUUID), task.deletedAt == nil, !task.completed else { return }
        let rows = try store.context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.taskUUID == taskUUID && $0.deletedAt == nil }
        ))
        let activeRows = rows.filter { $0.day >= WallClock.todayAnchor() || $0.clientUUID == blockID }
        let previousPlans = activeRows.map { ($0, $0.deletedAt, $0.updatedAt) }
        let due = task.dueDate, remindMe = task.remindMe, cleared = task.reminderClearedAt, updated = task.updatedAt
        let now = Date()
        task.dueDate = nil
        task.remindMe = false
        task.reminderClearedAt = nil
        task.updatedAt = now
        for row in activeRows {
            row.deletedAt = now
            row.updatedAt = now
        }
        do {
            try store.context.save()
        } catch {
            task.dueDate = due
            task.remindMe = remindMe
            task.reminderClearedAt = cleared
            task.updatedAt = updated
            for (row, deletedAt, updatedAt) in previousPlans {
                row.deletedAt = deletedAt
                row.updatedAt = updatedAt
            }
            throw error
        }
        Task { await TaskReminderScheduler.reconcile(store: store) }
    }

    // MARK: Helpers

    private func livePlan(forTask taskUUID: String) throws -> LocalPlanBlock? {
        let today = WallClock.todayAnchor()
        return try store.context.fetch(FetchDescriptor<LocalPlanBlock>(
            predicate: #Predicate { $0.taskUUID == taskUUID && $0.deletedAt == nil && $0.day >= today }
        )).first
    }

    private func ordered(_ a: Date, _ b: Date) -> (Date, Date) {
        let s = WallClock.minutePrecision(min(a, b))
        var e = WallClock.minutePrecision(max(a, b))
        if e <= s { e = s.addingTimeInterval(5 * 60) }
        return (s, e)
    }

    private func clean(_ title: String, fallback: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}
