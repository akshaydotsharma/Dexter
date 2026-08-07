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

    /// Ordered items that belong to this block and to nothing else.
    ///
    /// The counterpart to `members`, and the distinction is the ONLY thing that
    /// separates them. A member is a real `LocalTodo` the board borrows: it
    /// exists in Tasks, it can be completed there, and taking it off the board
    /// leaves it alive. An item exists only here. Same shape, same checkbox,
    /// same behaviour — it simply does not turn up in Tasks, which is the whole
    /// point of being able to make one.
    ///
    /// Defaulted where `members` is not, and the asymmetry is deliberate rather
    /// than an oversight. `members` was there when the type was written, so
    /// every construction had to decide about it; `items` arrived afterwards,
    /// and every construction that predates it meant "none". A default says
    /// exactly that, and saves editing a dozen fixtures to write `items: []`.
    var items: [VisionItem] = []

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

/// One item on a block: a checkable line that lives here and nowhere else (#446).
///
/// Renders exactly like a task tile, checkbox included, because it IS the same
/// kind of thing to the person looking at it. The only difference is where it
/// lives: a task is a `LocalTodo` the board borrows and Tasks also shows, an
/// item is owned by the block. That is a storage fact, not a visual one, and
/// giving it a different shape (which the first pass did, as a dot and a line of
/// grey text) made the board answer a question nobody asked while hiding the one
/// thing people actually want from a list — a box to tick.
///
/// `Codable` where `VisionBlock` deliberately is not, and the two facts do not
/// conflict. `VisionBlock` has no wire format because the board is absent from
/// `SyncRecordMapper` and `DataArchive`; this conforms so the array can be a JSON
/// blob on `LocalVisionBlock`, which is storage, not transport. The shape was
/// chosen to survive being put on the wire later without a second migration:
/// `id` is stable so a peer edit can be matched rather than appended twice, and
/// `createdAt` gives a deterministic tiebreak when two devices add at once.
///
/// `completed` and `completedAt` decode with defaults, so a row written by the
/// build that shipped before items could be ticked reads as an open item rather
/// than as a decode failure that would empty the whole block.
struct VisionItem: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var text: String
    var completed: Bool
    var completedAt: Date?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        completed: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.completed = completed
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// One row in a block's list, whichever kind it is (#446).
///
/// The board shows a single list. Half of it is borrowed from Tasks and half of
/// it is the block's own, and the person reading it should not have to care
/// which — so the split is resolved once, here, and every surface that renders a
/// block consumes this instead of two arrays it has to interleave itself.
///
/// That "itself" is the point. The card and the overflow popover both render the
/// list, and when each did its own interleaving they were one edit away from
/// disagreeing about order, which reads as rows moving when you open a popover.
enum VisionRow: Identifiable, Hashable {
    case task(Todo)
    case item(VisionItem)

    var id: UUID {
        switch self {
        case .task(let todo): todo.id
        case .item(let item): item.id
        }
    }

    var title: String {
        switch self {
        case .task(let todo): todo.title
        case .item(let item): item.text
        }
    }

    var completed: Bool {
        switch self {
        case .task(let todo): todo.completed
        case .item(let item): item.completed
        }
    }

    /// True for a real `LocalTodo`. Drives the two places the kinds genuinely
    /// differ: an item can be edited in place and a task cannot (its title
    /// belongs to Tasks), and removing an item destroys it where removing a task
    /// only takes it off the board.
    var isTask: Bool {
        if case .task = self { return true }
        return false
    }

    /// When this row is due, or nil.
    ///
    /// Only a task can carry one. An item is a line you wrote to yourself; it
    /// has no deadline, which is exactly why it keeps the position you put it in
    /// rather than being sorted against rows that do.
    var dueDate: Date? {
        switch self {
        case .task(let todo): todo.dueDate
        case .item: nil
        }
    }
}

/// The one order a block's rows are rendered in (#446).
///
/// A pure function on purpose, and here rather than inside the view model,
/// because the last ordering bug on this surface lived in an untested call site
/// while every test around it passed. Ordering is a rule; rules get asserted.
enum VisionRowOrder {

    /// Soonest first, then everything undated in the order it was added, then
    /// the same again for anything completed.
    ///
    /// ### Why dated rows lead
    ///
    /// Requested as *"the sub items should be sorted chronologically. If there
    /// is no date, add them wherever they were added"*. A date is a claim about
    /// when something has to happen, and a block is read top-down, so the row
    /// that bites first is the row you should meet first. Undated rows have no
    /// position to argue for, so they keep the one they were given: tasks in the
    /// order membership records, then items in the order they were typed, which
    /// is what puts a newly added item directly above the `+` that made it.
    ///
    /// ### Why completed rows are ordered too
    ///
    /// They sink as a group, but they are still a list, and a finished block
    /// whose bottom half is in an arbitrary order reads as a different list from
    /// the one that was worked through.
    ///
    /// - Parameter sinkHold: rows just ticked, held in place for a beat so the
    ///   check is seen landing on the row that was clicked rather than on one
    ///   that slid up underneath it.
    static func arrange(_ rows: [VisionRow], sinkHold: Set<UUID> = []) -> [VisionRow] {
        let open = rows.filter { !$0.completed || sinkHold.contains($0.id) }
        let done = rows.filter { $0.completed && !sinkHold.contains($0.id) }
        return byDueDate(open) + byDueDate(done)
    }

    /// Dated rows ascending, undated rows after them, both stable.
    ///
    /// The index tiebreak is not decoration: `sorted(by:)` is not documented to
    /// be stable, so two tasks due the same day could otherwise swap places on a
    /// re-render for no reason the user did anything to cause.
    private static func byDueDate(_ rows: [VisionRow]) -> [VisionRow] {
        let dated = rows.enumerated().filter { $0.element.dueDate != nil }
        let undated = rows.filter { $0.dueDate == nil }
        let sorted = dated.sorted { left, right in
            guard let a = left.element.dueDate, let b = right.element.dueDate else {
                return false
            }
            if a != b { return a < b }
            return left.offset < right.offset
        }
        return sorted.map(\.element) + undated
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
