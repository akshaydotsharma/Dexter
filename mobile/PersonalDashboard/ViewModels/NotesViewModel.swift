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
    /// The ACTIVE folders. Same contract as `notes` below: "the folders you see".
    private(set) var folders: [NoteFolder] = []
    /// The archived folders, most recently archived first (#393). Consumed by the
    /// root Archive, which lists them above the archived unfiled notes.
    private(set) var archivedFolders: [NoteFolder] = []
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

        // Mirrors `NoteService.listFolders()`: archived folders are excluded here
        // too (#393), so the first frame after launch does not flash a folder the
        // user has put away.
        let folderDescriptor = FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        // Mirrors `NoteService.list()`: active means neither deleted nor
        // archived.
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

    /// Resolve a folder by id across both collections (#393), so the note detail
    /// can still name the folder of a note it opened from the Archive instead of
    /// falling back to "Unfiled".
    func folder(id: UUID) -> NoteFolder? {
        folders.first { $0.id == id } ?? archivedFolders.first { $0.id == id }
    }

    func load() async {
        isLoading = true
        do {
            async let f = service.listFolders()
            async let af = service.listArchivedFolders()
            async let n = service.list()
            async let a = service.listArchived()
            self.folders = try await f
            self.archivedFolders = try await af
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

    /// The archive counterpart of `notes(in:)` (#393).
    ///
    /// The Archive is scoped to the screen it was opened from: the root shows
    /// archived folders plus the archived UNFILED notes, and a folder shows its
    /// own archived notes. `archivedNotes` stays flat so `note(id:)` can resolve
    /// anything the detail view is handed; the split happens here.
    func archivedNotes(in folder: NoteFolder?) -> [Note] {
        if let folder {
            return archivedNotes.filter { $0.folderId == folder.id }
        }
        return archivedNotes.filter { $0.folderId == nil }
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

    /// Archive a folder together with the active notes inside it, or restore both
    /// (#393).
    ///
    /// Reloads all four collections rather than moving items between them by
    /// hand: the cascade touches an unbounded number of notes, and re-deriving
    /// from the store is the only version of this that cannot drift from what
    /// `NoteService` actually wrote.
    func setFolderArchived(_ folder: NoteFolder, _ archived: Bool) async {
        do {
            try await service.setFolderArchived(folder, archived)
            async let activeFolders = service.listFolders()
            async let archivedFolderRows = service.listArchivedFolders()
            async let activeNotes = service.list()
            async let archivedRows = service.listArchived()
            let nextFolders = try await activeFolders
            let nextArchivedFolders = try await archivedFolderRows
            let nextNotes = try await activeNotes
            let nextArchivedNotes = try await archivedRows
            withAnimation(.easeOut(duration: 0.2)) {
                folders = nextFolders
                archivedFolders = nextArchivedFolders
                notes = nextNotes
                archivedNotes = nextArchivedNotes
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
            // Delete is reachable from the root Archive's folder rows too (#393).
            archivedFolders.removeAll { $0.id == folder.id }
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
