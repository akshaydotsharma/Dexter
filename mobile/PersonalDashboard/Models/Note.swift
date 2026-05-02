import Foundation

struct NoteFolder: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    let createdAt: Date
}

struct Note: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var folderId: Int?
    var title: String?
    var content: String?
    let createdAt: Date
    let updatedAt: Date
}

struct NoteFolderCreateRequest: Encodable {
    let name: String
}

struct NoteCreateRequest: Encodable {
    let title: String?
    let content: String?
    let folderId: Int?
}

struct NoteUpdateRequest: Encodable {
    let title: String?
    let content: String?
    let folderId: Int?
}
