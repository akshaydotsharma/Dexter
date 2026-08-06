import Foundation
import Observation
import SwiftData

/// View model for the Vision Board (#446).
///
/// Holds two things the surface needs together and the store keeps apart: the
/// blocks, and every live task keyed by id. Tiles are real `LocalTodo` rows, so
/// the board has to resolve membership ids against the task table on every load
/// — one fetch, one dictionary, rather than a lookup per tile.
///
/// Manual fetch plus `.localStoreDidChange`, the same construction Tasks, Notes
/// and Lists use. Not `@Query`: the board reads two tables and needs them
/// consistent with each other, and a per-tile query would be the row-multiplied
/// fetch that froze Finance (#442).
@Observable
@MainActor
final class VisionBoardViewModel {
    private(set) var blocks: [VisionBlock] = []
    /// Every live task, by id. Tiles resolve through this; a member id with no
    /// entry here is a task that was deleted from the Tasks surface and is
    /// simply not rendered.
    private(set) var tasksByID: [UUID: Todo] = [:]
    private(set) var isLoading = false
    var errorMessage: String?

    /// Tasks whose completion just changed and which hold their place in the
    /// tile stack for a beat before sinking.
    ///
    /// The delay has to live in the ORDERING, not in a sleep at the call site.
    /// The sink is a consequence of `completed` flipping, and `completed` flips
    /// the instant the checkbox is tapped, so sleeping before a reload changes
    /// nothing: the row has already moved. Holding the id here is what actually
    /// keeps it under the pointer long enough to see the check land on the row
    /// you clicked, rather than watching it leave and wondering what you hit.
    private(set) var sinkHold: Set<UUID> = []

    private let board: VisionBoardService
    private let todos: TodoService

    init(board: VisionBoardService? = nil, todos: TodoService? = nil) {
        self.board = board ?? VisionBoardService()
        self.todos = todos ?? TodoService()
    }

    // MARK: - Reads

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let allTasks = try await todos.list()
            tasksByID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
            blocks = try await board.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A block's tiles, resolved and ordered for display.
    ///
    /// Two rules, both from the spec. Unresolvable ids are dropped, so a task
    /// deleted in Tasks leaves no blank tile behind. Completed tiles sink below
    /// every incomplete one, so the three tiles a medium block shows stay the
    /// three that still need doing.
    func tiles(for block: VisionBlock) -> [Todo] {
        let resolved = block.members.compactMap { tasksByID[$0] }
        let open = resolved.filter { !$0.completed || sinkHold.contains($0.id) }
        let done = resolved.filter { $0.completed && !sinkHold.contains($0.id) }
        return open + done
    }

    /// Tasks not on any block, filtered by `query`. Backs the attach picker.
    func attachableTasks(matching query: String) -> [Todo] {
        let claimed = (try? board.claimedTaskIDs()) ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasksByID.values
            .filter { !claimed.contains($0.id) && !$0.completed }
            .filter { trimmed.isEmpty || $0.title.lowercased().contains(trimmed) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Block writes

    /// Create a block at a cell, nudged to the nearest free slot if that cell is
    /// taken. Returns its id so the caller can put the title straight into edit.
    @discardableResult
    func createBlock(
        at col: Int,
        row: Int,
        w: Int = VisionGrid.newColumns,
        h: Int = VisionGrid.newRows
    ) async -> UUID? {
        let desired = VisionBoardLayout.Slot(col: col, row: row, w: w, h: h)
        let slot = VisionBoardLayout.nearestFreeSlot(to: desired, in: blocks, excluding: nil) ?? desired
        do {
            let created = try await board.create(
                title: "Untitled",
                col: slot.col,
                row: slot.row,
                w: slot.w,
                h: slot.h
            )
            blocks.append(created)
            resort()
            return created.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ id: UUID, to title: String) async {
        await apply(id) { try await self.board.rename(id, to: title) }
    }

    func setIntent(_ id: UUID, to intent: String?) async {
        await apply(id) { try await self.board.setIntent(id, to: intent) }
    }

    func setState(_ id: UUID, to state: BlockState) async {
        await apply(id) { try await self.board.setState(id, to: state) }
    }

    func setFrame(_ id: UUID, col: Int, row: Int, w: Int, h: Int) async {
        await apply(id) { try await self.board.setFrame(id, col: col, row: row, w: w, h: h) }
        resort()
    }

    func deleteBlock(_ id: UUID) async {
        do {
            try await board.delete(id)
            blocks.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Membership

    func attach(taskID: UUID, to blockID: UUID) async {
        do {
            _ = try await board.attach(taskID: taskID, to: blockID)
            // A task can only be on one block, so the source block changed too.
            // Reloading the blocks is cheaper to reason about than patching two
            // arrays in place, and the store is local.
            blocks = try await board.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detach(taskID: UUID, from blockID: UUID) async {
        await apply(blockID) { try await self.board.detach(taskID: taskID, from: blockID) }
    }

    // MARK: - Task writes
    //
    // The board mutates real tasks, not shadows of them. Completing a tile here
    // is completing it in Tasks; that is the whole reason a board tile is a
    // `LocalTodo` rather than a scribble the board owns.

    /// Create a task and file it to `blockID`. Returns false so the add row can
    /// keep the text it failed to commit.
    @discardableResult
    func addTask(title: String, to blockID: UUID) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let created = try await todos.create(
                TodoCreateRequest(title: trimmed, description: nil, dueDate: nil, tag: nil)
            )
            tasksByID[created.id] = created
            _ = try await board.attach(taskID: created.id, to: blockID)
            blocks = try await board.list()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Toggle a tile's task.
    ///
    /// `sinkDelay` is nil under reduced motion, where the row simply reorders
    /// and the pause would be movement with no purpose left to serve.
    func toggleTask(_ id: UUID, sinkDelay: Duration? = .milliseconds(400)) async {
        guard let todo = tasksByID[id] else { return }
        do {
            let updated = try await todos.toggleCompleted(todo)
            tasksByID[id] = updated
            guard updated.completed, let sinkDelay else {
                sinkHold.remove(id)
                return
            }
            sinkHold.insert(id)
            Task { [weak self] in
                try? await Task.sleep(for: sinkDelay)
                self?.sinkHold.remove(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete the task itself. Distinct from `detach`, which only takes it off
    /// the board — the tile menu keeps the two visually distinct for the same
    /// reason this keeps them as separate calls.
    func deleteTask(_ id: UUID, from blockID: UUID) async {
        guard let todo = tasksByID[id] else { return }
        do {
            try await todos.delete(todo)
            tasksByID.removeValue(forKey: id)
            // Prune the now-dangling id rather than leaving it for the next
            // write. The user is looking at this block.
            _ = try await board.detach(taskID: id, from: blockID)
            blocks = try await board.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Internals

    private func apply(_ id: UUID, _ work: () async throws -> VisionBlock) async {
        do {
            let updated = try await work()
            if let index = blocks.firstIndex(where: { $0.id == id }) {
                blocks[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keep `blocks` in reading order after anything that moves one, so Tab
    /// order and the iOS projection's column order both stay honest.
    private func resort() {
        blocks.sort { lhs, rhs in
            if lhs.row != rhs.row { return lhs.row < rhs.row }
            if lhs.col != rhs.col { return lhs.col < rhs.col }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
