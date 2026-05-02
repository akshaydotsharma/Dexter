import Foundation
import Observation

@Observable
@MainActor
final class NotesViewModel {
    private(set) var folders: [NoteFolder] = []
    private(set) var notes: [Note] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: NoteService

    init(service: NoteService = NoteService()) {
        self.service = service
        if let cachedFolders = CacheStore.load([NoteFolder].self, from: .noteFolders) {
            self.folders = cachedFolders
        }
        if let cachedNotes = CacheStore.load([Note].self, from: .notes) {
            self.notes = cachedNotes
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let folders = service.listFolders()
            async let notes = service.list()
            let f = try await folders
            let n = try await notes
            self.folders = f
            self.notes = n
            CacheStore.save(f, to: .noteFolders)
            CacheStore.save(n, to: .notes)
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
            let updated = try await service.renameFolder(id: folder.id, name: name)
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: NoteFolder) async {
        do {
            try await service.deleteFolder(id: folder.id)
            folders.removeAll { $0.id == folder.id }
            notes.removeAll { $0.folderId == folder.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNote(title: String?, content: String?, folderId: Int? = nil) async -> Note? {
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

    func updateNote(_ note: Note, title: String?, content: String?, folderId: Int?) async {
        do {
            let request = NoteUpdateRequest(title: title, content: content, folderId: folderId)
            let updated = try await service.update(id: note.id, request)
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteNote(_ note: Note) async {
        do {
            try await service.delete(id: note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
