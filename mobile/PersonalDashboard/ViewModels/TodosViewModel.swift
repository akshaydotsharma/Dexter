import Foundation
import Observation
import SwiftData

/// View model for the Tasks surface. Reads from the local SwiftData store
/// (via `TodoService`) so the UI works whether or not the Mac is reachable.
/// Mutations go to the local store immediately and trigger a background
/// sync; the next refresh pulls back the canonical server state.
@Observable
@MainActor
final class TodosViewModel {
    private(set) var todos: [Todo] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: TodoService

    init(service: TodoService? = nil) {
        let resolvedService = service ?? TodoService()
        self.service = resolvedService
        // First paint: read the local store synchronously so the surface
        // never flashes empty. SwiftData's main-context fetch is synchronous.
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? resolvedService.store.context.fetch(descriptor)) ?? []
        self.todos = rows.map { $0.toDTO() }
    }

    /// Refresh from the local store. Optionally triggers a sync first so
    /// the local store catches up with the server before we re-render.
    func load(syncFirst: Bool = true) async {
        isLoading = true
        errorMessage = nil
        if syncFirst {
            do {
                try await SyncEngine.shared.sync()
            } catch {
                // Sync failure is non-fatal — the local store still has the
                // last-known state. Surface the error but keep going.
                errorMessage = error.localizedDescription
            }
        }
        do {
            todos = try await service.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        await load(syncFirst: true)
    }

    func create(title: String, description: String? = nil, dueDate: Date? = nil, tag: String? = nil) async {
        do {
            let request = TodoCreateRequest(title: title, description: description, dueDate: dueDate, tag: tag)
            let new = try await service.create(request)
            todos.insert(new, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleCompleted(_ todo: Todo) async {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        // Optimistic flip so the row animates immediately.
        todos[index].completed.toggle()
        do {
            let updated = try await service.toggleCompleted(todo)
            todos[index] = updated
        } catch {
            // Revert on failure.
            todos[index].completed.toggle()
            errorMessage = error.localizedDescription
        }
    }

    func update(_ todo: Todo, title: String? = nil, description: String? = nil, dueDate: Date? = nil, tag: String? = nil) async {
        do {
            let request = TodoUpdateRequest(
                title: title,
                description: description,
                completed: nil,
                dueDate: dueDate,
                tag: tag
            )
            let updated = try await service.update(todo, request)
            if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                todos[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ todo: Todo) async {
        let originalIndex = todos.firstIndex(where: { $0.id == todo.id })
        todos.removeAll { $0.id == todo.id }
        do {
            try await service.delete(todo)
        } catch {
            errorMessage = error.localizedDescription
            if let idx = originalIndex {
                todos.insert(todo, at: idx)
            }
        }
    }
}

