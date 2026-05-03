import Foundation

/// Wire DTOs for the sync endpoints (`/api/sync/changes`, `/api/sync/upsert`).
///
/// `APIClient.decoder` uses `.convertFromSnakeCase` and `APIClient.encoder`
/// uses `.convertToSnakeCase`. With those strategies in place, snake_case
/// keys on the server map automatically to camelCase property names — so
/// these DTOs DELIBERATELY do not declare CodingKeys with explicit
/// snake_case raw values. The strategy converts the JSON key first; the
/// CodingKey lookup runs against the converted (camelCase) form, which
/// means raw values like `"max_version"` would fail to match. Default
/// CodingKeys are correct here.

struct SyncChangesResponse: Decodable {
    let todos: [Todo]
    let notes: [Note]
    let lists: [Checklist]
    let noteFolders: [NoteFolder]
    let maxVersion: Int64
}

/// Body for `POST /api/sync/upsert`. Each table is a separate array so the
/// server can route per-table without inferring entity type.
struct SyncUpsertRequest: Encodable {
    var todos: [TodoUpsertRow] = []
    var notes: [NoteUpsertRow] = []
    var lists: [ListUpsertRow] = []
    var noteFolders: [NoteFolderUpsertRow] = []

    var isEmpty: Bool {
        todos.isEmpty && notes.isEmpty && lists.isEmpty && noteFolders.isEmpty
    }
}

/// One row in a sync upsert batch. Carries clientUuid + updatedAt + the
/// fields the client wants to write. nil-valued fields are omitted by
/// default Encodable behaviour, which lets the server's schema-driven
/// upsert leave them alone.
struct TodoUpsertRow: Encodable {
    let clientUuid: UUID
    let title: String?
    let description: String?
    let completed: Bool?
    let dueDate: Date?
    let tag: String?
    let position: Int?
    let deletedAt: Date?
    let updatedAt: Date
}

struct NoteFolderUpsertRow: Encodable {
    let clientUuid: UUID
    let name: String?
    let position: Int?
    let deletedAt: Date?
    let updatedAt: Date
}

struct NoteUpsertRow: Encodable {
    let clientUuid: UUID
    /// Maps to server's `folder_client_uuid`. Nil clears the folder
    /// assignment (note becomes unfiled).
    let folderClientUuid: UUID?
    let title: String?
    let content: String?
    let position: Int?
    let deletedAt: Date?
    let updatedAt: Date
}

struct ListUpsertRow: Encodable {
    let clientUuid: UUID
    let title: String?
    let items: [ChecklistItem]?
    let position: Int?
    let deletedAt: Date?
    let updatedAt: Date
}

struct SyncUpsertResponse: Decodable {
    let applied: AppliedRows
    let rejected: RejectedRows
    let maxVersion: Int64

    struct AppliedRows: Decodable {
        let todos: [Todo]
        let notes: [Note]
        let lists: [Checklist]
        let noteFolders: [NoteFolder]
    }

    struct RejectedRows: Decodable {
        let todos: [RejectedRow<Todo>]
        let notes: [RejectedRow<Note>]
        let lists: [RejectedRow<Checklist>]
        let noteFolders: [RejectedRow<NoteFolder>]
    }

    struct RejectedRow<Row: Decodable>: Decodable {
        let clientUuid: UUID
        let reason: String
        /// When the server wins, it returns the current row so the client
        /// can adopt it without a separate GET.
        let serverRow: Row?
    }
}
