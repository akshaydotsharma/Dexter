import Foundation
import Observation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ListsViewModel {
    /// The ACTIVE lists. This property keeps meaning exactly what it always
    /// meant — "the lists you see" — and that is load-bearing: `TodayView`
    /// reads `listsVM.lists` straight into its lists card, so keeping archived
    /// rows out of here is what makes Today correct without touching it (#374).
    private(set) var lists: [Checklist] = []
    /// The archived lists, most recently archived first. Loaded alongside
    /// `lists` and consumed only by the Archive branch of `ListsView`.
    private(set) var archivedLists: [Checklist] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: ChecklistService

    init(service: ChecklistService? = nil) {
        let resolved = service ?? ChecklistService()
        self.service = resolved

        // Synchronous seed so the first frame is populated before `load()` runs.
        // Mirrors `ChecklistService.list()`'s predicate: active means neither
        // deleted nor archived. Getting this wrong would flash archived lists
        // into the index for one frame on launch.
        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? resolved.store.context.fetch(descriptor)) ?? []
        self.lists = rows.map { $0.toDTO() }
    }

    /// Read/write access to a list by id, regardless of which collection holds
    /// it (#374).
    ///
    /// Every mutation below used to resolve `lists.firstIndex(where:)` and index
    /// into `lists` directly. That breaks the moment a list can be opened from
    /// the Archive: an archived list is absent from `lists`, so the guard fails
    /// and the edit silently does nothing — the worst failure mode, because the
    /// UI has already drawn the change optimistically. Routing through here
    /// makes an archived list editable exactly like an active one.
    ///
    /// The setter is a no-op for an id in neither collection, matching the old
    /// `guard let listIndex … else { return }` behaviour.
    private subscript(id id: UUID) -> Checklist? {
        get { lists.first { $0.id == id } ?? archivedLists.first { $0.id == id } }
        set {
            guard let newValue else { return }
            if let index = lists.firstIndex(where: { $0.id == id }) {
                lists[index] = newValue
            } else if let index = archivedLists.firstIndex(where: { $0.id == id }) {
                archivedLists[index] = newValue
            }
        }
    }

    /// Resolve a list by id across BOTH collections.
    ///
    /// The detail branch of `ListsView` looks a list up by `selectedListId`, and
    /// you can open a list from inside the Archive. Searching only `lists` would
    /// make an archived list un-openable — it would resolve to nil and bounce
    /// straight back to the index.
    func list(id: UUID) -> Checklist? { self[id: id] }

    func load() async {
        isLoading = true
        do {
            async let active = service.list()
            async let archived = service.listArchived()
            lists = try await active
            archivedLists = try await archived
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Archive a list, or restore it to the index (#374).
    ///
    /// Moves the DTO between the two arrays in memory rather than reloading, so
    /// the row animates out of one list and into the other on the same runloop
    /// tick as the tap. `setArchived` returns the persisted row, which is what
    /// carries the new `archivedAt` — re-reading it here rather than synthesising
    /// a Date keeps the in-memory DTO and the store in agreement.
    func setArchived(_ list: Checklist, _ archived: Bool) async {
        do {
            try await service.setArchived(list, archived)
            // Re-read both collections from the store. Cheaper than it looks
            // (two indexed fetches over a personal-scale table) and it keeps the
            // archive's `archivedAt` ordering correct without hand-maintaining
            // the sort here.
            async let active = service.list()
            async let archivedRows = service.listArchived()
            let nextActive = try await active
            let nextArchived = try await archivedRows
            // Animate the swap so the row lifts out of whichever list it was in
            // instead of cross-fading in place. Assignment is what SwiftUI
            // observes, so both have to land inside the same transaction.
            withAnimation(.easeOut(duration: 0.2)) {
                lists = nextActive
                archivedLists = nextArchived
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(
        title: String,
        items: [ChecklistItem] = [],
        iconName: String? = nil,
        colorHex: String? = nil
    ) async {
        do {
            // When the caller doesn't specify an appearance, derive one from the
            // title via the local keyword mapper (no API call) so every new list
            // gets an identity immediately (#253).
            let inferred = ListAppearance.infer(from: title)
            let request = ChecklistCreateRequest(
                title: title,
                items: items,
                iconName: iconName ?? inferred.icon,
                colorHex: colorHex ?? inferred.colorHex
            )
            let new = try await service.create(request)
            lists.insert(new, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ list: Checklist) async {
        do {
            // Carry the appearance fields through so item toggles / renames don't
            // wipe the list's icon + color (the request is a full row overwrite).
            let request = ChecklistUpdateRequest(
                title: list.title,
                items: list.items,
                iconName: list.iconName,
                colorHex: list.colorHex
            )
            let updated = try await service.update(list, request)
            self[id: list.id] = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ list: Checklist, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var snapshot = self[id: list.id],
              snapshot.title != trimmed else { return }
        snapshot.title = trimmed
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    /// Apply a new icon/color (and optionally a new title) from the properties
    /// sheet. Mutates the in-memory DTO first so the tile + Today row update
    /// immediately, then persists the whole row.
    func updateAppearance(
        _ list: Checklist,
        iconName: String?,
        colorHex: String?,
        title: String? = nil
    ) async {
        guard var snapshot = self[id: list.id] else { return }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            snapshot.title = title
        }
        snapshot.iconName = iconName
        snapshot.colorHex = colorHex
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    func renameItem(in list: Checklist, at index: Int, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var snapshot = self[id: list.id],
              index < snapshot.items.count,
              snapshot.items[index].text != trimmed else { return }
        snapshot.items[index].text = trimmed
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    func setItemURL(in list: Checklist, at index: Int, to url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var snapshot = self[id: list.id],
              index < snapshot.items.count,
              snapshot.items[index].url != trimmed else { return }
        snapshot.items[index].url = trimmed
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    func toggleItem(in list: Checklist, at index: Int) async {
        guard var snapshot = self[id: list.id],
              index < snapshot.items.count else { return }
        snapshot.items[index].checked.toggle()

        // Auto-reorder: completed items sink to the bottom in the order they were
        // completed; un-completing pops back to the bottom of the active section.
        // Manual drag-to-reorder still wins for the next toggle: after a drag,
        // the next time the user toggles an item, this reasserts the grouping.
        let nowChecked = snapshot.items[index].checked
        var item = snapshot.items.remove(at: index)
        if nowChecked {
            // Append to the end so it lands below items completed earlier.
            snapshot.items.append(item)
        } else {
            // Drop just before the first checked item, or at the end if none.
            let insertAt = snapshot.items.firstIndex(where: { $0.checked }) ?? snapshot.items.count
            // Defensive: ensure the item's flag truly reflects the new state.
            item.checked = false
            snapshot.items.insert(item, at: insertAt)
        }

        // Animate the visible mutation. The setter on the collection is what
        // SwiftUI observes; wrapping the assignment in withAnimation makes the
        // identity-keyed ForEach lift the row to its new slot rather than
        // cross-fade in place. The async update() that follows is disk + DTO
        // only — by the time it returns the UI is already animating.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            self[id: list.id] = snapshot
        }
        await update(snapshot)
    }

    /// Insert a new item at the end of the ACTIVE (non-completed) items — just
    /// before the first completed item, so it appears below the last active
    /// item but never below the completed block, which always stays at the
    /// bottom (#267). Returns the actual insertion index so callers (e.g. the
    /// new-item sheet applying a URL) can target the new item.
    @discardableResult
    func addItem(to list: Checklist, text: String) async -> Int? {
        guard !text.isEmpty,
              var snapshot = self[id: list.id] else { return nil }
        // First completed item marks the boundary; fall back to the end when
        // nothing is completed.
        let insertAt = snapshot.items.firstIndex(where: { $0.checked }) ?? snapshot.items.count
        snapshot.items.insert(ChecklistItem(text: text, checked: false), at: insertAt)
        self[id: list.id] = snapshot
        await update(snapshot)
        return insertAt
    }

    func reorderItems(in list: Checklist, from source: IndexSet, to destination: Int) async {
        guard var snapshot = self[id: list.id] else { return }
        snapshot.items.move(fromOffsets: source, toOffset: destination)
        // Re-assert completed-at-bottom after a drag: keep completed items pinned
        // below the active ones, preserving relative order within each group
        // (filter is stable). This lets the user freely reorder active items but
        // never leaves a completed item interleaved above an active one.
        snapshot.items = snapshot.items.filter { !$0.checked } + snapshot.items.filter { $0.checked }
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    func removeItem(from list: Checklist, at index: Int) async {
        guard var snapshot = self[id: list.id],
              index < snapshot.items.count else { return }
        snapshot.items.remove(at: index)
        self[id: list.id] = snapshot
        await update(snapshot)
    }

    func delete(_ list: Checklist) async {
        do {
            try await service.delete(list)
            lists.removeAll { $0.id == list.id }
            // Also drop it from the archive: delete is reachable from the
            // Archive's swipe too, and missing this would leave the deleted row
            // on screen there until the next reload (#374).
            archivedLists.removeAll { $0.id == list.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
