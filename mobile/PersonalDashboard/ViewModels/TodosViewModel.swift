import Foundation
import Observation
import SwiftData

/// View model for the Tasks surface. Reads from the local SwiftData store
/// (via `TodoService`) so the UI works whether or not the Mac is reachable.
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

    /// Refresh from the local store.
    func load() async {
        isLoading = true
        do {
            todos = try await service.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        await load()
    }

    func create(title: String, description: String? = nil, dueDate: Date? = nil, tag: String? = nil, address: String = "", googleMapsLink: String = "", priority: Int = 0) async {
        do {
            let request = TodoCreateRequest(title: title, description: description, dueDate: dueDate, tag: tag, address: address, googleMapsLink: googleMapsLink, priority: priority)
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

    func update(_ todo: Todo, title: String? = nil, description: String? = nil, dueDate: Date? = nil, tag: String? = nil, address: String? = nil, googleMapsLink: String? = nil, priority: Int? = nil) async {
        do {
            let request = TodoUpdateRequest(
                title: title,
                description: description,
                completed: nil,
                dueDate: dueDate,
                tag: tag,
                address: address,
                googleMapsLink: googleMapsLink,
                priority: priority
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

