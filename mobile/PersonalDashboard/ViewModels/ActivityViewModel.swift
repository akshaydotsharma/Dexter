import Foundation
import Observation

/// State holder for the Activity surface. Reads from local SwiftData via
/// `ActivityService`; no remote / no error path. Pagination is keyset-based
/// over (createdAt, type, id) so a fresh insert can't shuffle pages.
@Observable
@MainActor
final class ActivityViewModel {
    enum Filter: Equatable, CaseIterable, Identifiable {
        case all
        case note
        case todo
        case list
        case folder

        var id: String {
            switch self {
            case .all:    return "all"
            case .note:   return "note"
            case .todo:   return "todo"
            case .list:   return "list"
            case .folder: return "folder"
            }
        }

        var label: String {
            switch self {
            case .all:    return "All"
            case .note:   return "Notes"
            case .todo:   return "Todos"
            case .list:   return "Lists"
            case .folder: return "Folders"
            }
        }

        var typeParam: ActivityItem.ItemType? {
            switch self {
            case .all:    return nil
            case .note:   return .note
            case .todo:   return .todo
            case .list:   return .list
            case .folder: return .folder
            }
        }
    }

    private(set) var items: [ActivityItem] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    var filter: Filter = .all

    private let service: ActivityService

    init() {
        self.service = ActivityService()
    }

    init(service: ActivityService) {
        self.service = service
    }

    /// First page or refresh after filter change. Clears items and resets the
    /// cursor.
    func loadFirstPage() {
        isLoading = true
        items = []
        nextCursor = nil

        let page = service.page(cursor: nil, type: filter.typeParam)
        items = page.items
        nextCursor = page.nextCursor
        isLoading = false
    }

    /// Append the next page if a cursor exists. No-op while another fetch is
    /// in flight or there are no more pages.
    func loadNextPage() {
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let page = service.page(cursor: cursor, type: filter.typeParam)
        items.append(contentsOf: page.items)
        nextCursor = page.nextCursor
        isLoadingMore = false
    }

    /// Pull-to-refresh hook. Same effect as `loadFirstPage`.
    func refresh() {
        loadFirstPage()
    }

    /// Switch the active filter and re-fetch. No-op if the filter is unchanged.
    func setFilter(_ next: Filter) {
        guard next != filter else { return }
        filter = next
        loadFirstPage()
    }
}
