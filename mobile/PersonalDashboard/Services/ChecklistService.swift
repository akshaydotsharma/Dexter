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

    /// The ACTIVE lists: not deleted and not archived (#374).
    ///
    /// Both halves of that predicate matter. `deletedAt == nil` has always been
    /// here; `archivedAt == nil` is what keeps archived lists out of the index,
    /// the Today card and everything else that reads through
    /// `ListsViewModel.lists`. The archive has its own accessor below.
    func list() async throws -> [Checklist] {
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    /// The archived lists, most recently archived first (#374).
    ///
    /// Sorted by `archivedAt` rather than `createdAt`: in the archive the
    /// interesting order is "what did I just put in here", not when the list was
    /// originally made. This is the payoff for storing a timestamp instead of a
    /// Bool.
    func listArchived() async throws -> [Checklist] {
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt != nil },
            sortBy: [SortDescriptor(\.archivedAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    func create(_ request: ChecklistCreateRequest) async throws -> Checklist {
        let now = Date()
        let row = LocalList(
            title: request.title,
            items: request.items,
            iconName: request.iconName,
            colorHex: request.colorHex,
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
        row.iconName = request.iconName
        row.colorHex = request.colorHex
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    /// Archive or restore a list (#374).
    ///
    /// Deliberately NOT routed through `update(_:_:)`. That takes a
    /// `ChecklistUpdateRequest` and overwrites title, items, icon and colour in
    /// one shot, so archiving through it would mean assembling a full row
    /// snapshot just to flip one field — and any staleness in that snapshot
    /// would silently clobber real content. This touches `archivedAt` only.
    func setArchived(_ list: Checklist, _ archived: Bool) async throws {
        let row = try fetchLocal(uuid: list.id)
        row.archivedAt = archived ? Date() : nil
        row.updatedAt = Date()
        try store.context.save()
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
