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
    /// When the folder was archived, nil while it is active (#393). Changed
    /// through `NoteService.setFolderArchived`, which cascades to the notes
    /// inside. Optional, so JSON persisted before this field existed decodes to
    /// nil and those folders restore as active.
    let archivedAt: Date?

    var isArchived: Bool { archivedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case name
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
        case archivedAt
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
    let archivedAt: Date?
    /// Set when this note was archived by its folder being archived rather than
    /// on its own (#393). Drives nothing in the UI; it exists so unarchiving a
    /// folder restores exactly the notes it took with it.
    let archivedWithFolderAt: Date?

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
        case archivedWithFolderAt
    }
}

/// View-facing DTO for an image attached to a note (#395). Identity is the
/// clientUUID; the note link travels by UUID for the same offline-first reason
/// `Note.folderId` does.
struct NoteImage: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let noteId: UUID
    var relativePath: String
    var position: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    /// Aspect ratio of the stored JPEG, or nil when the dimensions were never
    /// recorded. The strip falls back to a square tile in that case.
    var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case noteId = "noteClientUuid"
        case relativePath
        case position
        case pixelWidth
        case pixelHeight
        case createdAt
        case updatedAt
        case deletedAt
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
