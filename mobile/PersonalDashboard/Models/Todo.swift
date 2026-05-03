import Foundation

/// API-wire DTO for a todo. Maps directly to the server's `todos` row.
/// View code consumes `Todo` (or `LocalTodo` when the SwiftData store is the
/// source of truth — see `Models/Local/LocalTodo.swift`).
struct Todo: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let clientUuid: UUID
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
