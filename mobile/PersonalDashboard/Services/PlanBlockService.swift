import Foundation
import SwiftData

/// Every write the Planner makes (#687). All of them land in `LocalPlanBlock`;
/// none touches a `LocalTodo` or any calendar.
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
    func addManual(title: String, start: Date, end: Date, notes: String = "") throws -> LocalPlanBlock {
        let (s, e) = ordered(start, end)
        let row = LocalPlanBlock(
            kind: .manual,
            title: clean(title, fallback: "Block"),
            day: WallClock.dayAnchor(from: s),
            start: s, end: e,
            durationMinutes: PlannerEngine.minutes(from: s, to: e),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.context.insert(row)
        try store.context.save()
        return row
    }

    /// A manual block planned to a day with no hour.
    @discardableResult
    func addManual(title: String, day: Date, durationMinutes: Int, notes: String = "") throws -> LocalPlanBlock {
        let row = LocalPlanBlock(
            kind: .manual,
            title: clean(title, fallback: "Block"),
            day: WallClock.dayAnchor(from: day),
            durationMinutes: max(5, durationMinutes),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.context.insert(row)
        try store.context.save()
        return row
    }

    /// Whatever the quick-add line parsed into.
    @discardableResult
    func add(_ parsed: PlannerQuickAdd.Result) throws -> LocalPlanBlock {
        if let start = parsed.start, let end = parsed.end {
            return try addManual(title: parsed.title, start: start, end: end)
        }
        return try addManual(title: parsed.title, day: parsed.day, durationMinutes: parsed.durationMinutes)
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

    // MARK: Edits

    /// `notes` nil leaves the notes as they are; "" clears them (#488).
    func update(_ block: LocalPlanBlock, title: String, start: Date?, end: Date?, day: Date, durationMinutes: Int, notes: String? = nil) throws {
        block.title = clean(title, fallback: block.title)
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
        block.updatedAt = Date()
        try store.context.save()
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
