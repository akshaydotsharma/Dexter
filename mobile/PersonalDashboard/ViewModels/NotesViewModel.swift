import Foundation
import Observation
import SwiftData
// For `withAnimation` when a note moves between the index and the archive (#374).
import SwiftUI

/// View model for the Notes surface. Reads from SwiftData via NoteService;
/// mutations land locally in the SwiftData store.
@Observable
@MainActor
final class NotesViewModel {
    private(set) var folders: [NoteFolder] = []
    /// The ACTIVE notes. Keeps its original meaning — "the notes you see" — which
    /// is what makes `TodayView`'s notes card and `notes(in:)` correct with no
    /// change to either (#374).
    private(set) var notes: [Note] = []
    /// The archived notes, most recently archived first, flat across folders.
    /// Consumed only by the Archive branch of `NotesView`.
    private(set) var archivedNotes: [Note] = []
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
        // Mirrors `NoteService.list()`: active means neither deleted nor
        // archived. Folders have no archived state, so their descriptor above is
        // unchanged.
        let noteDescriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let folderRows = (try? resolved.store.context.fetch(folderDescriptor)) ?? []
        let noteRows = (try? resolved.store.context.fetch(noteDescriptor)) ?? []
        self.folders = folderRows.map { $0.toDTO() }
        self.notes = noteRows.map { $0.toDTO() }
    }

    /// Read/write access to a note by id, regardless of which collection holds
    /// it (#374).
    ///
    /// Same reasoning as `ListsViewModel`'s equivalent: an archived note opened
    /// from the Archive is absent from `notes`, so an edit keyed on
    /// `notes.firstIndex` would silently do nothing while the editor showed the
    /// change as saved.
    private subscript(id id: UUID) -> Note? {
        get { notes.first { $0.id == id } ?? archivedNotes.first { $0.id == id } }
        set {
            guard let newValue else { return }
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = newValue
            } else if let index = archivedNotes.firstIndex(where: { $0.id == id }) {
                archivedNotes[index] = newValue
            }
        }
    }

    /// Resolve a note by id across BOTH collections, so a note opened from the
    /// Archive still resolves in the detail branch.
    func note(id: UUID) -> Note? { self[id: id] }

    func load() async {
        isLoading = true
        do {
            async let f = service.listFolders()
            async let n = service.list()
            async let a = service.listArchived()
            self.folders = try await f
            self.notes = try await n
            self.archivedNotes = try await a
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Notes in a folder, or the unfiled ones when `folder` is nil. Reads
    /// `notes`, which is active-only, so archived notes are absent here by
    /// construction — a folder's note list and its count both skip them.
    func notes(in folder: NoteFolder?) -> [Note] {
        if let folder {
            return notes.filter { $0.folderId == folder.id }
        }
        return notes.filter { $0.folderId == nil }
    }

    /// Archive a note, or restore it to wherever it came from (#374).
    ///
    /// An archived note keeps its `folderClientUUID`, so unarchiving puts it back
    /// in its original folder rather than dumping it into Unfiled.
    func setArchived(_ note: Note, _ archived: Bool) async {
        do {
            try await service.setArchived(note, archived)
            async let active = service.list()
            async let archivedRows = service.listArchived()
            let nextActive = try await active
            let nextArchived = try await archivedRows
            withAnimation(.easeOut(duration: 0.2)) {
                notes = nextActive
                archivedNotes = nextArchived
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
            // The service's soft-cascade deletes every note in the folder,
            // archived ones included, so the archive has to drop them too (#374).
            archivedNotes.removeAll { $0.folderId == folder.id }
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
            self[id: note.id] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteNote(_ note: Note) async {
        do {
            try await service.delete(note)
            notes.removeAll { $0.id == note.id }
            // Delete is reachable from the Archive's swipe too (#374).
            archivedNotes.removeAll { $0.id == note.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
