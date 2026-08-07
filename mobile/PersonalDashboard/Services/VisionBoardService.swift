import Foundation
import SwiftData

/// Local-first vision board service (#446). All mutations land in SwiftData.
///
/// Follows `TodoService`: `@MainActor struct`, store injected and defaulting to
/// `.shared`, `FetchDescriptor` + `#Predicate` reads, DTOs out, `APIError.notFound`
/// on a miss. Notification-agnostic — callers that write from outside the
/// observing view post `.localStoreDidChange` themselves.
///
/// The board owns membership, so this is also where the dangling-task problem is
/// answered. A task deleted from the Tasks surface leaves its id behind in
/// whatever block held it, because nothing on `LocalTodo` points back. Reads skip
/// ids with no surviving task; every write prunes them. Neither path can crash
/// and neither renders a blank tile.
@MainActor
struct VisionBoardService {
    let store: SwiftDataStore

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Reads

    /// Live blocks in reading order: top to bottom, then left to right.
    ///
    /// That order is not cosmetic. It is the Tab order on macOS AND the order
    /// the iOS projection will stack its single column in, so the two surfaces
    /// agree about sequence without either one owning it.
    func list() async throws -> [VisionBlock] {
        let descriptor = FetchDescriptor<LocalVisionBlock>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil }
        )
        let rows = try store.context.fetch(descriptor)
        let live = try liveTodoIDs()
        return rows
            .map { row in
                var dto = row.toDTO()
                // Skip on read. The stale ids stay on disk until the next write
                // to this block prunes them, which is the right trade: a read
                // should not mutate the store, and a resolvable-later id is
                // preferable to one this pass throws away by mistake.
                dto.members = dto.members.filter { live.contains($0) }
                return dto
            }
            .sorted { lhs, rhs in
                if lhs.row != rhs.row { return lhs.row < rhs.row }
                if lhs.col != rhs.col { return lhs.col < rhs.col }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Every task id currently claimed by any block, dangling ones included.
    ///
    /// Used by the attach picker to offer only tasks that are not already on the
    /// board. Dangling ids are harmless in this set: they cannot match a live
    /// task, so they exclude nothing.
    func claimedTaskIDs() throws -> Set<UUID> {
        let descriptor = FetchDescriptor<LocalVisionBlock>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil }
        )
        let rows = try store.context.fetch(descriptor)
        return Set(rows.flatMap { $0.members })
    }

    // MARK: - Block lifecycle

    func create(
        title: String,
        col: Int,
        row: Int,
        w: Int = VisionGrid.newColumns,
        h: Int = VisionGrid.newRows,
        state: BlockState = .default
    ) async throws -> VisionBlock {
        let now = Date()
        let block = LocalVisionBlock(
            title: title,
            col: max(0, col),
            row: max(0, row),
            w: max(VisionGrid.minColumns, w),
            h: max(VisionGrid.minRows, h),
            state: state,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(block)
        try store.context.save()
        return block.toDTO()
    }

    /// Rename. An empty title is rejected rather than saved: a block is never
    /// untitled, and the caller reverts to what was there before.
    func rename(_ id: UUID, to title: String) async throws -> VisionBlock {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.notFound }
        return try await mutate(id) { $0.title = trimmed }
    }

    func setIntent(_ id: UUID, to intent: String?) async throws -> VisionBlock {
        let trimmed = intent?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await mutate(id) { $0.intent = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    func setState(_ id: UUID, to state: BlockState) async throws -> VisionBlock {
        try await mutate(id) { $0.blockState = state }
    }

    /// Move and/or resize. The caller has already resolved overlap against the
    /// rest of the board — this only clamps to the canvas origin and the minimum
    /// block size, which are invariants of the model rather than of the layout.
    func setFrame(_ id: UUID, col: Int, row: Int, w: Int, h: Int) async throws -> VisionBlock {
        try await mutate(id) {
            $0.col = max(0, col)
            $0.row = max(0, row)
            $0.w = max(VisionGrid.minColumns, w)
            $0.h = max(VisionGrid.minRows, h)
        }
    }

    /// Move and/or resize SEVERAL blocks in one save.
    ///
    /// A displacement cascade is one user action — one drop — and has to land as
    /// one write. Looping `setFrame` would save once per block, which is both
    /// slower and, worse, observable: a `.localStoreDidChange` between two saves
    /// would reload the board mid-cascade and paint an arrangement that overlaps.
    ///
    /// Missing ids are skipped rather than thrown on. The caller computed this
    /// layout from a snapshot; a block deleted in another window between the
    /// snapshot and the drop should not fail the drop.
    func applyFrames(_ frames: [UUID: VisionBoardLayout.Slot]) async throws {
        guard !frames.isEmpty else { return }
        let now = Date()
        let ids = Set(frames.keys)
        let rows = try store.context.fetch(
            FetchDescriptor<LocalVisionBlock>(predicate: #Predicate { $0.deletedAt == nil })
        )
        for row in rows where ids.contains(row.clientUUID) {
            guard let slot = frames[row.clientUUID] else { continue }
            row.col = max(0, slot.col)
            row.row = max(0, slot.row)
            row.w = max(VisionGrid.minColumns, slot.w)
            row.h = max(VisionGrid.minRows, slot.h)
            row.updatedAt = now
        }
        try store.context.save()
    }

    // MARK: - Lattice migration

    /// Rescale any block still stored on the old 184pt-wide lattice (#446).
    ///
    /// Called from `VisionBoardViewModel.load()` before the read, so the board
    /// is never rendered from stale coordinates. It is safe to call on every
    /// load: `migrateToSquareGrid` returns nothing once every row carries the
    /// current `gridVersion`, and the fast path below leaves before touching the
    /// store at all.
    ///
    /// Runs over ALL rows including archived and soft-deleted ones. A block
    /// unarchived next month must come back to the lattice everything else is
    /// on, and a row skipped here would be a landmine with no marker to find it
    /// by. Only LIVE rows take part in the overlap repair, though — an archived
    /// block is not on the board and must not shove a visible one down.
    ///
    /// `updatedAt` is deliberately NOT bumped. Nothing about the block changed;
    /// the coordinate system it is described in did. Bumping would make a
    /// mechanical rewrite look like the user rearranged their whole board.
    ///
    /// - Returns: how many rows were rewritten, for the log line.
    @discardableResult
    func migrateGridIfNeeded() async throws -> Int {
        let all = try store.context.fetch(FetchDescriptor<LocalVisionBlock>())
        guard all.contains(where: { $0.latticeVersion < VisionGrid.schemaVersion }) else { return 0 }

        let liveIDs = Set(
            all.filter { $0.deletedAt == nil && $0.archivedAt == nil }.map(\.clientUUID)
        )
        let changes = VisionBoardLayout.migrateToSquareGrid(
            all.map {
                VisionBoardLayout.StoredFrame(
                    id: $0.clientUUID,
                    col: $0.col, row: $0.row, w: $0.w, h: $0.h,
                    gridVersion: $0.latticeVersion
                )
            },
            repairingOverlapsAmong: liveIDs
        )
        guard !changes.isEmpty else { return 0 }

        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        for row in all {
            guard let frame = byID[row.clientUUID] else { continue }
            row.col = frame.col
            row.row = frame.row
            row.w = frame.w
            row.h = frame.h
            row.latticeVersion = frame.gridVersion
        }
        try store.context.save()
        return changes.count
    }

    /// Soft-delete the block. The tasks it held are untouched: they go back to
    /// being ordinary tasks that happen not to be on the board.
    func delete(_ id: UUID) async throws {
        let row = try fetchLocal(id)
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
    }

    // MARK: - Membership

    /// File a task into a block, removing it from any other block first.
    ///
    /// A task may appear in at most one block, and this is the only place that
    /// invariant is enforced. Doing it as part of the add — rather than trusting
    /// callers to detach first — means there is no ordering in which a task can
    /// end up on the board twice.
    @discardableResult
    func attach(taskID: UUID, to blockID: UUID) async throws -> VisionBlock {
        let target = try fetchLocal(blockID)
        let live = try liveTodoIDs()
        let now = Date()

        let all = try store.context.fetch(
            FetchDescriptor<LocalVisionBlock>(predicate: #Predicate { $0.deletedAt == nil })
        )
        for block in all where block.clientUUID != blockID {
            var members = block.members
            let kept = members.filter { $0 != taskID && live.contains($0) }
            if kept.count != members.count {
                members = kept
                block.members = members
                block.updatedAt = now
            }
        }

        var members = target.members.filter { live.contains($0) }
        if !members.contains(taskID) { members.append(taskID) }
        target.members = members
        target.updatedAt = now
        try store.context.save()
        return target.toDTO()
    }

    /// Take a task off the board and leave the task itself alone. Distinct from
    /// deleting it, and the tile menu keeps the two visually distinct too.
    @discardableResult
    func detach(taskID: UUID, from blockID: UUID) async throws -> VisionBlock {
        try await mutate(blockID) { block in
            block.members = block.members.filter { $0 != taskID }
        }
    }

    // MARK: - Items

    /// Append an item to a block and hand back the one that was made.
    ///
    /// Returns the item as well as the block because the caller puts the new
    /// item straight into edit, and reading `block.items.last` to find it would
    /// be right only for as long as this stays an append. The id is the answer
    /// to "which one did I just make"; position is not.
    ///
    /// An empty or whitespace-only text is accepted here, unlike `rename`.
    /// Creating a blank item IS the flow — the row appears already in edit and
    /// the user types into it — and `setItemText` is where blank becomes a
    /// deletion.
    @discardableResult
    func addItem(to blockID: UUID, text: String = "") async throws -> (block: VisionBlock, item: VisionItem) {
        let item = VisionItem(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let block = try await mutate(blockID) { $0.items.append(item) }
        return (block, item)
    }

    /// Edit an item's text. Empty text REMOVES it.
    ///
    /// Deliberately not the block-title rule, which reverts an empty edit
    /// because a block must always be named. An item has no such requirement,
    /// and clearing one is the obvious way to ask for it to go: reverting
    /// instead would leave the user holding an item they had just emptied on
    /// purpose, with the remove button as the only way out of a thing they had
    /// already told the interface to drop. It is also what closes the blank-item
    /// flow above — make one, click away, and nothing is left behind.
    @discardableResult
    func setItemText(_ itemID: UUID, in blockID: UUID, to text: String) async throws -> VisionBlock {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await mutate(blockID) { block in
            guard trimmed.isEmpty == false else {
                block.items.removeAll { $0.id == itemID }
                return
            }
            var items = block.items
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[index].text = trimmed
            block.items = items
        }
    }

    /// Tick or untick an item.
    ///
    /// `completedAt` is set and cleared alongside `completed` rather than left
    /// behind, so the two can never disagree. Nothing reads it yet; it exists
    /// because "when did I finish this" is unrecoverable once lost, and the cost
    /// of carrying it is one field in a JSON blob.
    @discardableResult
    func toggleItem(_ itemID: UUID, in blockID: UUID) async throws -> VisionBlock {
        try await mutate(blockID) { block in
            var items = block.items
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            let nowCompleted = !items[index].completed
            items[index].completed = nowCompleted
            items[index].completedAt = nowCompleted ? Date() : nil
            block.items = items
        }
    }

    @discardableResult
    func deleteItem(_ itemID: UUID, from blockID: UUID) async throws -> VisionBlock {
        try await mutate(blockID) { block in
            block.items.removeAll { $0.id == itemID }
        }
    }

    /// Reorder membership within one block, e.g. after a tile drag.
    @discardableResult
    func reorder(_ blockID: UUID, to order: [UUID]) async throws -> VisionBlock {
        try await mutate(blockID) { block in
            // Intersect rather than replace, so a stale order array cannot drop
            // a member the caller did not know about or invent one that is not
            // in the block.
            let existing = Set(block.members)
            let reordered = order.filter { existing.contains($0) }
            let remainder = block.members.filter { !order.contains($0) }
            block.members = reordered + remainder
        }
    }

    // MARK: - Internals

    /// One write path, so every mutation prunes dangling ids and bumps
    /// `updatedAt` without each call site having to remember to.
    @discardableResult
    private func mutate(_ id: UUID, _ body: (LocalVisionBlock) -> Void) async throws -> VisionBlock {
        let row = try fetchLocal(id)
        body(row)
        let live = try liveTodoIDs()
        row.members = row.members.filter { live.contains($0) }
        row.updatedAt = Date()
        try store.context.save()
        return row.toDTO()
    }

    private func fetchLocal(_ id: UUID) throws -> LocalVisionBlock {
        let descriptor = FetchDescriptor<LocalVisionBlock>(
            predicate: #Predicate { $0.clientUUID == id }
        )
        guard let row = try store.context.fetch(descriptor).first else {
            throw APIError.notFound
        }
        return row
    }

    /// Ids of every task that still exists and has not been soft-deleted.
    ///
    /// One fetch per operation rather than one per member id. A block with
    /// twenty tiles on a board of thirty blocks would otherwise be six hundred
    /// predicate fetches to answer a question a single set membership test
    /// answers — the same shape as the per-row `@Query` that froze Finance
    /// (#442).
    private func liveTodoIDs() throws -> Set<UUID> {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let rows = try store.context.fetch(descriptor)
        return Set(rows.map(\.clientUUID))
    }
}
