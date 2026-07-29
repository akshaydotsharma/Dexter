import Foundation
import SwiftData

@Model
final class LocalNote {
    @Attribute(.unique) var clientUUID: UUID
    /// Folder link by UUID, mapping to the server's folder_client_uuid
    /// column. Nil for notes outside any folder ("unfiled").
    var folderClientUUID: UUID?
    var title: String?
    var content: String?
    var position: Int?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Archive marker (#374). Mirrors `LocalList.archivedAt` exactly — a
    /// timestamp, optional with no non-nil default so the lightweight migration
    /// on existing installs cannot fail. Nil on every pre-existing note.
    ///
    /// #393 made folders archivable too, and archiving one cascades to the notes
    /// inside it — see `archivedWithFolderAt` below for how the cascade is undone.
    var archivedAt: Date?
    /// Set alongside `archivedAt` when this note was archived as part of its
    /// FOLDER being archived, rather than on its own (#393).
    ///
    /// This is what makes unarchiving a folder reversible in the way a user
    /// expects: restoring the folder clears `archivedAt` only on the notes it
    /// took with it, so a note the user had already archived by itself stays
    /// archived. Stored rather than inferred — comparing timestamps to the
    /// folder's `archivedAt` would rest on Date equality surviving a JSON round
    /// trip through the archive and the sync oplog.
    ///
    /// Always nil while the note is active, and always cleared when the note is
    /// archived or unarchived individually.
    var archivedWithFolderAt: Date?
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        folderClientUUID: UUID? = nil,
        title: String? = nil,
        content: String? = nil,
        position: Int? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        archivedAt: Date? = nil,
        archivedWithFolderAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.folderClientUUID = folderClientUUID
        self.title = title
        self.content = content
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
        self.archivedWithFolderAt = archivedWithFolderAt
        self.needsSync = needsSync
    }

    func toDTO() -> Note {
        Note(
            id: clientUUID,
            folderId: folderClientUUID,
            title: title,
            content: content,
            position: position,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            archivedAt: archivedAt,
            archivedWithFolderAt: archivedWithFolderAt
        )
    }
}
