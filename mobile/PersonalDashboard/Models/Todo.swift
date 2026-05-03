import Foundation

/// View-facing DTO for a todo. Identity is the `clientUUID` (here exposed
/// as `id` for Identifiable conformance), which is the sync key shared with
/// the server. The server's integer primary key is kept inside `LocalTodo`
/// for sync internals and never bubbles up to views — this lets locally
/// created todos render correctly before they have ever reached the server.
struct Todo: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, matches `LocalTodo.clientUUID` and the server's
    /// `client_uuid` column.
    let id: UUID
    var title: String
    var description: String?
    var completed: Bool
    var dueDate: Date?
    var tag: String?
    var position: Int?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    /// Server JSON has both `id` (int) and `client_uuid`; we map our `id`
    /// to `client_uuid` and ignore the server's int. The decoder's
    /// `.convertFromSnakeCase` strategy turns `client_uuid` into
    /// `clientUuid`, which is what the explicit raw value below matches.
    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case title
        case description
        case completed
        case dueDate
        case tag
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }
}

struct TodoCreateRequest: Encodable {
    let title: String
    let description: String?
    let dueDate: Date?
    let tag: String?
}

struct TodoUpdateRequest: Encodable {
    let title: String?
    let description: String?
    let completed: Bool?
    let dueDate: Date?
    let tag: String?
}
