import Foundation
import SwiftData

/// A block on the vision board (#446): one big piece of work, positioned and
/// sized on a snapped canvas.
///
/// A brand-new `@Model`, which is the safe kind of SwiftData migration — it
/// creates one table and touches none of the fifteen models beside it. Nothing
/// is added to `LocalTodo`, deliberately (see `membersData`).
///
/// Field conventions follow `LocalList` exactly, including the two fields that
/// do nothing here. `needsSync` and `version` are dead weight while the board is
/// out of the sync lists, and they stay anyway: removing a field from a live
/// model triggers a lightweight migration that can fail and take the whole store
/// with it, so this codebase adds fields and never removes them.
@Model
final class LocalVisionBlock {
    @Attribute(.unique) var clientUUID: UUID

    var title: String
    /// Optional one-line intent. Nil when unset.
    var intent: String?

    /// Grid frame in `VisionGrid` cells. Stored as four scalars rather than a
    /// transformable `CGRect` so a sqlite dump is readable during QA and so a
    /// `#Predicate` could filter on them later without a custom transformer.
    ///
    /// NOT named `x`/`y`/`width`/`height`: `col`/`row` are cell indices, not
    /// points, and the point-valued reading is the one that would silently
    /// produce a block 184 times too far to the right.
    var col: Int
    var row: Int
    var w: Int
    var h: Int

    /// Which lattice `col` and `w` are expressed in.
    ///
    /// Optional, and nil means the original 184 × 68 lattice — because that is
    /// literally what a row written before this field existed says. A new
    /// non-optional attribute would need SwiftData to invent a value for every
    /// existing row, and the value it invents (0) would only accidentally be the
    /// right answer; an optional says "this row predates the question", which is
    /// exactly the fact the migration needs.
    ///
    /// Read through `latticeVersion` below, never directly, so the nil-means-0
    /// reading lives in one place.
    ///
    /// This is the marker that makes `VisionBoardLayout.migrateToSquareGrid`
    /// one-shot: it is written in the same `save()` as the rescaled coordinates,
    /// so a row can never be half-migrated and a second pass finds nothing to do.
    var gridVersion: Int?

    /// `BlockState.rawValue`. Stored as the raw string and read back through
    /// `blockState`, which falls back to `.idea` rather than trapping, so a
    /// value written by a future build with a state this one has not heard of
    /// renders as a parked block instead of crashing the board.
    var state: String

    /// Ordered task ids, JSON-encoded as an array of UUID strings.
    ///
    /// The same shape as `LocalList.itemsData` and for the same reason: SwiftData
    /// on iOS 17.0 will not persist an array without a custom transformer, and a
    /// blob with a computed accessor is the pattern this codebase already trusts.
    ///
    /// Membership is a property of the BLOCK, never of the task. That is the
    /// load-bearing half of the object model. It means `LocalTodo` gains no
    /// field, completing a task in Tasks is completing it on the board (one
    /// task, one truth, two places to see it), and deleting a task from Tasks
    /// cannot leave the board holding a reference the task itself knows about.
    ///
    /// What it can leave is a dangling id, which `members` skips on read and
    /// `VisionBoardService` prunes on write.
    var membersData: Data

    /// Ordered `VisionItem`s, JSON-encoded.
    ///
    /// Optional where `membersData` is not, and only because of when each was
    /// added. `membersData` was there when the table was created, so every row
    /// has one; this arrives on a model with rows already on disk, and a
    /// non-optional `Data` would need SwiftData to invent a value for each of
    /// them. It invents empty `Data`, which is not valid JSON and would decode
    /// to nothing — the right answer by luck rather than by construction. An
    /// optional says "this row predates items", which is the fact, and `items`
    /// below turns it into the empty array in one place.
    ///
    /// The STORED name stays `notesData` though the concept is now called an
    /// item. Renaming a `@Model` property renames the column, which is a
    /// remove-plus-add migration on a live store — and this codebase's rule is
    /// that fields are added and never removed. The name is frozen; the meaning
    /// is carried by `items` and by every UI string.
    ///
    /// Read and write through `items`, never directly.
    var notesData: Data?

    var position: Int?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var archivedAt: Date?
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        title: String,
        intent: String? = nil,
        col: Int = 0,
        row: Int = 0,
        w: Int = VisionGrid.newColumns,
        h: Int = VisionGrid.newRows,
        // A block made by THIS build is already on the current lattice, so it
        // is born marked and the migration never touches it.
        gridVersion: Int? = VisionGrid.schemaVersion,
        state: BlockState = .default,
        members: [UUID] = [],
        items: [VisionItem] = [],
        position: Int? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        archivedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.title = title
        self.intent = intent
        self.col = col
        self.row = row
        self.w = w
        self.h = h
        self.gridVersion = gridVersion
        self.state = state.rawValue
        self.membersData = LocalVisionBlock.encode(members)
        self.notesData = LocalVisionBlock.encodeItems(items)
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
        self.needsSync = needsSync
    }

    /// The lattice this row's columns are expressed in. Nil reads as 0, the
    /// original 184pt-wide lattice.
    var latticeVersion: Int {
        get { gridVersion ?? 0 }
        set { gridVersion = newValue }
    }

    /// Typed view of `state`. Unknown raw values read as `.idea`.
    var blockState: BlockState {
        get { BlockState(rawValue: state) ?? .idea }
        set { state = newValue.rawValue }
    }

    /// Read/write membership as an ordered id array. A decode failure yields an
    /// empty block rather than crashing: a recoverable empty state beats a fatal
    /// error on a surface whose whole job is to show you everything at once.
    var members: [UUID] {
        get { LocalVisionBlock.decode(membersData) }
        set { membersData = LocalVisionBlock.encode(newValue) }
    }

    /// Read/write the block's own items. Nil and a decode failure both read as
    /// empty, for the same reason `members` does: a block that renders without
    /// its items is recoverable, and a board that crashes on load is not.
    var items: [VisionItem] {
        get { LocalVisionBlock.decodeItems(notesData) }
        set { notesData = LocalVisionBlock.encodeItems(newValue) }
    }

    func toDTO() -> VisionBlock {
        VisionBlock(
            id: clientUUID,
            title: title,
            intent: intent,
            col: col,
            row: row,
            w: w,
            h: h,
            state: blockState,
            members: members,
            items: items,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Membership codec

    /// UUIDs are encoded as their string form, not as `UUID`'s own Codable
    /// representation, so the blob is a plain JSON array of readable strings in
    /// a sqlite dump.
    private static func encode(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(ids.map(\.uuidString))) ?? Data("[]".utf8)
    }

    private static func decode(_ data: Data) -> [UUID] {
        let strings = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return strings.compactMap(UUID.init(uuidString:))
    }

    /// Items go through `VisionItem`'s own `Codable` rather than a hand-rolled
    /// pair, because unlike a bare UUID an item has fields that will grow — it
    /// has already grown two.
    ///
    /// Named apart from the membership pair rather than overloaded. `Data`
    /// promotes to `Data?` silently, so `decode(membersData)` would still
    /// type-check against a `Data?` overload — and picking the wrong one would
    /// not fail to build, it would return an empty array and read as a block
    /// that had lost its tasks.
    private static func encodeItems(_ items: [VisionItem]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
    }

    private static func decodeItems(_ data: Data?) -> [VisionItem] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([VisionItem].self, from: data)) ?? []
    }
}
