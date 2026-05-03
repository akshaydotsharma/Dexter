import Foundation

/// On-device chat draft. Replaces the server-issued `Draft` for the chat
/// surface: carries the action type, the raw JSON tool input (passed
/// straight to `ExecuteDraftAction`), and a pre-rendered preview string.
///
/// `id` is a synthetic local UUID — drafts in chat-mode never persist to
/// any backend, so SwiftUI just needs a stable identity for `ForEach`.
struct ChatDraft: Identifiable, Hashable, Sendable {
    let id: UUID
    let actionType: DraftActionType
    let input: AnthropicJSONValue
    let preview: String

    init(id: UUID = UUID(), actionType: DraftActionType, input: AnthropicJSONValue, preview: String) {
        self.id = id
        self.actionType = actionType
        self.input = input
        self.preview = preview
    }
}

extension ChatDraft {
    /// Build a human-readable summary for one tool call. Ported from
    /// `generateDraftSummary` in server/ai/chatToDrafts.js so cards render
    /// the same prose users have been seeing from the server.
    static func makePreview(actionType: DraftActionType, input: AnthropicJSONValue) -> String {
        let dict = input.objectValue ?? [:]

        switch actionType {
        case .deleteTodo:
            return "Delete todo (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteNote:
            return "Delete note (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteList:
            return "Delete list (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteFolder:
            return "Delete folder (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .removeListItem:
            let listId = dict["list_id"]?.stringValue ?? "?"
            let idx = dict["item_index"]?.intValue.map(String.init) ?? "?"
            return "Remove item [\(idx)] from list (ID: \(listId))"

        case .completeTodo:
            let completed = dict["completed"]?.boolValue ?? true
            let verb = completed ? "Complete" : "Uncomplete"
            return "\(verb) task (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .updateListItem:
            let listId = dict["list_id"]?.stringValue ?? "?"
            let idx = dict["item_index"]?.intValue.map(String.init) ?? "?"
            var summary = "Edit item [\(idx)] in list (ID: \(listId))"
            if let text = dict["text"]?.stringValue, !text.isEmpty {
                summary += ": \"\(text)\""
            }
            if let checked = dict["checked"]?.boolValue {
                summary += checked ? " (mark done)" : " (mark undone)"
            }
            return summary

        case .updateTodo:
            var summary = "Edit task (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            return summary

        case .updateNote:
            var summary = "Edit note (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            return summary

        case .updateList:
            var summary = "Edit list (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            return summary

        case .addToList:
            let count = dict["new_items"]?.arrayValue?.count ?? 0
            return "Add \(count) item\(count == 1 ? "" : "s") to list (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .updateFolder:
            let name = dict["name"]?.stringValue ?? ""
            return "Rename folder (ID: \(dict["id"]?.stringValue ?? "?")) to \"\(name)\""

        case .createTodo:
            var summary = "Task: \"\(dict["title"]?.stringValue ?? "Untitled")\""
            if let due = dict["due_at"]?.stringValue, !due.isEmpty, due != "null",
               let date = Self.parseISODate(due) {
                summary += " (due: \(Self.dateOnly.string(from: date)))"
            }
            if let tag = dict["tag"]?.stringValue, !tag.isEmpty, tag != "null" {
                summary += " [\(tag)]"
            }
            return summary

        case .createNote:
            return "Note: \"\(dict["title"]?.stringValue ?? "Untitled")\""

        case .createList:
            let count = dict["items"]?.arrayValue?.count ?? 0
            return "List: \"\(dict["title"]?.stringValue ?? "Untitled")\" with \(count) item\(count == 1 ? "" : "s")"

        case .unknown:
            return "Unknown action"
        }
    }

    private static func parseISODate(_ raw: String) -> Date? {
        if let d = iso8601Fractional.date(from: raw) { return d }
        return iso8601.date(from: raw)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

extension ChatDraft {
    // MARK: - View accessors

    /// Title or name from the tool input, if the action carries one. Backs
    /// the chat preview card's headline line.
    var title: String? {
        let dict = input.objectValue ?? [:]
        if let t = dict["title"]?.stringValue, !t.isEmpty, t != "null" { return t }
        if let n = dict["name"]?.stringValue, !n.isEmpty, n != "null" { return n }
        return nil
    }

    /// Body / description / content blob, if any.
    var bodyPreview: String? {
        let dict = input.objectValue ?? [:]
        for key in ["body", "description", "content"] {
            if let v = dict[key]?.stringValue, !v.isEmpty, v != "null" {
                return v
            }
        }
        return nil
    }

    /// Items array for `draft_list` / `add_to_list` previews.
    var itemTexts: [String]? {
        let dict = input.objectValue ?? [:]
        let raw = dict["items"]?.arrayValue ?? dict["new_items"]?.arrayValue ?? []
        guard !raw.isEmpty else { return nil }
        return raw.compactMap { $0.objectValue?["text"]?.stringValue }
    }

    /// Due date as a `Date`, parsed from the `due_at` ISO string.
    var dueDate: Date? {
        guard let raw = input.objectValue?["due_at"]?.stringValue,
              !raw.isEmpty, raw != "null" else { return nil }
        return Self.parseISODate(raw)
    }

    /// Tag chip, if present.
    var tag: String? {
        guard let t = input.objectValue?["tag"]?.stringValue,
              !t.isEmpty, t != "null" else { return nil }
        return t
    }
}
