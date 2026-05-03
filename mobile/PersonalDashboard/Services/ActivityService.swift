import Foundation

/// Read-only client for the activity timeline endpoint.
///
/// The activity feed is server-driven (UNION across todos, notes, lists,
/// note_folders) rather than reading from the local SwiftData store, so the
/// surface always reflects what's actually on the Mac. There is no offline
/// fallback in v1: if the request fails, the view shows an empty/error
/// state and the user can pull to refresh.
struct ActivityService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    /// Fetch one page of activity. Pass `cursor` (the value from the previous
    /// page's `nextCursor`) to load the next page; pass `type` to filter to
    /// a single entity type.
    func page(cursor: String? = nil, type: ActivityItem.ItemType? = nil, limit: Int = 50) async throws -> ActivityPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let type { query.append(URLQueryItem(name: "type", value: type.rawValue)) }
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        return try await api.get("dashboard/activity", query: query)
    }
}
