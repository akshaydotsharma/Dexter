import Foundation
import SwiftData

/// Errors thrown when applying a draft action fails. The orchestrator
/// catches these and turns them into `FailedDraft` entries so the App
/// Intent dialog can surface the failure without aborting the whole batch.
enum DraftExecutionError: LocalizedError {
    case notFound(entityType: String, idString: String)
    case invalidArgument(field: String, reason: String)
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let type, let id):
            return "Couldn't find \(type) \(id)."
        case .invalidArgument(let field, let reason):
            return "Invalid \(field): \(reason)"
        case .persistence(let err):
            return err.localizedDescription
        }
    }
}

/// Outcome of one applied tool call. Surfaced back to the App Intent for
/// dialog rendering and to the chat UI for confirmation banners.
struct DraftActionOutcome {
    let type: String          // "todo" | "note" | "list" | "folder"
    let action: String        // see action constants below
    let id: String            // UUID string
    let title: String?
    let dueDate: Date?
    let addedNames: String?
}

/// Applies the 15 tool-call action types to SwiftData. Operates on
/// `LocalTodo / LocalNote / LocalList / LocalNoteFolder`. Deletes are
/// true deletes (no tombstones).
@MainActor
struct ExecuteDraftAction {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    /// Same shared-store factory as `AssistantContextBuilder.default`.
    static func `default`() -> ExecuteDraftAction {
        ExecuteDraftAction(store: .shared)
    }

    /// Dispatch a parsed tool call onto the right branch. `input` is the
    /// raw decoded JSON object the model returned.
    func run(actionType: DraftActionType, input: [String: AnthropicJSONValue]) async throws -> DraftActionOutcome {
        switch actionType {
        case .createTodo: return try createTodo(input)
        case .createNote: return try createNote(input)
        case .createList: return try createList(input)
        case .completeTodo: return try completeTodo(input)
        case .updateTodo: return try updateTodo(input)
        case .updateNote: return try updateNote(input)
        case .updateList: return try updateList(input)
        case .addToList: return try addToList(input)
        case .updateListItem: return try updateListItem(input)
        case .removeListItem: return try removeListItem(input)
        case .updateFolder: return try updateFolder(input)
        case .deleteTodo: return try deleteTodo(input)
        case .deleteNote: return try deleteNote(input)
        case .deleteList: return try deleteList(input)
        case .deleteFolder: return try deleteFolder(input)
        case .unknown:
            throw DraftExecutionError.invalidArgument(field: "action", reason: "unknown action type")
        }
    }

    // MARK: - CREATE

    private func createTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let description = trimmedString(input["description"])
        let dueDate = parseISODate(trimmedString(input["due_at"]))
        let tag = trimmedString(input["tag"])

        let now = Date()
        let row = LocalTodo(
            title: title,
            todoDescription: description,
            completed: false,
            dueDate: dueDate,
            tag: tag,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "todo", action: ActionString.created, id: row.clientUUID, title: row.title, dueDate: row.dueDate)
    }

    private func createNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let body = trimmedString(input["body"])
        let folderUUID = parseUUID(trimmedString(input["folder_id"]))

        let now = Date()
        let row = LocalNote(
            folderClientUUID: folderUUID,
            title: title,
            content: body,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "note", action: ActionString.created, id: row.clientUUID, title: row.title)
    }

    private func createList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let items = parseChecklistItems(input["items"])

        let now = Date()
        let row = LocalList(
            title: title,
            items: items,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "list", action: ActionString.created, id: row.clientUUID, title: row.title)
    }

    // MARK: - COMPLETE / UPDATE

    private func completeTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")
        let completed = input["completed"]?.boolValue ?? true
        row.completed = completed
        row.updatedAt = Date()
        try save()

        let action = completed ? ActionString.completed : ActionString.reopened
        return outcome(type: "todo", action: action, id: row.clientUUID, title: row.title)
    }

    private func updateTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        // "null" sentinel = clear, empty string = keep, anything else = set.
        if let raw = input["description"]?.stringValue {
            if raw == "null" {
                row.todoDescription = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.todoDescription = raw.trimmingCharacters(in: .whitespacesAndNewlines); changed = true
            }
        }
        if let raw = input["due_at"]?.stringValue {
            if raw == "null" {
                row.dueDate = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parsed = parseISODate(raw) {
                row.dueDate = parsed; changed = true
            }
        }
        if let raw = input["tag"]?.stringValue {
            if raw == "null" {
                row.tag = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.tag = raw.trimmingCharacters(in: .whitespacesAndNewlines); changed = true
            }
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "task", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "todo", action: ActionString.updated, id: row.clientUUID, title: row.title, dueDate: row.dueDate)
    }

    private func updateNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "note")
        let row: LocalNote = try fetchOne(uuid: uuid, entity: "note")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let raw = input["body"]?.stringValue {
            if raw == "null" {
                row.content = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.content = raw; changed = true
            }
        }
        if let raw = input["folder_id"]?.stringValue {
            if raw == "null" {
                row.folderClientUUID = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let folderUUID = UUID(uuidString: raw) {
                row.folderClientUUID = folderUUID; changed = true
            }
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "note", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "note", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    private func updateList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let arr = input["items"]?.arrayValue, !arr.isEmpty {
            row.items = parseChecklistItems(input["items"])
            changed = true
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "list", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "list", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    private func addToList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        let newItems = parseChecklistItems(input["new_items"])
        guard !newItems.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "new_items", reason: "required")
        }

        var items = row.items
        items.append(contentsOf: newItems)
        row.items = items
        row.updatedAt = Date()
        try save()

        let added = newItems.map { $0.text }.joined(separator: ", ")
        return DraftActionOutcome(
            type: "list",
            action: ActionString.itemsAdded,
            id: row.clientUUID.uuidString.lowercased(),
            title: row.title,
            dueDate: nil,
            addedNames: added
        )
    }

    private func updateListItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["list_id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        guard let index = input["item_index"]?.intValue, index >= 0 else {
            throw DraftExecutionError.invalidArgument(field: "item_index", reason: "required and >= 0")
        }
        var items = row.items
        guard index < items.count else {
            throw DraftExecutionError.invalidArgument(
                field: "item_index",
                reason: "out of range (\(index) of \(items.count))"
            )
        }

        var item = items[index]
        var changed = false
        if let text = trimmedString(input["text"]), !text.isEmpty {
            item.text = text; changed = true
        }
        if let checked = input["checked"]?.boolValue, checked != item.checked {
            item.checked = checked; changed = true
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "list item", reason: "no changes provided")
        }
        items[index] = item
        row.items = items
        row.updatedAt = Date()
        try save()

        return outcome(type: "list", action: ActionString.itemUpdated, id: row.clientUUID, title: row.title)
    }

    private func removeListItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["list_id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        guard let index = input["item_index"]?.intValue, index >= 0 else {
            throw DraftExecutionError.invalidArgument(field: "item_index", reason: "required and >= 0")
        }
        var items = row.items
        guard index < items.count else {
            throw DraftExecutionError.invalidArgument(
                field: "item_index",
                reason: "out of range (\(index) of \(items.count))"
            )
        }
        items.remove(at: index)
        row.items = items
        row.updatedAt = Date()
        try save()

        return outcome(type: "list", action: ActionString.itemRemoved, id: row.clientUUID, title: row.title)
    }

    private func updateFolder(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "folder")
        let row: LocalNoteFolder = try fetchOne(uuid: uuid, entity: "folder")

        guard let name = trimmedString(input["name"]), !name.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "name", reason: "required")
        }
        row.name = name
        row.updatedAt = Date()
        try save()

        return outcome(type: "folder", action: ActionString.updated, id: row.clientUUID, title: row.name)
    }

    // MARK: - DELETE (true deletes, no tombstones)

    private func deleteTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "todo", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "note")
        let row: LocalNote = try fetchOne(uuid: uuid, entity: "note")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "note", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "list", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteFolder(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "folder")
        let row: LocalNoteFolder = try fetchOne(uuid: uuid, entity: "folder")
        let name = row.name

        // Detach (don't cascade-delete) child notes — matches the original
        // tool description: "notes in the folder will be moved to no folder".
        let folderUUID = uuid
        let children = (try? store.context.fetch(
            FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.folderClientUUID == folderUUID && $0.deletedAt == nil }
            )
        )) ?? []
        let now = Date()
        for child in children {
            child.folderClientUUID = nil
            child.updatedAt = now
        }

        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "folder", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: name, dueDate: nil, addedNames: nil
        )
    }

    // MARK: - Helpers

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw DraftExecutionError.persistence(error)
        }
    }

    private func fetchOne<T: PersistentModel>(uuid: UUID, entity: String) throws -> T {
        if T.self == LocalTodo.self {
            let descriptor = FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalNote.self {
            let descriptor = FetchDescriptor<LocalNote>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalList.self {
            let descriptor = FetchDescriptor<LocalList>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalNoteFolder.self {
            let descriptor = FetchDescriptor<LocalNoteFolder>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
    }

    private func requireUUID(_ value: AnthropicJSONValue?, entity: String) throws -> UUID {
        guard let raw = value?.stringValue, let uuid = UUID(uuidString: raw) else {
            let provided = value?.stringValue ?? "<missing>"
            throw DraftExecutionError.notFound(entityType: entity, idString: provided)
        }
        return uuid
    }

    private func parseUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        return UUID(uuidString: raw)
    }

    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        // Try with fractional seconds first, then without — both shapes
        // are valid ISO 8601 and the LLM emits either.
        if let date = Self.iso8601Fractional.date(from: raw) {
            return date
        }
        if let date = Self.iso8601.date(from: raw) {
            return date
        }
        return nil
    }

    private func trimmedString(_ value: AnthropicJSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseChecklistItems(_ value: AnthropicJSONValue?) -> [ChecklistItem] {
        guard let array = value?.arrayValue else { return [] }
        var out: [ChecklistItem] = []
        for entry in array {
            guard let dict = entry.objectValue else { continue }
            let text = (dict["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let checked = dict["checked"]?.boolValue ?? false
            out.append(ChecklistItem(text: text, checked: checked))
        }
        return out
    }

    private func outcome(type: String, action: String, id: UUID, title: String?, dueDate: Date? = nil) -> DraftActionOutcome {
        DraftActionOutcome(
            type: type,
            action: action,
            id: id.uuidString.lowercased(),
            title: title,
            dueDate: dueDate,
            addedNames: nil
        )
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
}

/// Action strings returned with `DraftActionOutcome`. Kept as a namespace
/// rather than an enum so callers can compare against the raw string used
/// by the App Intent's dialog switch.
enum ActionString {
    static let created = "created"
    static let completed = "completed"
    static let reopened = "reopened"
    static let updated = "updated"
    static let deleted = "deleted"
    static let itemsAdded = "items_added"
    static let itemUpdated = "item_updated"
    static let itemRemoved = "item_removed"
}
