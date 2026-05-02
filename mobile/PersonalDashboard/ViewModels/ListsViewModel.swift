import Foundation
import Observation

@Observable
@MainActor
final class ListsViewModel {
    private(set) var lists: [Checklist] = []
    private(set) var isLoading = false
    var errorMessage: String?

    private let service: ChecklistService

    init(service: ChecklistService = ChecklistService()) {
        self.service = service
        if let cached = CacheStore.load([Checklist].self, from: .lists) {
            self.lists = cached
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await service.list()
            lists = fresh
            CacheStore.save(fresh, to: .lists)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func create(title: String, items: [ChecklistItem] = []) async {
        do {
            let request = ChecklistCreateRequest(title: title, items: items)
            let new = try await service.create(request)
            lists.insert(new, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ list: Checklist) async {
        do {
            let request = ChecklistUpdateRequest(title: list.title, items: list.items)
            let updated = try await service.update(id: list.id, request)
            if let index = lists.firstIndex(where: { $0.id == list.id }) {
                lists[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleItem(in list: Checklist, at index: Int) async {
        guard let listIndex = lists.firstIndex(where: { $0.id == list.id }),
              index < lists[listIndex].items.count else { return }
        var snapshot = lists[listIndex]
        snapshot.items[index].checked.toggle()
        lists[listIndex] = snapshot
        await update(snapshot)
    }

    func addItem(to list: Checklist, text: String) async {
        guard !text.isEmpty,
              let listIndex = lists.firstIndex(where: { $0.id == list.id }) else { return }
        var snapshot = lists[listIndex]
        snapshot.items.append(ChecklistItem(text: text, checked: false))
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
            try await service.delete(id: list.id)
            lists.removeAll { $0.id == list.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
