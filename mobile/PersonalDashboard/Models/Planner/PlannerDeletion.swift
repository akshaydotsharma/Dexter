import Foundation
import SwiftData

/// What Delete means for a tile (#687 round 6).
///
/// A planned task is two things on one tile: the plan (a Dexter block) and the
/// task it places. "Delete" on it is ambiguous, so the confirmation names both
/// and lets the person choose. A block they made by hand has only one meaning.
/// A calendar event has none: Dexter does not own it, so it offers Decline and
/// Remove from Planner instead.
enum PlannerDeleteChoice: String, Equatable, CaseIterable, Identifiable {
    /// A manual block: removed from every device.
    case deleteBlock
    /// A planned task: the plan goes, the task stays in Tasks, unscheduled.
    case removePlan
    /// The task itself (soft delete), with every plan of it.
    case deleteTask

    var id: String { rawValue }

    var buttonTitle: String {
        switch self {
        case .deleteBlock: return "Delete block"
        case .removePlan:  return "Remove from plan, keep the task"
        case .deleteTask:  return "Delete the task"
        }
    }

    /// Whether the dialog draws the button in red.
    var isDestructive: Bool { self != .removePlan }
}

enum PlannerDeletion {
    /// The choices for a tile, in the order the dialog shows them. Empty for a
    /// calendar event.
    static func choices(for item: PlannerItem) -> [PlannerDeleteChoice] {
        if item.isFixed { return [] }
        if item.isBlock {
            if let task = item.taskUUID, !task.isEmpty { return [.removePlan, .deleteTask] }
            return [.deleteBlock]
        }
        if case .taskDue = item.origin, item.taskUUID != nil { return [.deleteTask] }
        return []
    }

    static func dialogTitle(for item: PlannerItem) -> String {
        "Delete “\(item.title)”?"
    }

    static func dialogMessage(for item: PlannerItem) -> String {
        let choices = choices(for: item)
        if choices == [.deleteBlock] { return "The block is removed from every device." }
        if choices.contains(.removePlan) {
            return "Remove the plan and the task goes back to To plan. Delete the task and it leaves Tasks as well."
        }
        return "The task is deleted from Tasks."
    }

    /// Run one choice against a store.
    @MainActor
    static func perform(_ choice: PlannerDeleteChoice, for item: PlannerItem, store: SwiftDataStore) async throws {
        let blocks = PlanBlockService(store: store)
        switch choice {
        case .deleteBlock, .removePlan:
            guard let id = item.blockID, let row = try blocks.block(id: id) else { return }
            try blocks.delete(row)
        case .deleteTask:
            guard let taskID = item.taskUUID else { return }
            try await deleteTask(taskID, store: store)
        }
    }

    /// Soft-delete a task through `TodoService` (so its tickets and reminder go
    /// with it), and every plan of it.
    @MainActor
    static func deleteTask(_ taskID: String, store: SwiftDataStore) async throws {
        guard let uuid = UUID(uuidString: taskID) else { return }
        let rows = try store.context.fetch(FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.clientUUID == uuid }))
        if let row = rows.first {
            try await TodoService(store: store).delete(row.toDTO())
        }
        try PlanBlockService(store: store).unplanAll(taskUUID: taskID)
    }
}
