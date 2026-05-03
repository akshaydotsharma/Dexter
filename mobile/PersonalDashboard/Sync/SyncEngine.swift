import Foundation
import SwiftData

/// Sync engine for the iOS local-first data layer (#14).
///
/// Two responsibilities:
///   1. **Push**: drains LocalTodo rows where `needsSync == true`, posts
///      them to `/api/sync/upsert`, and applies the server's response back
///      into the store (so server-assigned id + version are stamped on).
///   2. **Pull**: asks `/api/sync/changes?since_version=<watermark>` for any
///      remote changes since last sync and applies them — including
///      tombstones, which delete the matching LocalTodo locally.
///
/// `sync()` runs push then pull, which is the natural order: push local
/// edits first so the pull doesn't fetch and overwrite them in flight.
///
/// All entry points are async + actor-isolated to MainActor because the
/// SwiftData ModelContext is main-actor-only on iOS 17.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine(api: .shared, store: SwiftDataStore.shared)

    let api: APIClient
    let store: SwiftDataStore

    init(api: APIClient, store: SwiftDataStore) {
        self.api = api
        self.store = store
    }

    /// Push pending local changes, then pull remote changes. Errors are
    /// surfaced for the caller to display; the local store is unaffected
    /// by transport failures so the next sync retries.
    func sync() async throws {
        try await pushOutbox()
        try await pullChanges()
    }

    // MARK: - Push

    /// Drain LocalTodo rows where needsSync == true. Build an upsert batch,
    /// post it, then apply the response: applied rows adopt server state;
    /// rejected rows (server_newer) adopt the server's row.
    func pushOutbox() async throws {
        let context = store.context
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.needsSync == true }
        )
        let pending = try context.fetch(descriptor)
        guard !pending.isEmpty else { return }

        let rows = pending.map { todo in
            TodoUpsertRow(
                clientUuid: todo.clientUUID,
                title: todo.title,
                description: todo.todoDescription,
                completed: todo.completed,
                dueDate: todo.dueDate,
                tag: todo.tag,
                position: todo.position,
                deletedAt: todo.deletedAt,
                updatedAt: todo.updatedAt
            )
        }
        let body = SyncUpsertRequest(todos: rows)
        let response: SyncUpsertResponse = try await api.post("sync/upsert", body: body)

        // Index local rows by clientUUID for fast lookup during apply.
        var byUUID: [UUID: LocalTodo] = [:]
        for row in pending { byUUID[row.clientUUID] = row }

        for serverDTO in response.applied.todos {
            byUUID[serverDTO.id]?.applyServerState(serverDTO)
        }
        for rejection in response.rejected.todos {
            if let serverRow = rejection.serverRow {
                byUUID[rejection.clientUuid]?.applyServerState(serverRow)
            }
            // For non-server_newer rejections (missing fields, etc.), the
            // local row keeps needsSync = true so the next push retries.
        }

        try context.save()
        SyncWatermark.advance(to: response.maxVersion)
    }

    // MARK: - Pull

    /// Fetch every server change with `version > watermark` and apply.
    /// Inserts rows we don't have. Updates rows we do. Rows whose
    /// `deleted_at` is not null are tombstones — the local row is deleted.
    func pullChanges() async throws {
        let watermark = SyncWatermark.current
        let path = "sync/changes"
        let query = [URLQueryItem(name: "since_version", value: String(watermark))]
        let response: SyncChangesResponse = try await api.get(path, query: query)

        let context = store.context
        for incoming in response.todos {
            try applyIncomingTodo(incoming, in: context)
        }
        try context.save()
        SyncWatermark.advance(to: response.maxVersion)
    }

    private func applyIncomingTodo(_ dto: Todo, in context: ModelContext) throws {
        let uuid = dto.id
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        let existing = try context.fetch(descriptor).first

        if let row = existing {
            // Tombstone? Delete locally (only if local has no unsynced edits;
            // otherwise the next push will conflict and the server response
            // will overwrite us).
            if dto.deletedAt != nil {
                context.delete(row)
                return
            }
            // Last-write-wins by updated_at: only adopt server state when
            // the server's updated_at is newer than ours. If the local row
            // has unpushed edits with a later updated_at, leave it alone —
            // the next pushOutbox() will resolve the conflict.
            if dto.updatedAt > row.updatedAt {
                row.applyServerState(dto)
            }
        } else {
            if dto.deletedAt != nil {
                // Tombstone for a row we never had locally. Skip.
                return
            }
            // New row from server.
            let row = LocalTodo(
                clientUUID: dto.id,
                title: dto.title,
                todoDescription: dto.description,
                completed: dto.completed,
                dueDate: dto.dueDate,
                tag: dto.tag,
                position: dto.position,
                version: dto.version,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt,
                deletedAt: dto.deletedAt,
                needsSync: false
            )
            context.insert(row)
        }
    }
}
