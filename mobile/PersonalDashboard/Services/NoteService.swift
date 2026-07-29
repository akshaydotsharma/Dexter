import Foundation
import SwiftData

/// Local-first note service. Every mutation lands in SwiftData.
@MainActor
struct NoteService {
    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Folders

    /// The ACTIVE folders: not deleted and not archived (#393).
    ///
    /// `archivedAt == nil` is what keeps an archived folder out of the Notes
    /// index and out of the note detail's folder picker, the same way the note
    /// predicate below keeps archived notes out of every active surface.
    func listFolders() async throws -> [NoteFolder] {
        let descriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    /// The archived folders, most recently archived first (#393).
    func listArchivedFolders() async throws -> [NoteFolder] {
        let descriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt != nil },
            sortBy: [SortDescriptor(\.archivedAt, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    /// Archive a folder and the active notes inside it, or restore both (#393).
    ///
    /// Cascade is the whole point of the feature: putting away a finished project
    /// should take its notes with it, and leaving them active behind an archived
    /// folder would make them unreachable in the index while still counting on
    /// the Today card.
    ///
    /// Archiving stamps each cascaded note with `archivedWithFolderAt`, and
    /// unarchiving restores exactly that set. A note the user had archived on its
    /// own beforehand carries no marker, so it stays archived and shows up in the
    /// folder's own archive rather than resurfacing in the folder.
    func setFolderArchived(_ folder: NoteFolder, _ archived: Bool) async throws {
        let row = try fetchLocalFolder(uuid: folder.id)
        let now = Date()
        let folderUUID = folder.id

        if archived {
            row.archivedAt = now
            let activeChildren = FetchDescriptor<LocalNote>(
                predicate: #Predicate {
                    $0.folderClientUUID == folderUUID && $0.deletedAt == nil && $0.archivedAt == nil
                }
            )
            for child in try store.context.fetch(activeChildren) {
                child.archivedAt = now
                child.archivedWithFolderAt = now
                child.updatedAt = now
            }
        } else {
            row.archivedAt = nil
            let cascadedChildren = FetchDescriptor<LocalNote>(
                predicate: #Predicate {
                    $0.folderClientUUID == folderUUID && $0.deletedAt == nil && $0.archivedWithFolderAt != nil
                }
            )
            for child in try store.context.fetch(cascadedChildren) {
                child.archivedAt = nil
                child.archivedWithFolderAt = nil
                child.updatedAt = now
            }
        }

        row.updatedAt = now
        try store.context.save()
    }

    func createFolder(name: String) async throws -> NoteFolder {
        let row = LocalNoteFolder(name: name)
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    func renameFolder(_ folder: NoteFolder, to name: String) async throws -> NoteFolder {
        let row = try fetchLocalFolder(uuid: folder.id)
        row.name = name
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    func deleteFolder(_ folder: NoteFolder) async throws {
        let row = try fetchLocalFolder(uuid: folder.id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        // Soft-cascade to child notes so the iOS view immediately stops showing them.
        let folderUUID = folder.id
        let childDescriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.folderClientUUID == folderUUID && $0.deletedAt == nil }
        )
        let children = try store.context.fetch(childDescriptor)
        for child in children {
            child.deletedAt = Date()
            child.updatedAt = Date()
        }
        try store.context.save()
    }

    // MARK: - Notes

    /// The ACTIVE notes: not deleted and not archived (#374).
    ///
    /// `archivedAt == nil` is what keeps archived notes out of the Notes index,
    /// out of each folder's note list, and out of the Today card, all of which
    /// read through `NotesViewModel.notes`. The archive has its own accessor.
    func list(folderId: UUID? = nil) async throws -> [Note] {
        let descriptor: FetchDescriptor<LocalNote>
        if let folderId {
            descriptor = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil && $0.folderClientUUID == folderId },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }
        let rows = try store.context.fetch(descriptor)
        return rows.map { $0.toDTO() }
    }

    /// The archived notes, most recently archived first (#374).
    ///
    /// Flat across folders on purpose: the archive is one place you go to find
    /// something you put away, not a second copy of the folder tree. A note
    /// keeps its `folderClientUUID` while archived, so unarchiving returns it to
    /// the folder it came from.
    func listArchived() async throws -> [Note] {
        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt != nil },
            sortBy: [SortDescriptor(\.archivedAt, order: .reverse)]
        )
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
            updatedAt: now
        )
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    func update(_ note: Note, _ request: NoteUpdateRequest) async throws -> Note {
        let row = try fetchLocalNote(uuid: note.id)
        if let title = request.title { row.title = title }
        if let content = request.content { row.content = content }
        if let folderId = request.folderId { row.folderClientUUID = folderId }
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    /// Archive or restore a note (#374). Touches `archivedAt` only, rather than
    /// going through `update(_:_:)` — see `ChecklistService.setArchived` for the
    /// reasoning.
    func setArchived(_ note: Note, _ archived: Bool) async throws {
        let row = try fetchLocalNote(uuid: note.id)
        row.archivedAt = archived ? Date() : nil
        // Either direction is an individual decision about this one note, so it
        // is no longer part of any folder cascade (#393). Clearing on archive
        // matters: without it, a note archived by hand inside a folder that was
        // later archived and unarchived would come back with the folder.
        row.archivedWithFolderAt = nil
        row.updatedAt = Date()
        try store.context.save()
    }

    func delete(_ note: Note) async throws {
        let row = try fetchLocalNote(uuid: note.id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
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
}
