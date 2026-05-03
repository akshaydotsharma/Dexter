import Foundation
import SwiftData

/// Local-first note service. Mirrors `TodoService` pattern: every
/// mutation lands in SwiftData first, gets flagged needsSync, and the
/// SyncEngine pushes to the server in the background.
@MainActor
struct NoteService {
    let store: SwiftDataStore
    let syncEngine: SyncEngine

    init(store: SwiftDataStore = .shared, syncEngine: SyncEngine = .shared) {
        self.store = store
        self.syncEngine = syncEngine
    }

    // MARK: - Folders

    func listFolders() async throws -> [NoteFolder] {
        let descriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    func createFolder(name: String) async throws -> NoteFolder {
        let row = LocalNoteFolder(name: name, needsSync: true)
        store.context.insert(row)
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    func renameFolder(_ folder: NoteFolder, to name: String) async throws -> NoteFolder {
        let row = try fetchLocalFolder(uuid: folder.id)
        row.name = name
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    func deleteFolder(_ folder: NoteFolder) async throws {
        let row = try fetchLocalFolder(uuid: folder.id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        row.needsSync = true
        // Soft-cascade to child notes so the iOS view immediately stops
        // showing them. The server's folder delete also cascades, so
        // post-sync state matches.
        let folderUUID = folder.id
        let childDescriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.folderClientUUID == folderUUID && $0.deletedAt == nil }
        )
        let children = try store.context.fetch(childDescriptor)
        for child in children {
            child.deletedAt = Date()
            child.updatedAt = Date()
            child.needsSync = true
        }
        try store.context.save()
        kickSync()
    }

    // MARK: - Notes

    func list(folderId: UUID? = nil) async throws -> [Note] {
        let descriptor: FetchDescriptor<LocalNote>
        if let folderId {
            descriptor = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil && $0.folderClientUUID == folderId },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    func create(_ request: NoteCreateRequest) async throws -> Note {
        let now = Date()
        let row = LocalNote(
            folderClientUUID: request.folderId,
            title: request.title,
            content: request.content,
            createdAt: now,
            updatedAt: now,
            needsSync: true
        )
        store.context.insert(row)
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    func update(_ note: Note, _ request: NoteUpdateRequest) async throws -> Note {
        let row = try fetchLocalNote(uuid: note.id)
        if let title = request.title { row.title = title }
        if let content = request.content { row.content = content }
        if let folderId = request.folderId { row.folderClientUUID = folderId }
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
        return row.toDTO()
    }

    func delete(_ note: Note) async throws {
        let row = try fetchLocalNote(uuid: note.id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        row.needsSync = true
        try store.context.save()
        kickSync()
    }

    // MARK: - Internals

    private func fetchLocalFolder(uuid: UUID) throws -> LocalNoteFolder {
        let descriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        guard let row = try store.context.fetch(descriptor).first else {
            throw APIError.notFound
        }
        return row
    }

    private func fetchLocalNote(uuid: UUID) throws -> LocalNote {
        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        guard let row = try store.context.fetch(descriptor).first else {
            throw APIError.notFound
        }
        return row
    }

    private func kickSync() {
        Task { @MainActor in try? await syncEngine.sync() }
    }
}
