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
    let type: String          // "todo" | "note" | "list" | "folder" | "trip" | "itinerary_item"
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
        case .createTrip: return try createTrip(input)
        case .addItineraryItems: return try addItineraryItems(input)
        case .updateTrip: return try updateTrip(input)
        case .deleteTrip: return try deleteTrip(input)
        case .updateItineraryItem: return try updateItineraryItem(input)
        case .deleteItineraryItem: return try deleteItineraryItem(input)
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

    // MARK: - TRIPS (Itineraries)

    private func createTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let name = trimmedString(input["name"]) ?? ""
        guard !name.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "name", reason: "required")
        }
        guard let startRaw = trimmedString(input["start_date"]), let start = parseAnyISODate(startRaw) else {
            throw DraftExecutionError.invalidArgument(field: "start_date", reason: "required ISO 8601 date")
        }
        guard let endRaw = trimmedString(input["end_date"]), let end = parseAnyISODate(endRaw) else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "required ISO 8601 date")
        }
        let startOfStart = Calendar(identifier: .gregorian).startOfDay(for: start)
        let startOfEnd = Calendar(identifier: .gregorian).startOfDay(for: end)
        guard startOfEnd >= startOfStart else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "must be on or after start_date")
        }

        let notes = input["notes"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanNotes = notes == "null" ? "" : notes

        let now = Date()
        let row = LocalTrip(
            name: name,
            startDate: startOfStart,
            endDate: startOfEnd,
            notes: cleanNotes,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try save()
        return outcome(type: "trip", action: ActionString.created, id: row.clientUUID, title: row.name)
    }

    private func addItineraryItems(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let tripUUID = try requireUUID(input["trip_id"], entity: "trip")
        let trip: LocalTrip = try fetchOne(uuid: tripUUID, entity: "trip")

        guard let rawItems = input["items"]?.arrayValue, !rawItems.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "items", reason: "required and non-empty")
        }

        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var addedTitles: [String] = []

        // Snapshot existing items for sortOrder math so we don't refetch per item.
        let tripFK = tripUUID
        var existing = (try? store.context.fetch(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.tripUUID == tripFK }
            )
        )) ?? []

        for entry in rawItems {
            guard let dict = entry.objectValue else { continue }
            let title = (dict["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            guard let dayRaw = dict["day_date"]?.stringValue,
                  let day = parseAnyISODate(dayRaw) else { continue }
            let dayStart = cal.startOfDay(for: day)

            // Map kind string; last-resort fallback is .activity per spec.
            let kindRaw = (dict["kind"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let kind = ItineraryKind(rawValue: kindRaw) ?? .activity

            let notes = (dict["notes"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanNotes = notes == "null" ? "" : notes

            // Optional start_time: any unparseable value silently falls back
            // to nil (untimed) rather than failing the whole batch. The
            // model can omit the field entirely; we don't require it.
            let startTime = parseAnyISODate(dict["start_time"]?.stringValue)

            // Stay-only check-out fields. For non-stay kinds, both are
            // discarded even if the model accidentally provided them.
            var endDateValue: Date? = nil
            var endTimeValue: Date? = nil
            if kind == .stay {
                if let endRaw = dict["end_date"]?.stringValue,
                   let parsedEnd = parseAnyISODate(endRaw) {
                    endDateValue = cal.startOfDay(for: parsedEnd)
                }
                endTimeValue = parseAnyISODate(dict["end_time"]?.stringValue)
            }

            let maxForDay = existing
                .filter { cal.isDate($0.dayDate, inSameDayAs: dayStart) }
                .map { $0.sortOrder }
                .max() ?? -1

            let row = LocalItineraryItem(
                tripUUID: tripUUID,
                dayDate: dayStart,
                kind: kind,
                title: title,
                notes: cleanNotes,
                startTime: startTime,
                endDate: endDateValue,
                endTime: endTimeValue,
                sortOrder: maxForDay + 1,
                createdAt: now,
                updatedAt: now
            )
            store.context.insert(row)
            existing.append(row)
            addedTitles.append(title)
        }

        guard !addedTitles.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "items", reason: "no valid items provided")
        }

        trip.updatedAt = now
        try save()

        return DraftActionOutcome(
            type: "itinerary_item",
            action: ActionString.itemsAdded,
            id: trip.clientUUID.uuidString.lowercased(),
            title: trip.name,
            dueDate: nil,
            addedNames: addedTitles.joined(separator: ", ")
        )
    }

    private func updateTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "trip")
        let row: LocalTrip = try fetchOne(uuid: uuid, entity: "trip")
        let cal = Calendar(identifier: .gregorian)

        var changed = false
        if let name = trimmedString(input["name"]), !name.isEmpty {
            row.name = name; changed = true
        }
        // start_date / end_date: empty = keep, real value = set. No "null" support (can't clear dates).
        if let raw = input["start_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let parsed = parseAnyISODate(raw) {
            row.startDate = cal.startOfDay(for: parsed); changed = true
        }
        if let raw = input["end_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let parsed = parseAnyISODate(raw) {
            row.endDate = cal.startOfDay(for: parsed); changed = true
        }
        // notes: empty = keep, "null" = clear (to ""), real value = set.
        if let raw = input["notes"]?.stringValue {
            if raw == "null" {
                row.notes = ""; changed = true
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    row.notes = trimmed; changed = true
                }
            }
        }

        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "trip", reason: "no changes provided")
        }
        guard row.endDate >= row.startDate else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "must be on or after start_date")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "trip", action: ActionString.updated, id: row.clientUUID, title: row.name)
    }

    private func deleteTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "trip")
        let row: LocalTrip = try fetchOne(uuid: uuid, entity: "trip")
        let name = row.name

        // Cascade: delete every itinerary item that references this trip,
        // then the trip itself. Single SwiftData save.
        let tripFK = uuid
        let children = (try? store.context.fetch(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.tripUUID == tripFK }
            )
        )) ?? []
        for child in children {
            store.context.delete(child)
        }
        store.context.delete(row)
        try save()

        return DraftActionOutcome(
            type: "trip", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: name, dueDate: nil, addedNames: nil
        )
    }

    private func updateItineraryItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "itinerary_item")
        let row: LocalItineraryItem = try fetchOne(uuid: uuid, entity: "itinerary_item")
        let cal = Calendar(identifier: .gregorian)

        var changed = false
        if let raw = input["day_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let parsed = parseAnyISODate(raw) {
            row.dayDate = cal.startOfDay(for: parsed); changed = true
        }
        if let raw = input["kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty, raw != "null",
           let kind = ItineraryKind(rawValue: raw) {
            row.kind = kind.rawValue; changed = true
        }
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let raw = input["notes"]?.stringValue {
            if raw == "null" {
                row.notes = ""; changed = true
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    row.notes = trimmed; changed = true
                }
            }
        }
        // start_time follows the same empty/"null"/value tri-state as notes.
        // Empty string = keep current value, "null" = clear (untimed),
        // anything else = parse as ISO 8601 and set.
        if let raw = input["start_time"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.startTime = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseAnyISODate(trimmed) {
                row.startTime = parsed; changed = true
            }
        }
        // end_date / end_time: same tri-state. Cleared automatically when
        // kind switches away from stay (handled below after `changed` check).
        if let raw = input["end_date"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.endDate = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseAnyISODate(trimmed) {
                row.endDate = cal.startOfDay(for: parsed); changed = true
            }
        }
        if let raw = input["end_time"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.endTime = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseAnyISODate(trimmed) {
                row.endTime = parsed; changed = true
            }
        }
        // If the kind isn't stay any more, clear the stay-only fields so the
        // persisted shape doesn't leak stale data through the timeline.
        if row.kindEnum != .stay {
            if row.endDate != nil { row.endDate = nil; changed = true }
            if row.endTime != nil { row.endTime = nil; changed = true }
        }

        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "itinerary item", reason: "no changes provided")
        }

        row.updatedAt = Date()
        // Bump the parent trip's updatedAt so it floats to the top of the
        // EXISTING TRIPS context next round.
        let tripFK = row.tripUUID
        if let trip = try? store.context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == tripFK })
        ).first {
            trip.updatedAt = Date()
        }
        try save()
        return outcome(type: "itinerary_item", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    private func deleteItineraryItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "itinerary_item")
        let row: LocalItineraryItem = try fetchOne(uuid: uuid, entity: "itinerary_item")
        let title = row.title
        let tripFK = row.tripUUID
        store.context.delete(row)
        if let trip = try? store.context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == tripFK })
        ).first {
            trip.updatedAt = Date()
        }
        try save()
        return DraftActionOutcome(
            type: "itinerary_item", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
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
        if T.self == LocalTrip.self {
            let descriptor = FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalItineraryItem.self {
            let descriptor = FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.clientUUID == uuid })
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

    /// Slightly more lenient ISO parser used by the trip tools. Accepts
    /// full datetimes (with or without fractional seconds) AND bare
    /// `yyyy-MM-dd` dates, which the model emits for day-level fields.
    private func parseAnyISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Self.iso8601Fractional.date(from: trimmed) { return d }
        if let d = Self.iso8601.date(from: trimmed) { return d }
        if let d = Self.dateOnly.date(from: trimmed) { return d }
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

    /// Bare `yyyy-MM-dd` parsed in UTC. Used for date-only fields (trip
    /// start/end, itinerary item day_date).
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
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
