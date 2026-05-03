import Foundation

/// One row of the activity timeline. Built locally by `ActivityService` from
/// the SwiftData store: each `LocalTodo / LocalNote / LocalList / LocalNoteFolder`
/// projects to one item at its `createdAt` time. Soft-deleted rows are excluded.
struct ActivityItem: Identifiable, Equatable {
    enum ItemType: String, CaseIterable {
        case note
        case todo
        case list
        case folder
    }

    /// Stable per-item identity: the entity's `clientUUID`. Two different
    /// entity types can share neither identity nor row position because the
    /// projection enforces uniqueness on (type, UUID).
    let id: UUID
    let type: ItemType
    let title: String
    let snippet: String?
    let parent: String?
    let createdAt: Date

    /// SwiftUI `ForEach` needs a stable identifier and we may show a note and
    /// a folder that share the same UUID slot in unrelated stores. Combine
    /// type + id into a single key to be safe.
    var rowKey: String { "\(type.rawValue)-\(id.uuidString.lowercased())" }
}

/// Page of activity items. `nextCursor` is null on the last page; clients
/// stop paginating when it disappears. The cursor encodes the (createdAt, type, id)
/// triple of the last row on the page so we can fetch strictly-older rows next.
struct ActivityPage: Equatable {
    let items: [ActivityItem]
    let nextCursor: String?
}
