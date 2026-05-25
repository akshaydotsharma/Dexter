import Foundation

struct ChecklistItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable per-item identity. Used by SwiftUI ForEach so that toggle-driven
    /// reorders (active items first, completed at the bottom) animate cleanly
    /// instead of cross-fading on index changes. Items persisted before this
    /// field existed get a fresh UUID at decode time — see `init(from:)`.
    var id: UUID
    var text: String
    var checked: Bool

    init(id: UUID = UUID(), text: String, checked: Bool = false) {
        self.id = id
        self.text = text
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case checked
        case completed
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(checked, forKey: .checked)
    }
}

/// View-facing DTO for a checklist. Identity is the clientUUID.
struct Checklist: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var items: [ChecklistItem]
    var position: Int?
    let version: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id = "clientUuid"
        case title
        case items
        case position
        case version
        case createdAt
        case updatedAt
        case deletedAt
    }
}

struct ChecklistCreateRequest {
    let title: String
    let items: [ChecklistItem]
}

struct ChecklistUpdateRequest {
    let title: String
    let items: [ChecklistItem]
}
