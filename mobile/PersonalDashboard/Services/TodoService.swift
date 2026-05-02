import Foundation

struct TodoService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func list() async throws -> [Todo] {
        try await api.get("todos")
    }

    func create(_ request: TodoCreateRequest) async throws -> Todo {
        try await api.post("todos", body: request)
    }

    func update(id: Int, _ request: TodoUpdateRequest) async throws -> Todo {
        try await api.put("todos/\(id)", body: request)
    }

    func toggleCompleted(_ todo: Todo) async throws -> Todo {
        let request = TodoUpdateRequest(
            title: nil,
            description: nil,
            completed: !todo.completed,
            dueDate: nil,
            tag: nil
        )
        return try await api.put("todos/\(todo.id)", body: request)
    }

    func delete(id: Int, permanent: Bool = false) async throws {
        let query = permanent ? [URLQueryItem(name: "permanent", value: "true")] : []
        try await api.delete("todos/\(id)", query: query)
    }

    func restore(id: Int) async throws -> Todo {
        try await api.postNoBody("todos/\(id)/restore")
    }
}
