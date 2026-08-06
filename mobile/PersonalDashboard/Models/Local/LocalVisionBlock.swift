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
        w: Int = 2,
        h: Int = 3,
        state: BlockState = .default,
        members: [UUID] = [],
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
        self.state = state.rawValue
        self.membersData = LocalVisionBlock.encode(members)
        self.position = position
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
        self.needsSync = needsSync
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
}
