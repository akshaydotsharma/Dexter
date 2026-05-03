import Foundation
import SwiftData

/// Local activity timeline projection. Reads `LocalTodo / LocalNote / LocalList /
/// LocalNoteFolder` rows out of SwiftData, projects each to an `ActivityItem`
/// at its `createdAt`, and orders by (createdAt DESC, type ASC, id DESC) so
/// the page is stable across mutations.
///
/// Mirrors the previous `GET /api/dashboard/activity` shape so the view layer
/// did not need to change. Soft-deleted rows are excluded.
@MainActor
struct ActivityService: Sendable {
    let context: ModelContext

    init() {
        self.context = SwiftDataStore.shared.context
    }

    init(context: ModelContext) {
        self.context = context
    }

    /// Fetch one page of activity. Pass `cursor` (the value from the previous
    /// page's `nextCursor`) to load the next page; pass `type` to filter to a
    /// single entity type.
    func page(cursor: String? = nil, type: ActivityItem.ItemType? = nil, limit: Int = 50) -> ActivityPage {
        var all: [ActivityItem] = []

        if type == nil || type == .todo {
            let rows = (try? context.fetch(FetchDescriptor<LocalTodo>(
                predicate: #Predicate { $0.deletedAt == nil }
            ))) ?? []
            all.append(contentsOf: rows.map { row in
                ActivityItem(
                    id: row.clientUUID,
                    type: .todo,
                    title: row.title,
                    snippet: snippet(from: row.todoDescription),
                    parent: nil,
                    createdAt: row.createdAt
                )
            })
        }

        if type == nil || type == .note {
            let rows = (try? context.fetch(FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.deletedAt == nil }
            ))) ?? []
            let folderNamesByUUID = folderNameLookup()
            all.append(contentsOf: rows.map { row in
                ActivityItem(
                    id: row.clientUUID,
                    type: .note,
                    title: row.title ?? "",
                    snippet: snippet(from: row.content),
                    parent: row.folderClientUUID.flatMap { folderNamesByUUID[$0] },
                    createdAt: row.createdAt
                )
            })
        }

        if type == nil || type == .list {
            let rows = (try? context.fetch(FetchDescriptor<LocalList>(
                predicate: #Predicate { $0.deletedAt == nil }
            ))) ?? []
            all.append(contentsOf: rows.map { row in
                ActivityItem(
                    id: row.clientUUID,
                    type: .list,
                    title: row.title,
                    snippet: row.items.first?.text,
                    parent: nil,
                    createdAt: row.createdAt
                )
            })
        }

        if type == nil || type == .folder {
            let rows = (try? context.fetch(FetchDescriptor<LocalNoteFolder>(
                predicate: #Predicate { $0.deletedAt == nil }
            ))) ?? []
            all.append(contentsOf: rows.map { row in
                ActivityItem(
                    id: row.clientUUID,
                    type: .folder,
                    title: row.name,
                    snippet: nil,
                    parent: nil,
                    createdAt: row.createdAt
                )
            })
        }

        // Sort: createdAt DESC, type ASC (folder, list, note, todo alphabetic),
        // id DESC. Matches the server's keyset ordering so cursor pagination
        // is stable across calls.
        all.sort { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            if a.type.rawValue != b.type.rawValue { return a.type.rawValue < b.type.rawValue }
            return a.id.uuidString > b.id.uuidString
        }

        // Drop everything <= the cursor triple (strictly-older).
        let after: [ActivityItem]
        if let cursor, let cursorTriple = parseCursor(cursor) {
            after = all.drop(while: { item in
                if item.createdAt > cursorTriple.createdAt { return true }
                if item.createdAt == cursorTriple.createdAt {
                    if item.type.rawValue < cursorTriple.type { return true }
                    if item.type.rawValue == cursorTriple.type {
                        return item.id.uuidString >= cursorTriple.id
                    }
                }
                return false
            }).map { $0 }
        } else {
            after = all
        }

        let page = Array(after.prefix(limit))
        let nextCursor: String?
        if after.count > limit, let last = page.last {
            nextCursor = formatCursor(createdAt: last.createdAt, type: last.type.rawValue, id: last.id.uuidString)
        } else {
            nextCursor = nil
        }
        return ActivityPage(items: page, nextCursor: nextCursor)
    }

    // MARK: - Helpers

    private func folderNameLookup() -> [UUID: String] {
        let rows = (try? context.fetch(FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.clientUUID, $0.name) })
    }

    private func snippet(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 140 { return collapsed }
        return String(collapsed.prefix(140))
    }

    private struct CursorTriple {
        let createdAt: Date
        let type: String
        let id: String
    }

    private static let cursorFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func formatCursor(createdAt: Date, type: String, id: String) -> String {
        let ts = Self.cursorFormatter.string(from: createdAt)
        return "\(ts)|\(type)|\(id)"
    }

    private func parseCursor(_ raw: String) -> CursorTriple? {
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ts = Self.cursorFormatter.date(from: String(parts[0])) else {
            return nil
        }
        return CursorTriple(createdAt: ts, type: String(parts[1]), id: String(parts[2]))
    }
}
