import Foundation
import CoreGraphics

/// What the pointer is over on the vision board (#446).
///
/// Four answers, and every one of them is a decision the pointer layer would
/// otherwise have to make inline with an `NSEvent` in hand.
enum VisionHit: Equatable {
    /// The bottom-right resize grip of a block.
    case grip(UUID)
    /// A block's own chrome: the part of it that drags.
    case body(UUID)
    /// Empty canvas, at this cell.
    case canvas(col: Int, row: Int)
    /// A SwiftUI child that owns this point — a checkbox, the title, `+N more`,
    /// the ellipsis menu, the add-task field. The pointer layer must make itself
    /// transparent here.
    case passThrough
}

/// Where the pointer is, worked out with no AppKit, no view state and no window.
///
/// This is the whole reason the board's gestures moved to AppKit. Four rounds of
/// SwiftUI gesture fixes shipped and the block drag never once worked, because
/// the failure was recogniser racing rather than arithmetic: which of an
/// ancestor drag, a card-wide tap, a grip drag and a `.focusable()` mouse-down
/// won a given click was not decidable from the outside, and was not the same
/// twice. Nothing about that class of bug is visible in a build or a screenshot.
///
/// So hit testing became a pure function. It takes rectangles and returns an
/// answer; it has no opinion about SwiftUI, no reference to a view, and nothing
/// in its signature that needs a screen. `VisionPointerView` is then thin enough
/// that what remains in it is event plumbing rather than policy, and every
/// decision this file makes is asserted directly in `VisionHitTestTests`.
///
/// Cross-platform on purpose (no `#if os(macOS)`), even though only the Mac has
/// a pointer. It costs nothing on iOS, and it means the resolver's tests run in
/// the iOS-hosted `PersonalDashboardTests` target alongside
/// `VisionBoardLayoutTests` rather than needing the macOS host.
enum VisionHitTest {

    /// One block reduced to the only thing hit testing cares about.
    ///
    /// A rect rather than a `VisionBoardLayout.Slot`, because the pointer works
    /// in points and a resize renders a block at a size that is deliberately
    /// NOT on a cell boundary. Taking cells here would mean converting twice and
    /// disagreeing once.
    struct Frame: Equatable {
        let id: UUID
        var rect: CGRect

        init(id: UUID, rect: CGRect) {
            self.id = id
            self.rect = rect
        }

        init(_ block: VisionBlock) {
            self.id = block.id
            let origin = VisionGrid.origin(col: block.col, row: block.row)
            let size = VisionGrid.blockSize(columns: block.w, rows: block.h)
            self.rect = CGRect(origin: origin, size: size)
        }
    }

    /// The grip's hit target: the block's bottom-right corner, out to the edge.
    ///
    /// The GLYPH is a `VisionBlockMetrics.resizeTarget` square inset `Space.sm`
    /// from both edges, but the target deliberately runs past it to the corner
    /// itself. The inset used to be dead body, so aiming at the very corner —
    /// which is where a person aims, because that is where every window and
    /// every spreadsheet cell puts its handle — began a MOVE. The block sliding
    /// away when you meant to widen it reads as the board being broken rather
    /// than as a missed 8pt.
    ///
    /// Derived from the same two constants the card draws with, rather than
    /// restated, because a grip you can see and a grip you can hit drifting
    /// apart is a defect nobody can photograph.
    static func gripRect(in rect: CGRect) -> CGRect {
        let reach = VisionBlockMetrics.resizeTarget + Space.sm
        return CGRect(
            x: rect.maxX - reach,
            y: rect.maxY - reach,
            width: reach,
            height: reach
        )
    }

    /// The topmost block containing `point`, ignoring exclusions.
    ///
    /// Separate from `resolve` because hover wants a different question. Moving
    /// the pointer onto a tile must not read as leaving the block — the grip and
    /// the ellipsis are revealed on block hover, and they would flicker off the
    /// moment you moved toward a checkbox.
    static func block(at point: CGPoint, in blocks: [Frame]) -> UUID? {
        blocks.last { $0.rect.contains(point) }?.id
    }

    /// Resolve a canvas-space point.
    ///
    /// - Parameters:
    ///   - point: in canvas points, top-left origin, the same space
    ///     `VisionGrid.origin(col:row:)` produces.
    ///   - blocks: in draw order. **The last match wins**, matching the ZStack
    ///     the board renders: committed blocks never overlap, but a block being
    ///     resized renders past its own cells and over its neighbour, and the
    ///     one the user is steering is the one they mean.
    ///   - exclusions: interactive SwiftUI children, in canvas space, collected
    ///     by `VisionInteractiveRectsKey`.
    ///
    /// The grip is tested BEFORE exclusions on purpose. At `large` the add-task
    /// field spans the block's foot and its rect reaches under the grip; the
    /// grip is drawn on top of it, so it has to hit first or a wide block could
    /// not be resized at all.
    static func resolve(
        point: CGPoint,
        blocks: [Frame],
        exclusions: [CGRect]
    ) -> VisionHit {
        if let frame = blocks.last(where: { $0.rect.contains(point) }) {
            if gripRect(in: frame.rect).contains(point) { return .grip(frame.id) }
            if exclusions.contains(where: { $0.contains(point) }) { return .passThrough }
            return .body(frame.id)
        }

        // Off every block. An exclusion can still be here: the empty-board
        // invitation and anything a future block draws outside its own bounds.
        if exclusions.contains(where: { $0.contains(point) }) { return .passThrough }

        let cell = VisionGrid.cell(at: point)
        return .canvas(col: cell.col, row: cell.row)
    }
}
