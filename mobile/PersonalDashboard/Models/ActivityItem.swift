import Foundation

/// One row in the Activity feed. The feed is built locally from the SwiftData
/// store, so identity is the entity's `clientUUID`. Two different types may
/// share an identifier (a note and a folder both with the same UUID is
/// theoretically possible) so `rowKey` combines type + id for SwiftUI diffing.
struct ActivityItem: Identifiable, Equatable {
    enum ItemType: String, CaseIterable {
        case note
        case todo
        case list
        case folder
    }

    let id: UUID
    let type: ItemType
    let title: String
    let snippet: String?
    let parent: String?
    /// Sort key. We use the later of `createdAt` / `updatedAt` so edits and
    /// nested-item additions (e.g. a new checklist item) bubble the parent to
    /// the top of the feed without inventing a separate event row.
    let sortDate: Date
    /// Original creation timestamp for day-grouping and "1h ago" rendering.
    let createdAt: Date

    var rowKey: String { "\(type.rawValue)-\(id.uuidString)" }
}
