import Foundation
import Observation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ListsViewModel {
    private(set) var lists: [Checklist] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: ChecklistService

    init(service: ChecklistService? = nil) {
        let resolved = service ?? ChecklistService()
        self.service = resolved

        let descriptor = FetchDescriptor<LocalList>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? resolved.store.context.fetch(descriptor)) ?? []
        self.lists = rows.map { $0.toDTO() }
    }

    func load() async {
        isLoading = true
        do {
            lists = try await service.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
            if let index = lists.firstIndex(where: { $0.id == list.id }) {
                lists[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ list: Checklist, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              lists[listIndex].title != trimmed else { return }
        var snapshot = lists[listIndex]
        snapshot.title = trimmed
        lists[listIndex] = snapshot
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
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }) else { return }
        var snapshot = lists[listIndex]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            snapshot.title = title
        }
        snapshot.iconName = iconName
        snapshot.colorHex = colorHex
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func renameItem(in list: Checklist, at index: Int, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              index < lists[listIndex].items.count,
              lists[listIndex].items[index].text != trimmed else { return }
        var snapshot = lists[listIndex]
        snapshot.items[index].text = trimmed
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func setItemURL(in list: Checklist, at index: Int, to url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              index < lists[listIndex].items.count,
              lists[listIndex].items[index].url != trimmed else { return }
        var snapshot = lists[listIndex]
        snapshot.items[index].url = trimmed
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func toggleItem(in list: Checklist, at index: Int) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              index < lists[listIndex].items.count else { return }
        var snapshot = lists[listIndex]
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

        // Animate the visible mutation. The setter on `lists` is what SwiftUI
        // observes; wrapping the assignment in withAnimation makes the
        // identity-keyed ForEach lift the row to its new slot rather than
        // cross-fade in place. The async update() that follows is disk + DTO
        // only — by the time it returns the UI is already animating.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            lists[listIndex] = snapshot
        }
        await update(snapshot)
    }

    func addItem(to list: Checklist, text: String) async {
        guard !text.isEmpty,
              let listIndex = lists.firstIndex(where: { $0.id == list.id }) else { return }
        var snapshot = lists[listIndex]
        snapshot.items.insert(ChecklistItem(text: text, checked: false), at: 0)
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func reorderItems(in list: Checklist, from source: IndexSet, to destination: Int) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }) else { return }
        var snapshot = lists[listIndex]
        snapshot.items.move(fromOffsets: source, toOffset: destination)
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func removeItem(from list: Checklist, at index: Int) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              index < lists[listIndex].items.count else { return }
        var snapshot = lists[listIndex]
        snapshot.items.remove(at: index)
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func delete(_ list: Checklist) async {
        do {
            try await service.delete(list)
            lists.removeAll { $0.id == list.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
