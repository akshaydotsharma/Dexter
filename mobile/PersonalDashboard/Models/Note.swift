import Foundation

/// View-facing DTO for a folder. Identity is the clientUUID.
struct NoteFolder: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var position: Int?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case name
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }
}

/// View-facing DTO for a note. Identity is the clientUUID. The folder
/// link travels by UUID (folderId here = folder_client_uuid on the
/// server) so an offline-created note can reference an offline-created
/// folder before either has touched the server.
struct Note: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var folderId: UUID?
    var title: String?
    var content: String?
    var position: Int?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    /// When the note was archived, nil while it is active (#374). Read-only
    /// here like `deletedAt` — changed through `NoteService.setArchived`.
    /// Optional, so JSON persisted before this field existed decodes to nil.
    ///
    /// `NoteFolder` above has no equivalent: folders are not archivable.
    let archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case folderId = "folderClientUuid"
        case title
        case content
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
        case archivedAt
    }
}

struct NoteFolderCreateRequest {
    let name: String
}

struct NoteCreateRequest {
    let title: String?
    let content: String?
    let folderId: UUID?
}

struct NoteUpdateRequest {
    let title: String?
    let content: String?
    let folderId: UUID?
}
