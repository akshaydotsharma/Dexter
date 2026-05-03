import Foundation
import SwiftData

/// Local-first todo service. All mutations land in SwiftData.
/// Identity is the row's `clientUUID` (exposed as `Todo.id`), which is
/// stable — the iOS layer never depends on the server's integer primary key.
@MainActor
struct TodoService {
    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Reads

    /// Return the live, undeleted todos sorted by createdAt descending.
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

    func create(_ request: TodoCreateRequest) async throws -> Todo {
        let now = Date()
        let row = LocalTodo(
            title: request.title,
            todoDescription: request.description,
            completed: false,
            dueDate: request.dueDate,
            tag: request.tag,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    func update(_ todo: Todo, _ request: TodoUpdateRequest) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        if let title = request.title { row.title = title }
        if let description = request.description { row.todoDescription = description }
        if let completed = request.completed { row.completed = completed }
        if let dueDate = request.dueDate { row.dueDate = dueDate }
        if let tag = request.tag { row.tag = tag }
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    func toggleCompleted(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.completed.toggle()
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    /// Soft-delete the todo. `permanent: true` removes the row from the local
    /// store entirely.
    func delete(_ todo: Todo, permanent: Bool = false) async throws {
        let row = try fetchLocal(uuid: todo.id)
        if permanent {
            store.context.delete(row)
        } else {
            row.deletedAt = Date()
            row.updatedAt = Date()
        }
        try store.context.save()
    }

    func restore(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.deletedAt = nil
        row.updatedAt = Date()
        try store.context.save()
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
}
