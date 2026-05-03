import Foundation
import SwiftData

/// Sync engine for the iOS local-first data layer (#14).
///
/// Two responsibilities:
///   1. **Push**: drains rows where `needsSync == true` across todos,
///      notes, lists, and note_folders, posts them to `/api/sync/upsert`,
///      and applies the server's response back into the store (so
///      server-assigned version is stamped on).
///   2. **Pull**: asks `/api/sync/changes?since_version=<watermark>` for
///      remote changes since last sync and applies them — including
///      tombstones, which delete the matching local row.
///
/// `sync()` runs push then pull, so push results don't get clobbered by
/// the pull window.
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

    func sync() async throws {
        NSLog("[SyncEngine] sync() begin")
        do {
            try await pushOutbox()
            NSLog("[SyncEngine] pushOutbox done")
            try await pullChanges()
            NSLog("[SyncEngine] pullChanges done")
        } catch {
            NSLog("[SyncEngine] sync failed: %@", String(describing: error))
            throw error
        }
    }

    // MARK: - Push

    func pushOutbox() async throws {
        let context = store.context

        // Folders go first inside the same batch so notes referencing
        // a freshly-created folder by UUID can resolve on the server.
        let pendingFolders = try context.fetch(FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.needsSync == true }
        ))
        let pendingTodos = try context.fetch(FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.needsSync == true }
        ))
        let pendingNotes = try context.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.needsSync == true }
        ))
        let pendingLists = try context.fetch(FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.needsSync == true }
        ))

        var body = SyncUpsertRequest()
        body.noteFolders = pendingFolders.map(folderToRow)
        body.todos = pendingTodos.map(todoToRow)
        body.notes = pendingNotes.map(noteToRow)
        body.lists = pendingLists.map(listToRow)

        guard !body.isEmpty else { return }

        let response: SyncUpsertResponse = try await api.post("sync/upsert", body: body)

        var todosByUUID: [UUID: LocalTodo] = [:]
        for r in pendingTodos { todosByUUID[r.clientUUID] = r }
        var foldersByUUID: [UUID: LocalNoteFolder] = [:]
        for r in pendingFolders { foldersByUUID[r.clientUUID] = r }
        var notesByUUID: [UUID: LocalNote] = [:]
        for r in pendingNotes { notesByUUID[r.clientUUID] = r }
        var listsByUUID: [UUID: LocalList] = [:]
        for r in pendingLists { listsByUUID[r.clientUUID] = r }

        for dto in response.applied.todos { todosByUUID[dto.id]?.applyServerState(dto) }
        for dto in response.applied.noteFolders { foldersByUUID[dto.id]?.applyServerState(dto) }
        for dto in response.applied.notes { notesByUUID[dto.id]?.applyServerState(dto) }
        for dto in response.applied.lists { listsByUUID[dto.id]?.applyServerState(dto) }

        for r in response.rejected.todos {
            if let server = r.serverRow { todosByUUID[r.clientUuid]?.applyServerState(server) }
        }
        for r in response.rejected.noteFolders {
            if let server = r.serverRow { foldersByUUID[r.clientUuid]?.applyServerState(server) }
        }
        for r in response.rejected.notes {
            if let server = r.serverRow { notesByUUID[r.clientUuid]?.applyServerState(server) }
        }
        for r in response.rejected.lists {
            if let server = r.serverRow { listsByUUID[r.clientUuid]?.applyServerState(server) }
        }

        try context.save()
        SyncWatermark.advance(to: response.maxVersion)
    }

    private func todoToRow(_ row: LocalTodo) -> TodoUpsertRow {
        TodoUpsertRow(
            clientUuid: row.clientUUID,
            title: row.title,
            description: row.todoDescription,
            completed: row.completed,
            dueDate: row.dueDate,
            tag: row.tag,
            position: row.position,
            deletedAt: row.deletedAt,
            updatedAt: row.updatedAt
        )
    }

    private func folderToRow(_ row: LocalNoteFolder) -> NoteFolderUpsertRow {
        NoteFolderUpsertRow(
            clientUuid: row.clientUUID,
            name: row.name,
            position: row.position,
            deletedAt: row.deletedAt,
            updatedAt: row.updatedAt
        )
    }

    private func noteToRow(_ row: LocalNote) -> NoteUpsertRow {
        NoteUpsertRow(
            clientUuid: row.clientUUID,
            folderClientUuid: row.folderClientUUID,
            title: row.title,
            content: row.content,
            position: row.position,
            deletedAt: row.deletedAt,
            updatedAt: row.updatedAt
        )
    }

    private func listToRow(_ row: LocalList) -> ListUpsertRow {
        ListUpsertRow(
            clientUuid: row.clientUUID,
            title: row.title,
            items: row.items,
            position: row.position,
            deletedAt: row.deletedAt,
            updatedAt: row.updatedAt
        )
    }

    // MARK: - Pull

    func pullChanges() async throws {
        let watermark = SyncWatermark.current
        let path = "sync/changes"
        let query = [URLQueryItem(name: "since_version", value: String(watermark))]
        let response: SyncChangesResponse = try await api.get(path, query: query)

        let context = store.context
        for dto in response.noteFolders { try applyIncomingFolder(dto, in: context) }
        for dto in response.todos { try applyIncomingTodo(dto, in: context) }
        for dto in response.notes { try applyIncomingNote(dto, in: context) }
        for dto in response.lists { try applyIncomingList(dto, in: context) }
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
            if dto.deletedAt != nil { context.delete(row); return }
            if dto.updatedAt > row.updatedAt { row.applyServerState(dto) }
        } else {
            if dto.deletedAt != nil { return }
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

    private func applyIncomingFolder(_ dto: NoteFolder, in context: ModelContext) throws {
        let uuid = dto.id
        let descriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        let existing = try context.fetch(descriptor).first

        if let row = existing {
            if dto.deletedAt != nil { context.delete(row); return }
            if dto.updatedAt > row.updatedAt { row.applyServerState(dto) }
        } else {
            if dto.deletedAt != nil { return }
            let row = LocalNoteFolder(
                clientUUID: dto.id,
                name: dto.name,
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

    private func applyIncomingNote(_ dto: Note, in context: ModelContext) throws {
        let uuid = dto.id
        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        let existing = try context.fetch(descriptor).first

        if let row = existing {
            if dto.deletedAt != nil { context.delete(row); return }
            if dto.updatedAt > row.updatedAt { row.applyServerState(dto) }
        } else {
            if dto.deletedAt != nil { return }
            let row = LocalNote(
                clientUUID: dto.id,
                folderClientUUID: dto.folderId,
                title: dto.title,
                content: dto.content,
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

    private func applyIncomingList(_ dto: Checklist, in context: ModelContext) throws {
        let uuid = dto.id
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        let existing = try context.fetch(descriptor).first

        if let row = existing {
            if dto.deletedAt != nil { context.delete(row); return }
            if dto.updatedAt > row.updatedAt { row.applyServerState(dto) }
        } else {
            if dto.deletedAt != nil { return }
            let row = LocalList(
                clientUUID: dto.id,
                title: dto.title,
                items: dto.items,
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
