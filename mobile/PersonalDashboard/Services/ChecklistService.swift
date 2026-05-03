import Foundation
import SwiftData

/// Local-first checklist service. Items are part of the row (JSON-encoded
/// Data) so updating an item is a row-level update.
@MainActor
struct ChecklistService {
    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    func list() async throws -> [Checklist] {
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    func create(_ request: ChecklistCreateRequest) async throws -> Checklist {
        let now = Date()
        let row = LocalList(
            title: request.title,
            items: request.items,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    func update(_ list: Checklist, _ request: ChecklistUpdateRequest) async throws -> Checklist {
        let row = try fetchLocal(uuid: list.id)
        row.title = request.title
        row.items = request.items
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    func delete(_ list: Checklist) async throws {
        let row = try fetchLocal(uuid: list.id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
    }

    private func fetchLocal(uuid: UUID) throws -> LocalList {
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        guard let row = try store.context.fetch(descriptor).first else {
            throw APIError.notFound
        }
        return row
    }
}
