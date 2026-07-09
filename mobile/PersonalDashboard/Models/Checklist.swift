import Foundation

struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable per-item identity. Used by SwiftUI ForEach so that toggle-driven
    /// reorders (active items first, completed at the bottom) animate cleanly
    /// instead of cross-fading on index changes. Items persisted before this
    /// field existed get a fresh UUID at decode time — see `init(from:)`.
    var id: UUID
    var text: String
    var checked: Bool
    /// Optional per-item link. Defaults to "" and is decoded with
    /// `decodeIfPresent ?? ""` so JSON persisted before this field existed
    /// still loads. Same forward-compatible shape as `id`.
    var url: String

    init(id: UUID = UUID(), text: String, checked: Bool = false, url: String = "") {
        self.id = id
        self.text = text
        self.checked = checked
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case checked
        case completed
        case url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Old persisted JSON has no `id` field. Generate one on the fly so
        // existing lists keep loading instead of throwing. Same defensive
        // shape LocalList.decode already uses (fallback to [] on failure).
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        // Server uses either "checked" or "completed" depending on the row.
        if let v = try c.decodeIfPresent(Bool.self, forKey: .checked) {
            self.checked = v
        } else if let v = try c.decodeIfPresent(Bool.self, forKey: .completed) {
            self.checked = v
        } else {
            self.checked = false
        }
        // Missing on all existing rows — default to "" so decode never throws.
        self.url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(checked, forKey: .checked)
        try c.encode(url, forKey: .url)
    }

    /// The stored link coerced into a URL: trims whitespace, returns nil when
    /// empty, uses the string as-is if it already carries a scheme, otherwise
    /// prefixes `https://`. Mirrors `Todo.mapsURL`. The row hides the link chip
    /// when this is nil.
    var linkURL: URL? {
        let stored = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let u = URL(string: stored), u.scheme != nil { return u }
        return URL(string: "https://\(stored)")
    }
}

/// View-facing DTO for a checklist. Identity is the clientUUID.
struct Checklist: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var items: [ChecklistItem]
    var position: Int?
    /// Per-list visual identity (#253). `iconName` is an SF Symbol name,
    /// `colorHex` a palette key. Both optional; nil falls back to the default
    /// checklist symbol + teal via `ListAppearance`.
    var iconName: String?
    var colorHex: String?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case title
        case items
        case position
        case iconName
        case colorHex
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }
}

struct ChecklistCreateRequest {
    let title: String
    let items: [ChecklistItem]
    var iconName: String? = nil
    var colorHex: String? = nil
}

struct ChecklistUpdateRequest {
    let title: String
    let items: [ChecklistItem]
    var iconName: String? = nil
    var colorHex: String? = nil
}
