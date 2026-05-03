import Foundation
import Observation

/// State holder for the Activity surface. Pure remote, no local cache. The
/// service is injected so tests can stub it.
///
/// Pagination model: the server returns up to `limit` items plus a
/// `nextCursor`. When `nextCursor` is null, we stop paginating. Filter
/// changes reset the cursor and clear the items.
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

        /// `nil` for `.all`; the wire value otherwise.
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
    var errorMessage: String?
    var filter: Filter = .all

    /// Bumped on every fresh load so a stale-filter response can be discarded
    /// when the user flips filters mid-fetch.
    private var requestGeneration = 0

    private let service: ActivityService

    init(service: ActivityService = ActivityService()) {
        self.service = service
    }

    /// First page or refresh after filter change. Clears items, shows the
    /// first-load skeleton in the view, and resets the cursor.
    func loadFirstPage() async {
        let myGen = bumpGeneration()
        isLoading = true
        errorMessage = nil
        items = []
        nextCursor = nil

        do {
            let page = try await service.page(cursor: nil, type: filter.typeParam)
            guard myGen == requestGeneration else { return }
            items = page.items
            nextCursor = page.nextCursor
        } catch {
            guard myGen == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if myGen == requestGeneration {
            isLoading = false
        }
    }

    /// Append the next page if a cursor exists. No-op while another fetch is
    /// in flight or there are no more pages.
    func loadNextPage() async {
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        let myGen = requestGeneration
        isLoadingMore = true
        errorMessage = nil
        do {
            let page = try await service.page(cursor: cursor, type: filter.typeParam)
            guard myGen == requestGeneration else { return }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            guard myGen == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if myGen == requestGeneration {
            isLoadingMore = false
        }
    }

    /// Pull-to-refresh hook. Same effect as `loadFirstPage`.
    func refresh() async {
        await loadFirstPage()
    }

    /// Switch the active filter and re-fetch. No-op if the filter is unchanged.
    func setFilter(_ next: Filter) async {
        guard next != filter else { return }
        filter = next
        await loadFirstPage()
    }

    private func bumpGeneration() -> Int {
        requestGeneration += 1
        return requestGeneration
    }
}
