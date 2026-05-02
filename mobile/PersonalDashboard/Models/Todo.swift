import Foundation

struct Todo: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var description: String?
    var completed: Bool
    var dueDate: Date?
    var tag: String?
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
