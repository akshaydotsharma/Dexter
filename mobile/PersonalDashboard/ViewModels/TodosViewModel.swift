import Foundation
import Observation

@Observable
@MainActor
final class TodosViewModel {
    private(set) var todos: [Todo] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: TodoService

    init(service: TodoService = TodoService()) {
        self.service = service
        if let cached = CacheStore.load([Todo].self, from: .todos) {
            self.todos = cached
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await service.list()
            todos = fresh
            CacheStore.save(fresh, to: .todos)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        await load()
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
        guard let index = todos.firstIndex(of: todo) else { return }
        let optimistic = Todo(
            id: todo.id,
            clientUuid: todo.clientUuid,
            title: todo.title,
            description: todo.description,
            completed: !todo.completed,
            dueDate: todo.dueDate,
            tag: todo.tag,
            position: todo.position,
            version: todo.version,
            createdAt: todo.createdAt,
            updatedAt: Date(),
            deletedAt: todo.deletedAt
        )
        todos[index] = optimistic
        do {
            let updated = try await service.toggleCompleted(todo)
            if let idx = todos.firstIndex(where: { $0.id == updated.id }) {
                todos[idx] = updated
            }
        } catch {
            todos[index] = todo
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
            let updated = try await service.update(id: todo.id, request)
            if let index = todos.firstIndex(where: { $0.id == todo.id }) {
                todos[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ todo: Todo) async {
        let originalIndex = todos.firstIndex(of: todo)
        todos.removeAll { $0.id == todo.id }
        do {
            try await service.delete(id: todo.id)
        } catch {
            errorMessage = error.localizedDescription
            if let idx = originalIndex {
                todos.insert(todo, at: idx)
            }
        }
    }
}
