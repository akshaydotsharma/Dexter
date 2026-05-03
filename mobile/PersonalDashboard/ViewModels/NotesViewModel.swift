import Foundation
import Observation
import SwiftData

/// View model for the Notes surface. Reads from SwiftData via NoteService;
/// mutations land locally and trigger a background sync push.
@Observable
@MainActor
final class NotesViewModel {
    private(set) var folders: [NoteFolder] = []
    private(set) var notes: [Note] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: NoteService

    init(service: NoteService? = nil) {
        let resolved = service ?? NoteService()
        self.service = resolved

        let folderDescriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let noteDescriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let folderRows = (try? resolved.store.context.fetch(folderDescriptor)) ?? []
        let noteRows = (try? resolved.store.context.fetch(noteDescriptor)) ?? []
        self.folders = folderRows.map { $0.toDTO() }
        self.notes = noteRows.map { $0.toDTO() }
    }

    func load(syncFirst: Bool = true) async {
        isLoading = true
        errorMessage = nil
        if syncFirst {
            do {
                try await SyncEngine.shared.sync()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        do {
            async let f = service.listFolders()
            async let n = service.list()
            self.folders = try await f
            self.notes = try await n
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func notes(in folder: NoteFolder?) -> [Note] {
        if let folder {
            return notes.filter { $0.folderId == folder.id }
        }
        return notes.filter { $0.folderId == nil }
    }

    func createFolder(name: String) async {
        do {
            let folder = try await service.createFolder(name: name)
            folders.insert(folder, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameFolder(_ folder: NoteFolder, to name: String) async {
        do {
            let updated = try await service.renameFolder(folder, to: name)
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: NoteFolder) async {
        do {
            try await service.deleteFolder(folder)
            folders.removeAll { $0.id == folder.id }
            notes.removeAll { $0.folderId == folder.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNote(title: String?, content: String?, folderId: UUID? = nil) async -> Note? {
        do {
            let request = NoteCreateRequest(title: title, content: content, folderId: folderId)
            let note = try await service.create(request)
            notes.insert(note, at: 0)
            return note
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updateNote(_ note: Note, title: String?, content: String?, folderId: UUID?) async {
        do {
            let request = NoteUpdateRequest(title: title, content: content, folderId: folderId)
            let updated = try await service.update(note, request)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteNote(_ note: Note) async {
        do {
            try await service.delete(note)
            notes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
