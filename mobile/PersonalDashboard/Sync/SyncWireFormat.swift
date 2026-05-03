import Foundation

/// Wire DTOs for the sync endpoints (`/api/sync/changes`, `/api/sync/upsert`).
/// Names mirror the server JSON, so APIClient.decoder/encoder snake-case
/// conversion does the rest.

struct SyncChangesResponse: Decodable {
    let todos: [Todo]
    // Notes / lists / note_folders fields are present on the wire but iOS
    // does not consume them yet (Phase 5/6). Decoded as a passthrough so
    // the response still parses.
    let maxVersion: Int64

    enum CodingKeys: String, CodingKey {
        case todos
        case maxVersion = "max_version"
    }
}

/// Body for `POST /api/sync/upsert`. Each table is a separate array so the
/// server can route per-table without inferring entity type.
struct SyncUpsertRequest: Encodable {
    var todos: [TodoUpsertRow]

    enum CodingKeys: String, CodingKey {
        case todos
    }
}

/// One row in a sync upsert batch. Carries client_uuid + updated_at + the
/// fields the client wants to write. nil-valued fields are omitted via the
/// optional encoding so the server's schema-driven upsert leaves them alone.
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

    enum CodingKeys: String, CodingKey {
        case clientUuid = "client_uuid"
        case title
        case description
        case completed
        case dueDate = "due_date"
        case tag
        case position
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
    }
}

struct SyncUpsertResponse: Decodable {
    let applied: AppliedRows
    let rejected: RejectedRows
    let maxVersion: Int64

    struct AppliedRows: Decodable {
        let todos: [Todo]
    }

    struct RejectedRows: Decodable {
        let todos: [RejectedRow]
    }

    struct RejectedRow: Decodable {
        let clientUuid: UUID
        let reason: String
        /// When the server wins, it returns the current row so the client
        /// can adopt it without a separate GET.
        let serverRow: Todo?

        enum CodingKeys: String, CodingKey {
            case clientUuid = "client_uuid"
            case reason
            case serverRow = "server_row"
        }
    }

    enum CodingKeys: String, CodingKey {
        case applied
        case rejected
        case maxVersion = "max_version"
    }
}
