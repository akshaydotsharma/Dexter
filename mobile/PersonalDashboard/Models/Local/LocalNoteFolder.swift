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
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        name: String,
        position: Int? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
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
            deletedAt: deletedAt
        )
    }
}
