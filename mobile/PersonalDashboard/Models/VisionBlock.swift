import Foundation

/// View-facing projection of a `LocalVisionBlock` (#446).
///
/// Views and view models consume this struct rather than the SwiftData model,
/// the same split every other surface uses (`Todo`, `Checklist`): value
/// semantics mean SwiftUI diffing is predictable and equality is per-snapshot.
///
/// Not `Codable`. The board is deliberately absent from `SyncRecordMapper`,
/// `DataArchive` and the export/import services while this feature is in
/// flight, so there is no wire format to conform to yet. A model absent from
/// `SyncRecordMapper` never gets a `SyncShadow` row, which means sync cannot see
/// it and can never infer it as deleted — that containment is the point, and
/// wiring backup and sync is a separate follow-up.
struct VisionBlock: Identifiable, Hashable, Sendable {
    /// Stable identity, matches `LocalVisionBlock.clientUUID`.
    let id: UUID
    var title: String
    /// One-line statement of what this block is for. Nil or empty when unset;
    /// rendered under the title at medium and large.
    var intent: String?

    // Grid frame, in `VisionGrid` cells. Position and size are content on this
    // board, not layout: a block you made large is a claim about how much of you
    // it is taking, and the iOS projection reads the same numbers to order and
    // rank its single column.
    var col: Int
    var row: Int
    var w: Int
    var h: Int

    var state: BlockState

    /// Ordered task ids. Membership lives on the BLOCK, never on `LocalTodo`,
    /// so nothing on the board can strand a task and a task can be deleted from
    /// the Tasks surface without the board having to be told.
    ///
    /// May contain ids with no surviving task; see `LocalVisionBlock.members`.
    var members: [UUID]

    let createdAt: Date
    let updatedAt: Date

    /// The block's presentation tier, driven by its OWN column count and never
    /// by the window's width. Recomputed live during a resize, which is the
    /// whole point of the exercise: growing a block from one column to two makes
    /// its tiles appear under your hand.
    var tier: VisionBlockTier {
        if w >= 3 { return .large }
        if w == 2 { return .medium }
        return .small
    }
}

/// How much of itself a block shows. A function of the block's width in cells.
enum VisionBlockTier {
    /// 1 col. Title, state, urgency chip, `3/8`. No tiles. This is what stops a
    /// thirty-block board from being three hundred lines of task text.
    case small
    /// 2 col. Adds the intent line, the progress bar, and up to three tiles.
    case medium
    /// 3+ col. Adds the state eyebrow, every tile that fits, and the add row.
    case large
}
