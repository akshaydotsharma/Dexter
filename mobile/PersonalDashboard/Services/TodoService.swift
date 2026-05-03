import Foundation
import SwiftData

/// Local-first todo service. All mutations land in SwiftData first, get
/// flagged with `needsSync = true`, and are pushed to the server in the
/// background by `SyncEngine`. Reads always come from the local store, so
/// the UI stays responsive even when the Mac is off.
///
/// Identity is the row's `clientUUID` (exposed as `Todo.id`), which is
/// stable across the network — the iOS layer never depends on the
/// server's integer primary key.
@MainActor
struct TodoService {
    let store: SwiftDataStore
    let syncEngine: SyncEngine

    init(store: SwiftDataStore = .shared, syncEngine: SyncEngine = .shared) {
        self.store = store
        self.syncEngine = syncEngine
    }

    // MARK: - Reads

    /// Return the live, undeleted todos sorted by the server's preferred
    /// position (or createdAt as a fallback).
    func list() async throws -> [Todo] {
        let context = store.context
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    // MARK: - Writes

    /// Create a new todo locally with a fresh UUID. The row is queued for
    /// sync; it appears in `list()` immediately and shows up on the Mac on
    /// the next successful push.
    func create(_ request: TodoCreateRequest) async throws -> Todo {
        let now = Date()
        let row = LocalTodo(
            title: request.title,
            todoDescription: request.description,
            completed: false,
            dueDate: request.dueDate,
            tag: request.tag,
            createdAt: now,
            updatedAt: now,
            needsSync: true
        )
        store.context.insert(row)
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    /// Update a todo identified by its UUID (= `Todo.id`). Only fields
    /// present on `request` are changed; nil values leave the existing
    /// value alone.
    func update(_ todo: Todo, _ request: TodoUpdateRequest) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        if let title = request.title { row.title = title }
        if let description = request.description { row.todoDescription = description }
        if let completed = request.completed { row.completed = completed }
        if let dueDate = request.dueDate { row.dueDate = dueDate }
        if let tag = request.tag { row.tag = tag }
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    /// Flip the `completed` flag. Identity is the UUID on `todo`.
    func toggleCompleted(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.completed.toggle()
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    /// Soft-delete the todo. The row stays in SwiftData with `deletedAt`
    /// stamped so the next sync can push the tombstone. `permanent: true`
    /// removes the row from the local store too — used when the server has
    /// confirmed the delete and we no longer need the tombstone locally.
    func delete(_ todo: Todo, permanent: Bool = false) async throws {
        let row = try fetchLocal(uuid: todo.id)
        if permanent {
            store.context.delete(row)
        } else {
            row.deletedAt = Date()
            row.updatedAt = Date()
            row.needsSync = true
        }
        try store.context.save()
        kickSync()
    }

    /// Restore a soft-deleted todo. Clears `deletedAt` and queues for sync.
    func restore(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.deletedAt = nil
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    // MARK: - Internals

    private func fetchLocal(uuid: UUID) throws -> LocalTodo {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        guard let row = try store.context.fetch(descriptor).first else {
            throw APIError.notFound
        }
        return row
    }

    /// Best-effort background sync. Failures are silent — the row stays
    /// `needsSync = true` and the next attempt retries.
    private func kickSync() {
        Task { @MainActor in
            try? await syncEngine.sync()
        }
    }
}
