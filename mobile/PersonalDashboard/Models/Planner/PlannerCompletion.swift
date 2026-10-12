import Foundation
import SwiftData

/// Mark complete / Mark incomplete for a Planner tile (#695).
///
/// The write goes through `TodoService.toggleCompleted`, the same call the
/// Tasks section makes, so the reminder reconcile (#444) rides it and a
/// recurring occurrence is history to `RecurringTaskService` exactly as if it
/// had been ticked in Tasks (#524).
///
/// It SETS a state rather than flipping one. A tile is a snapshot, and two
/// quick taps or a sync landing between the draw and the tap must not turn a
/// "Mark complete" into a reopen.
enum PlannerCompletion {
    /// Set the task's completed state. Returns true when it changed.
    @MainActor
    @discardableResult
    static func set(_ taskID: String, completed: Bool, store: SwiftDataStore) async throws -> Bool {
        guard let uuid = UUID(uuidString: taskID) else { return false }
        let rows = try store.context.fetch(FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.clientUUID == uuid }))
        guard let row = rows.first, row.deletedAt == nil, row.completed != completed else { return false }
        _ = try await TodoService(store: store).toggleCompleted(row.toDTO())
        return true
    }
}
