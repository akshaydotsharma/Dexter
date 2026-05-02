import Foundation

struct ChecklistService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func list() async throws -> [Checklist] {
        try await api.get("lists")
    }

    func create(_ request: ChecklistCreateRequest) async throws -> Checklist {
        try await api.post("lists", body: request)
    }

    func update(id: Int, _ request: ChecklistUpdateRequest) async throws -> Checklist {
        try await api.put("lists/\(id)", body: request)
    }

    func delete(id: Int) async throws {
        try await api.delete("lists/\(id)")
    }
}
