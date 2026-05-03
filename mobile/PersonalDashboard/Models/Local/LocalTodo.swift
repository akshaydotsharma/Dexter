import Foundation
import SwiftData

/// Local-first SwiftData model for a todo. The phone treats this as the
/// source of truth: every create/update/delete writes here first, then the
/// `SyncEngine` pushes pending changes to the server and pulls remote
/// changes back. `clientUUID` is the stable identity across the network —
/// the server keeps an integer `id` but the iOS layer only ever keys on UUID.
@Model
final class LocalTodo {
    /// Stable identity. Generated locally on creation; the server adopts it
    /// on first sync. Unique within the SwiftData store.
    @Attribute(.unique) var clientUUID: UUID

    /// Server-assigned integer id, populated after the first successful sync.
    /// nil for rows that exist locally but have not yet been pushed.
    var serverID: Int?

    var title: String
    var todoDescription: String?
    var completed: Bool
    var dueDate: Date?
    var tag: String?
    var position: Int?

    /// Server-assigned monotonic version. 0 if never synced.
    var version: Int64

    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    /// True when this row has unpushed local changes. The sync engine drains
    /// the set of `needsSync == true` rows on every push cycle.
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        serverID: Int? = nil,
        title: String,
        todoDescription: String? = nil,
        completed: Bool = false,
        dueDate: Date? = nil,
        tag: String? = nil,
        position: Int? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.serverID = serverID
        self.title = title
        self.todoDescription = todoDescription
        self.completed = completed
        self.dueDate = dueDate
        self.tag = tag
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsSync = needsSync
    }

    /// Adopt server state into the local row. Used by SyncEngine when
    /// applying delta from `/api/sync/changes`. Clears `needsSync` because
    /// the row now matches the server.
    func applyServerState(_ dto: Todo) {
        self.serverID = dto.id
        self.title = dto.title
        self.todoDescription = dto.description
        self.completed = dto.completed
        self.dueDate = dto.dueDate
        self.tag = dto.tag
        self.position = dto.position
        self.version = dto.version
        self.createdAt = dto.createdAt
        self.updatedAt = dto.updatedAt
        self.deletedAt = dto.deletedAt
        self.needsSync = false
    }

    /// Project to the API-wire DTO for legacy view-model consumption while
    /// the migration is in flight. ViewModels that read `[Todo]` keep working.
    func toDTO() -> Todo {
        Todo(
            id: serverID ?? 0,
            clientUuid: clientUUID,
            title: title,
            description: todoDescription,
            completed: completed,
            dueDate: dueDate,
            tag: tag,
            position: position,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
