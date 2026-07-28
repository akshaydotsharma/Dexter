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
    /// Notes only. Folders are NOT archivable: archiving a container raises
    /// cascade questions (does it take its notes with it? do they resurface
    /// unfiled on unarchive?) that #374 deliberately left out of scope, so
    /// `LocalNoteFolder` has no equivalent field.
    var archivedAt: Date?
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
            archivedAt: archivedAt
        )
    }
}
