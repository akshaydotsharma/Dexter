import Foundation

/// One row from `GET /api/dashboard/activity`. Server identity is the integer
/// `id`; type discriminates the entity. The activity surface is read-only:
/// the iOS app never writes to this endpoint.
struct ActivityItem: Decodable, Identifiable, Equatable {
    enum ItemType: String, Decodable, CaseIterable {
        case note
        case todo
        case list
        case folder
    }

    let id: Int
    let type: ItemType
    let title: String
    let snippet: String?
    let parent: String?
    let createdAt: Date

    /// SwiftUI `ForEach` needs a stable identifier and we may show the same
    /// integer id for two different types in the same feed (a note id 5 and a
    /// folder id 5). Combine the two into a string key.
    var rowKey: String { "\(type.rawValue)-\(id)" }
}

/// Payload returned by the activity endpoint. `nextCursor` is null on the
/// last page; clients stop paginating when it disappears.
struct ActivityPage: Decodable {
    let items: [ActivityItem]
    let nextCursor: String?
}
