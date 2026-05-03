import Foundation
import SwiftData

/// Builds the EXISTING TASKS / NOTES / LISTS / FOLDERS section the LLM uses
/// to resolve "the dentist task" or "groceries list" to a concrete UUID.
/// Mirrors `fetchContext` + the `getInstructions` context block in
/// server/ai/chatToDrafts.js, just with UUIDs instead of integer IDs.
@MainActor
struct AssistantContextBuilder {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    /// Convenience constructor for callers running on `MainActor` who want
    /// the shared singleton. Default-argument bindings can't read
    /// `SwiftDataStore.shared` (it's main-actor-isolated), so we bottle the
    /// dereference inside an explicit factory.
    static func `default`() -> AssistantContextBuilder {
        AssistantContextBuilder(store: .shared)
    }

    /// Render the context block exactly the way the server prompt embeds it,
    /// minus the leading newlines (the orchestrator concatenates).
    func build() async -> String {
        let context = store.context
        var out = ""

        // Tasks: 50 most recent, undeleted.
        if let todos = try? context.fetch(
            FetchDescriptor<LocalTodo>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).prefix(50), !todos.isEmpty {
            out += "\n\nEXISTING TASKS:\n"
            out += todos.map { todo -> String in
                let id = Self.uuidString(todo.clientUUID)
                var line = "- ID:\(id) \"\(todo.title)\""
                if let due = todo.dueDate {
                    line += " (due: \(Self.dateOnly.string(from: due)))"
                }
                if let tag = todo.tag, !tag.isEmpty {
                    line += " [\(tag)]"
                }
                if todo.completed {
                    line += " ✓"
                }
                return line
            }.joined(separator: "\n")
        }

        // Notes: 50 most recent, sorted by updatedAt desc, with content preview.
        if let notes = try? context.fetch(
            FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        ).prefix(50), !notes.isEmpty {
            out += "\n\nEXISTING NOTES:\n"
            out += notes.map { note -> String in
                let id = Self.uuidString(note.clientUUID)
                let title = note.title ?? ""
                var line = "- ID:\(id) \"\(title)\""
                if let folderUUID = note.folderClientUUID {
                    line += " (folder ID:\(Self.uuidString(folderUUID)))"
                }
                if let raw = note.content, !raw.isEmpty {
                    let trimmed = String(raw.prefix(200))
                    let preview = trimmed.count >= 200
                        ? String(trimmed.prefix(197)) + "..."
                        : trimmed
                    let oneLine = preview.replacingOccurrences(of: "\n", with: " ")
                    line += "\n  Body preview: \"\(oneLine)\""
                }
                return line
            }.joined(separator: "\n")
        }

        // Lists: 50 most recent. Items are emitted with their indices so the
        // model can target edit_list_item / remove_list_item by index.
        if let lists = try? context.fetch(
            FetchDescriptor<LocalList>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).prefix(50), !lists.isEmpty {
            out += "\n\nEXISTING LISTS:\n"
            out += lists.map { list -> String in
                let id = Self.uuidString(list.clientUUID)
                let items = list.items
                var line = "- List ID:\(id) \"\(list.title)\" (\(items.count) items)"
                if !items.isEmpty {
                    line += "\n  Items:"
                    for (idx, item) in items.enumerated() {
                        line += "\n    [\(idx)] \"\(item.text)\""
                        if item.checked {
                            line += " ✓"
                        }
                    }
                }
                return line
            }.joined(separator: "\n")
        }

        // Folders: 20 most recent, sorted by name.
        if let folders = try? context.fetch(
            FetchDescriptor<LocalNoteFolder>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.name, order: .forward)]
            )
        ).prefix(20), !folders.isEmpty {
            out += "\n\nEXISTING FOLDERS:\n"
            out += folders.map { folder in
                "- ID:\(Self.uuidString(folder.clientUUID)) \"\(folder.name)\""
            }.joined(separator: "\n")
        }

        return out
    }

    /// Lower-cased UUID string. Matches Postgres' default uuid render so any
    /// future cross-checking against server logs lines up.
    private static func uuidString(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    /// Mirrors `new Date(due).toLocaleDateString()` from the server prompt:
    /// short date, no time, locale-respecting.
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}
