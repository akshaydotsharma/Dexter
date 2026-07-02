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
        /// One `LocalItineraryItem`. Deep-links into its owning trip.
        case itinerary
        /// One standalone `LocalExpense` (manual / chat / voice / photo /
        /// email receipt). Deep-links into Finance.
        case expense
        /// A collapsed PDF statement import: many `LocalExpense` rows sharing a
        /// `statementLabel` render as ONE row so a single upload doesn't
        /// explode the feed. Deep-links into Finance.
        case statement
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

    /// Deep-link target for `.itinerary` rows: the `LocalTrip.clientUUID` the
    /// tapped item belongs to. The Activity tap handler routes to Itineraries
    /// and focuses this trip. `nil` for every other type.
    let tripUUID: UUID?

    /// Stable identity token for rows that don't map 1:1 to a single entity.
    /// `.statement` rows collapse many `LocalExpense`s sharing a
    /// `statementLabel` into one row, so their identity is the label rather
    /// than any single expense UUID. `nil` for every 1:1 row (which key off
    /// `id`). Keeps `rowKey` unique + stable across recomputes of the feed.
    let groupKey: String?

    init(
        id: UUID,
        type: ItemType,
        title: String,
        snippet: String?,
        parent: String?,
        sortDate: Date,
        createdAt: Date,
        tripUUID: UUID? = nil,
        groupKey: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.snippet = snippet
        self.parent = parent
        self.sortDate = sortDate
        self.createdAt = createdAt
        self.tripUUID = tripUUID
        self.groupKey = groupKey
    }

    var rowKey: String {
        if let groupKey { return "\(type.rawValue)-\(groupKey)" }
        return "\(type.rawValue)-\(id.uuidString)"
    }
}
