import Foundation
import SwiftData

@Model
final class LocalNoteFolder {
    @Attribute(.unique) var clientUUID: UUID
    var name: String
    var position: Int?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Archive marker (#393). Same shape as `LocalNote.archivedAt` — a timestamp,
    /// optional with no non-nil default so the lightweight migration on existing
    /// installs cannot fail. Nil on every pre-existing folder.
    ///
    /// #374 left folders out of the archive because cascade was unresolved.
    /// #393 settles it: archiving a folder archives the active notes inside it
    /// and stamps each with `LocalNote.archivedWithFolderAt`, so unarchiving
    /// restores exactly that set and leaves separately-archived notes alone.
    var archivedAt: Date?
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        name: String,
        position: Int? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        archivedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
        self.needsSync = needsSync
    }

    func toDTO() -> NoteFolder {
        NoteFolder(
            id: clientUUID,
            name: name,
            position: position,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            archivedAt: archivedAt
        )
    }
}
