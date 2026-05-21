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

        // Trips: 20 most-recently-updated. The 3 newest get a full day-by-day
        // breakdown; older trips only emit the header line to keep the prompt
        // budget reasonable. Match the EXISTING TASKS pattern: skip the
        // section entirely when there are zero trips.
        if let trips = try? context.fetch(
            FetchDescriptor<LocalTrip>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        ).prefix(20), !trips.isEmpty {
            // Pre-fetch every item once so we don't hit SwiftData N times.
            let allItems = (try? context.fetch(
                FetchDescriptor<LocalItineraryItem>(
                    sortBy: [SortDescriptor(\.dayDate, order: .forward),
                             SortDescriptor(\.sortOrder, order: .forward),
                             SortDescriptor(\.createdAt, order: .forward)]
                )
            )) ?? []
            let itemsByTrip = Dictionary(grouping: allItems, by: { $0.tripUUID })

            out += "\n\nEXISTING TRIPS:\n"
            out += trips.enumerated().map { (idx, trip) -> String in
                let id = Self.uuidString(trip.clientUUID)
                let startISO = Self.isoDate.string(from: trip.startDate)
                let endISO = Self.isoDate.string(from: trip.endDate)
                let days = max(1, Self.dayCount(from: trip.startDate, to: trip.endDate))
                let items = itemsByTrip[trip.clientUUID] ?? []

                var line = "- \(id) | \(trip.name) | \(startISO) → \(endISO) (\(days) day\(days == 1 ? "" : "s")) | \(items.count) item\(items.count == 1 ? "" : "s")"

                // Full day-by-day breakdown only for the 3 most-recently-updated trips.
                if idx < 3, !items.isEmpty {
                    let groups = Dictionary(grouping: items, by: { $0.dayDate })
                    let sortedDays = groups.keys.sorted()
                    for day in sortedDays {
                        let dayItems = groups[day] ?? []
                        let dayNumber = Self.dayNumber(start: trip.startDate, day: day)
                        let dayISO = Self.isoDate.string(from: day)
                        let pretty = dayItems.map { item -> String in
                            let kind = ItineraryKind(rawValue: item.kind) ?? .activity
                            return "\(item.title) (\(kind.rawValue))"
                        }.joined(separator: ", ")
                        line += "\n  Day \(dayNumber) (\(dayISO)): \(pretty)"
                    }
                }
                return line
            }.joined(separator: "\n")
        }

        // Personal vocabulary: words the user has explicitly taught the
        // assistant so the model can prefer them over close-sounding
        // mistranscriptions ("envisso" vs. "in visa", "Dexter" vs. "Dexter
        // [unrelated]"). Emitted as XML-tagged so the prompt can refer to it
        // by name. Skipped entirely when empty so we don't ship a stub block.
        if let keywords = try? context.fetch(
            FetchDescriptor<LocalKeyword>(
                sortBy: [SortDescriptor(\.term, order: .forward)]
            )
        ), !keywords.isEmpty {
            out += "\n\n<personal_vocabulary>\n"
            out += keywords.map { keyword -> String in
                let trimmedNotes = keyword.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedNotes.isEmpty {
                    return "- \(keyword.term)"
                }
                let oneLineNotes = trimmedNotes.replacingOccurrences(of: "\n", with: " ")
                return "- \(keyword.term): \(oneLineNotes)"
            }.joined(separator: "\n")
            out += "\n</personal_vocabulary>"
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

    /// `yyyy-MM-dd` for trip start/end and per-day labels. Matches the
    /// "ISO date" shape the spec calls out for the EXISTING TRIPS block.
    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Inclusive day count between two `startOfDay`-normalised dates.
    private static func dayCount(from start: Date, to end: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: start, to: end)
        return (comps.day ?? 0) + 1
    }

    /// 1-indexed day number for a given day inside a trip ("Day 1" = startDate).
    private static func dayNumber(start: Date, day: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.day], from: start, to: day)
        return (comps.day ?? 0) + 1
    }
}
