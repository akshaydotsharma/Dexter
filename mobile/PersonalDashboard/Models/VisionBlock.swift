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

    /// Ordered line items that belong to this block and to nothing else.
    ///
    /// The counterpart to `members`, and the distinction is the point. A member
    /// is a real `LocalTodo` that the board borrows: it exists in Tasks, it can
    /// be completed there, and taking it off the board leaves it alive. A note
    /// exists only here. It is the scrap of context that would be silly to file
    /// as a task — a budget, a phone number, the name of the person who owes you
    /// the answer — and putting it in Tasks would mean carrying it through the
    /// task surfaces forever.
    ///
    /// Defaulted where `members` is not, and the asymmetry is deliberate rather
    /// than an oversight. `members` was there when the type was written, so
    /// every construction had to decide about it; `notes` arrived afterwards,
    /// and every construction that predates it meant "none". A default says
    /// exactly that, and saves editing a dozen fixtures to write `notes: []`.
    var notes: [VisionNote] = []

    let createdAt: Date
    let updatedAt: Date

    /// The block's presentation tier, driven by its OWN rendered width and never
    /// by the window's. Recomputed live during a resize, which is the whole
    /// point of the exercise: widening a block past a boundary makes its tiles
    /// appear under your hand.
    var tier: VisionBlockTier {
        VisionBlockTier(renderedWidth: VisionGrid.blockSize(columns: w, rows: h).width)
    }
}

/// One line item on a block (#446).
///
/// `Codable` where `VisionBlock` deliberately is not, and the two facts do not
/// conflict. `VisionBlock` has no wire format because the board is absent from
/// `SyncRecordMapper` and `DataArchive`; this conforms so the array can be a JSON
/// blob on `LocalVisionBlock`, which is storage, not transport. The shape was
/// chosen to survive being put on the wire later without a second migration:
/// `id` is stable so a peer edit can be matched rather than appended twice, and
/// `createdAt` gives a deterministic tiebreak when two devices add at once.
struct VisionNote: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// How much of itself a block shows. A function of the block's rendered WIDTH IN
/// POINTS, deliberately not of its column count.
///
/// Columns were the original unit and it was wrong: the tier is a claim about how
/// much type fits across the card, and expressing a physical claim in lattice
/// units meant that changing the lattice silently re-tiered the whole board. The
/// square-grid change (#446) is exactly that event — one column stopped being
/// 184pt and became 68pt — and in the old formulation every medium block on the
/// board would have become large.
enum VisionBlockTier {
    /// Under `VisionGrid.mediumMinWidth`. Title, state, urgency chip, `3/8`. No
    /// tiles. This is what stops a thirty-block board from being three hundred
    /// lines of task text.
    case small
    /// Adds the intent line, the progress bar, and up to three tiles.
    case medium
    /// At `VisionGrid.largeMinWidth` and above. Adds the state eyebrow, every
    /// tile that fits, and the add row.
    case large

    init(renderedWidth: CGFloat) {
        if renderedWidth >= VisionGrid.largeMinWidth {
            self = .large
        } else if renderedWidth >= VisionGrid.mediumMinWidth {
            self = .medium
        } else {
            self = .small
        }
    }
}
