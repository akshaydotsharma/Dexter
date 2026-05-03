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
            deletedAt: deletedAt
        )
    }
}
