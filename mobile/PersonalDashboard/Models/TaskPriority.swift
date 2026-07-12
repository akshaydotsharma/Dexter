import Foundation

/// Priority level for a task. Local-only concept — the server sync contract has
/// no column for it, so it lives on `LocalTodo.priority` as the raw `Int` and is
/// omitted from `Todo`'s `CodingKeys` (same treatment as `address`).
///
/// `none` is the default (raw value 0). It renders the same neutral edge accent
/// as `p2` so an unprioritised task still reads as calm/green rather than blank.
enum TaskPriority: Int, CaseIterable, Sendable {
    case none = 0
    case p0 = 1
    case p1 = 2
    case p2 = 3

    /// Short label for the editor picker and the AI context line.
    var label: String {
        switch self {
        case .none: return "None"
        case .p0:   return "P0"
        case .p1:   return "P1"
        case .p2:   return "P2"
        }
    }

    /// Parse a value supplied by the AI tools. Accepts "p0"/"p1"/"p2"
    /// (case-insensitive) plus common synonyms ("high"/"medium"/"low").
    /// Empty or unrecognised input returns `nil` so callers decide whether that
    /// means "leave unchanged" (edit) or "no priority" (create).
    init?(aiString raw: String?) {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        switch trimmed {
        case "p0", "high", "urgent", "critical": self = .p0
        case "p1", "medium", "med", "normal":    self = .p1
        case "p2", "low":                        self = .p2
        case "none", "no", "0":                  self = .none
        default:                                 return nil
        }
    }
}
