import Foundation

struct ChecklistItem: Codable, Hashable, Sendable {
    var text: String
    var checked: Bool

    init(text: String, checked: Bool = false) {
        self.text = text
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case checked
        case completed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
        try c.encode(text, forKey: .text)
        try c.encode(checked, forKey: .checked)
    }
}

struct Checklist: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var items: [ChecklistItem]
    let createdAt: Date
}

struct ChecklistCreateRequest: Encodable {
    let title: String
    let items: [ChecklistItem]
}

struct ChecklistUpdateRequest: Encodable {
    let title: String
    let items: [ChecklistItem]
}
