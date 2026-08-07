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

    /// Return the live, undeleted todos sorted by createdAt ascending
    /// (oldest first, newest last) so new tasks land at the bottom (#267).
    func list() async throws -> [Todo] {
        let context = store.context
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
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
            address: request.address,
            googleMapsLink: request.googleMapsLink,
            priority: request.priority,
            remindMe: request.remindMe,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try store.context.save()
        reconcileReminders()
        return row.toDTO()
    }

    func update(_ todo: Todo, _ request: TodoUpdateRequest) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        if let title = request.title { row.title = title }
        if let description = request.description { row.todoDescription = description }
        if let completed = request.completed { row.completed = completed }
        // Clearing wins over setting: an editor that turned the toggle off sends
        // `clearsDueDate` with a stale `dueDate` still in its state.
        if request.clearsDueDate {
            row.dueDate = nil
        } else if let dueDate = request.dueDate {
            row.dueDate = dueDate
        }
        if let tag = request.tag { row.tag = tag }
        if let address = request.address { row.address = address }
        if let googleMapsLink = request.googleMapsLink { row.googleMapsLink = googleMapsLink }
        if let priority = request.priority { row.priority = priority }
        if let remindMe = request.remindMe { row.remindMe = remindMe }
        // A task with no due date has nothing to remind against (#444), so the
        // flag cannot survive the date being cleared. Enforced here rather than
        // only in the editor so the AI and calendar paths cannot leave a task
        // flagged-but-dateless either.
        if row.dueDate == nil { row.remindMe = false }
        row.updatedAt = Date()
        try store.context.save()
        reconcileReminders()
        return row.toDTO()
    }

    func toggleCompleted(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.completed.toggle()
        row.updatedAt = Date()
        try store.context.save()
        // Completing a task must take its pending banner with it (#444).
        reconcileReminders()
        return row.toDTO()
    }

    /// Bring the OS's pending reminders back in line with the store (#444).
    ///
    /// Every write goes through this service, so this is the one place that has to
    /// know about it — rather than each of create/update/complete/delete's callers,
    /// which is what would otherwise have to be kept in step as surfaces are added.
    /// Detached because a reminder is not worth failing or delaying a save for.
    private func reconcileReminders() {
        Task { await TaskReminderScheduler.reconcile(store: store) }
    }

    /// Soft-delete the todo. `permanent: true` removes the row from the local
    /// store entirely.
    ///
    /// Cascades to the task's ticket attachments (#399) so they don't outlive it
    /// as orphaned rows and files on disk, the same way deleting a note takes its
    /// images. The cascade runs FIRST: it needs to read the ticket rows, and a
    /// permanent delete of the task would leave nothing to key them off.
    func delete(_ todo: Todo, permanent: Bool = false) async throws {
        try? TaskTicketService(store: store).deleteAll(todoId: todo.id)

        let row = try fetchLocal(uuid: todo.id)
        if permanent {
            store.context.delete(row)
        } else {
            row.deletedAt = Date()
            row.updatedAt = Date()
        }
        try store.context.save()
        // A deleted task must not go on banner-ing (#444).
        reconcileReminders()
    }

    func restore(_ todo: Todo) async throws -> Todo {
        let row = try fetchLocal(uuid: todo.id)
        row.deletedAt = nil
        row.updatedAt = Date()
        try store.context.save()
        reconcileReminders()
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
