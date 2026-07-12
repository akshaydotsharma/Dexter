import Foundation

/// View-facing DTO for a todo. Identity is the `clientUUID` (here exposed
/// as `id` for Identifiable conformance), which is the sync key shared with
/// the server. The server's integer primary key is kept inside `LocalTodo`
/// for sync internals and never bubbles up to views — this lets locally
/// created todos render correctly before they have ever reached the server.
struct Todo: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity, matches `LocalTodo.clientUUID` and the server's
    /// `client_uuid` column.
    let id: UUID
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

    /// Optional street / postal address. Local-only (the server schema has no
    /// column for it), so it is omitted from `CodingKeys` and carries a default
    /// — Codable synthesis skips it on encode/decode and uses "" instead.
    var address: String = ""

    /// Optional Google Maps URL. Local-only, same handling as `address`.
    var googleMapsLink: String = ""

    /// Task priority as a raw `Int` (see `TaskPriority`). Local-only, same
    /// handling as `address`/`googleMapsLink`: defaulted and omitted from
    /// `CodingKeys` so the server sync contract is untouched.
    var priority: Int = 0

    /// Typed view of `priority` for the UI. Unknown raw values fall back to
    /// `.none` so a bad stored value never renders a blank/missing bar.
    var taskPriority: TaskPriority { TaskPriority(rawValue: priority) ?? .none }

    /// Server JSON has both `id` (int) and `client_uuid`; we map our `id`
    /// to `client_uuid` and ignore the server's int. The decoder's
    /// `.convertFromSnakeCase` strategy turns `client_uuid` into
    /// `clientUuid`, which is what the explicit raw value below matches.
    /// `address` / `googleMapsLink` are intentionally absent: they are local
    /// fields the server doesn't know about.
    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case title
        case description
        case completed
        case dueDate
        case tag
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }

    /// The stored Google Maps URL, coercing a bare host (e.g.
    /// "maps.app.goo.gl/…") into an https URL. `nil` when no link is saved or
    /// the stored string can't form a URL — the row hides the MAP chip then.
    var mapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let url = URL(string: stored), url.scheme != nil { return url }
        return URL(string: "https://\(stored)")
    }
}

struct TodoCreateRequest: Encodable {
    let title: String
    let description: String?
    let dueDate: Date?
    let tag: String?
    var address: String = ""
    var googleMapsLink: String = ""
    var priority: Int = 0
}

struct TodoUpdateRequest: Encodable {
    let title: String?
    let description: String?
    let completed: Bool?
    let dueDate: Date?
    let tag: String?
    /// `nil` leaves the stored value untouched; a value (incl. "") overwrites.
    var address: String? = nil
    var googleMapsLink: String? = nil
    /// `nil` leaves the stored priority untouched; a value overwrites it.
    var priority: Int? = nil
}
