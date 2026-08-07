import SwiftUI

#if os(macOS)

/// Live pointer, selection and keyboard state for the vision board (#446).
///
/// A reference type rather than a pile of `@State` on the view, and now for a
/// second reason on top of the original one: the board's pointer handling lives
/// in an `NSView` (`VisionPointerView`), which is not a SwiftUI view and cannot
/// hold SwiftUI state. This object is the seam between the two — AppKit writes
/// it, SwiftUI reads it.
///
/// It also holds every piece of arithmetic a gesture performs. The `NSView` is
/// deliberately left with nothing but event plumbing, so the behaviour that four
/// rounds of gesture fixes never managed to pin down is asserted here, directly,
/// with no window and no screen (`VisionPointerViewTests`).
@MainActor
@Observable
final class VisionInteraction {
    struct Cell: Equatable {
        var col: Int
        var row: Int
    }

    struct DragSession: Equatable {
        let id: UUID
        let origin: VisionBoardLayout.Slot
        /// Where inside the block the pointer went down, as an offset from its
        /// top-left. The block stays under the part of it you actually grabbed
        /// instead of jumping its own corner to the cursor.
        let grab: CGSize
        /// The block's top-left in canvas points, ALREADY clamped to the canvas
        /// by `updateDrag`. Held as a position rather than a translation so
        /// there is no unclamped intermediate for a render to read.
        var position: CGPoint
        /// Exactly the cell the pointer is over. Never nudged: the block goes
        /// where you put it and the board moves around it.
        var target: VisionBoardLayout.Slot?
        /// Where every OTHER block would end up if this were dropped now.
        ///
        /// Nothing is written to a block while a gesture is in flight, so
        /// dropping the session IS the undo. Since 2026-08-08 this is also all
        /// the preview there is: displaced blocks stay exactly where they are
        /// and only their DESTINATION is drawn, as a ghost outline. A preview
        /// that actually moves the board is not a preview — *"if I have not
        /// released the mouse, that means I have not expanded, I am just
        /// checking."*
        var displaced: [UUID: VisionBoardLayout.Slot] = [:]
        /// Set synchronously the moment the gesture ends, before the async
        /// commit, so a second ending is a no-op.
        var settling = false
    }

    struct ResizeSession: Equatable {
        let id: UUID
        let origin: VisionBoardLayout.Slot
        /// Canvas point of the mouse-down on the grip. Every later sample is
        /// read as a delta from this, which is what makes the two axes
        /// independent by construction rather than by care.
        let anchor: CGPoint
        /// The cell-quantised destination. Drives the tier, the tile budget, the
        /// dimension readout and the dashed outline.
        var w: Int
        var h: Int
        /// The unquantised size in points, which is what the card actually
        /// renders at, so its edge stays under the pointer instead of jumping a
        /// whole cell at a time.
        var live: CGSize
        /// Neighbours this growth would push aside, same as `DragSession`.
        var displaced: [UUID: VisionBoardLayout.Slot] = [:]
        var settling = false

        var target: VisionBoardLayout.Slot {
            VisionBoardLayout.Slot(col: origin.col, row: origin.row, w: w, h: h)
        }
    }

    var selected: UUID?
    /// The cell the pointer is over on empty canvas, which draws the ghost.
    var hoverCell: Cell?
    /// The block the pointer is over. Drives the card's border, shadow, grip and
    /// ellipsis reveal. Held here rather than in the card's own `@State`
    /// because the pointer layer sits on top of the cards and AppKit, not
    /// SwiftUI, is what now knows where the mouse is.
    var hoveredBlock: UUID?
    var drag: DragSession?
    var resize: ResizeSession?
    /// The block a dragged tile is currently over.
    var tileDropTarget: UUID?
    /// A just-created block, which opens with its title in edit. Consumed by
    /// the card on appear so a later re-render cannot re-enter the edit.
    var pendingTitleEdit: UUID?
    /// Keyboard cursor within the selected block's tile stack. Nil until Return
    /// or Space "enters" the block; Escape leaves it again.
    var tileCursor: Int?

    /// The one popover open on the board, if any.
    ///
    /// Board-wide and here rather than `@State` on the card, because the thing
    /// that has to CLOSE it is the AppKit pointer layer. `NSPopover`'s own
    /// `.semitransient` dismissal did not fire for a click on this canvas — the
    /// pointer layer answers those clicks itself, and a re-render landing
    /// between `performClose` and `popoverDidClose` could reopen a popover that
    /// had just closed, since the binding still read `true`. Reported as *"when
    /// I click on the outer surface, it still doesn't go away"*.
    ///
    /// Making it state the pointer layer owns replaces that with something
    /// deterministic and, more to the point, assertable with no window: see
    /// `testClickingTheBoardClosesAnOpenPopover`.
    ///
    /// One value, not one flag per card, because there is one popover on screen.
    /// Two flags could both be true.
    var popover: Popover?

    enum Popover: Equatable {
        /// A block's `+N more`, listing everything that did not fit.
        case overflow(UUID)
        /// A block's "Attach existing task…".
        case attach(UUID)
    }

    /// Mirrored from the environment by the view, because the settle animation
    /// and the haptics run outside any view's body.
    var reduceMotion = false

    @ObservationIgnored private var lastCreation = Date.distantPast

    // MARK: - Creation

    /// One interaction, at most one block.
    ///
    /// AppKit hands the pointer layer a `clickCount`, so the two recognisers
    /// that used to argue about this are gone — but a double click still
    /// arrives as two separate `mouseDown`s, and creation is async, so the
    /// second one sees a board that does not yet contain the block the first one
    /// made. `NSEvent.doubleClickInterval` rather than a literal, because the
    /// thing being collapsed IS a double click and the user's own setting is the
    /// only correct definition of how long that lasts.
    func claimCreation() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCreation) > NSEvent.doubleClickInterval else { return false }
        lastCreation = now
        return true
    }

    var isManipulating: Bool { drag != nil || resize != nil }

    /// True while a block's ellipsis menu is on screen.
    ///
    /// Set by `MacMenuButton` around the whole life of the `NSMenu`. The pointer
    /// leaves the card the moment the menu opens, so without this the tracking
    /// area reports `mouseExited`, hover clears, and the ellipsis — which is
    /// revealed on hover — disappears under the pointer that just clicked it.
    /// Reported as *"the three dots disappear when I click on it"*.
    var menuTracking = false

    /// Hover is frozen: keep reporting whatever it last said.
    ///
    /// A drag or a resize owns the pointer, and so does an open menu. In all
    /// three the cursor's position stops meaning "what am I pointing at".
    var holdsHover: Bool { isManipulating || menuTracking }

    /// One spring for both gestures, so a drop and a resize release read as the
    /// same physical event.
    var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86)
    }

    // MARK: - Drag

    func beginDrag(_ block: VisionBlock, grabbedAt point: CGPoint) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        let topLeft = VisionGrid.origin(col: block.col, row: block.row)
        drag = DragSession(
            id: block.id,
            origin: origin,
            grab: CGSize(width: point.x - topLeft.x, height: point.y - topLeft.y),
            position: topLeft,
            target: origin
        )
        selected = block.id
        tileCursor = nil
        // The ground stops tracking the pointer for the duration, so whatever it
        // last saw is stale. Cleared here rather than left to go stale, so a
        // ghost cannot flash at a cell the pointer left several hundred points
        // ago the instant the block is dropped.
        hoverCell = nil
    }

    /// Move the block in hand to wherever the pointer now is.
    ///
    /// - Returns: true when the SNAP CELL changed, which is the only moment the
    ///   alignment haptic should fire. A haptic on every pointer sample is a
    ///   buzz, not a signal, and re-running the solver sixty times a second
    ///   inside one cell is work nobody can see.
    @discardableResult
    func updateDrag(to point: CGPoint, canvas: CGSize, blocks: [VisionBlock]) -> Bool {
        guard let session = drag, !session.settling else { return false }

        let size = VisionGrid.blockSize(columns: session.origin.w, rows: session.origin.h)
        let position = VisionBoardLayout.clampedOrigin(
            CGPoint(x: point.x - session.grab.width, y: point.y - session.grab.height),
            size: size,
            in: canvas
        )
        drag?.position = position

        // Rounded, not floored: the block should snap to whichever cell it is
        // MOSTLY over, which is what makes a half-cell nudge feel decisive.
        let desired = VisionBoardLayout.Slot(
            col: max(0, Int((position.x / VisionGrid.cellWidth).rounded())),
            row: max(0, Int((position.y / VisionGrid.cellHeight).rounded())),
            w: session.origin.w,
            h: session.origin.h
        )
        guard desired != session.target else { return false }
        drag?.target = desired
        drag?.displaced = VisionBoardLayout.displacements(
            moving: session.id, to: desired, in: blocks
        )
        return true
    }

    // MARK: - Resize

    func beginResize(_ block: VisionBlock, from point: CGPoint) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        resize = ResizeSession(
            id: block.id,
            origin: origin,
            anchor: point,
            w: block.w,
            h: block.h,
            live: VisionGrid.blockSize(columns: block.w, rows: block.h)
        )
        selected = block.id
        tileCursor = nil
        hoverCell = nil
    }

    /// Grow or shrink the block in hand to wherever the pointer now is.
    ///
    /// ### The two axes are independent, and that is structural
    ///
    /// Width reads `point.x` only; height reads `point.y` only. Neither is
    /// consulted when the other is quantised, and neither is clamped by
    /// anything except its own minimum.
    ///
    /// That is the fix for the real defect. The board used to size a resize with
    /// `VisionBoardLayout.largestFreeSize`, which shrank the requested size
    /// until it fitted the gaps around the block — in three passes, the last of
    /// which was `while w > minColumns, !free(w, h) { w -= 1 }`. The WIDTH was
    /// reduced to accommodate the HEIGHT. So a block with a neighbour below and
    /// to the right could not be widened at its current height, and growing it
    /// downward first changed which neighbour the width pass collided with. That
    /// is exactly the reported *"I have to grow downward first before I can grow
    /// right"*. `largestFreeSize` was deleted in 4f7e945 when growth started
    /// pushing neighbours instead of refusing, and nothing may reintroduce a
    /// cross-axis cap: the minimum is the only limit, because whatever is in the
    /// way is about to move.
    ///
    /// - Returns: true when the quantised size changed, for the haptic.
    @discardableResult
    func updateResize(to point: CGPoint, blocks: [VisionBlock]) -> Bool {
        guard let session = resize, !session.settling else { return false }

        let base = VisionGrid.blockSize(columns: session.origin.w, rows: session.origin.h)
        let wanted = CGSize(
            width: base.width + (point.x - session.anchor.x),
            height: base.height + (point.y - session.anchor.y)
        )

        // The edge follows the pointer continuously and unquantised: the card
        // renders at a size in points, which is what makes a resize feel like a
        // handle rather than a stepper. Below the minimum the edge simply stops
        // following, with no error state.
        let floor = VisionGrid.blockSize(columns: VisionGrid.minColumns, rows: VisionGrid.minRows)
        resize?.live = CGSize(
            width: max(wanted.width, floor.width),
            height: max(wanted.height, floor.height)
        )

        let cellsW = max(
            VisionGrid.minColumns,
            Int(((wanted.width + VisionGrid.gutter) / VisionGrid.cellWidth).rounded())
        )
        let cellsH = max(
            VisionGrid.minRows,
            Int(((wanted.height + VisionGrid.gutter) / VisionGrid.cellHeight).rounded())
        )
        guard cellsW != session.w || cellsH != session.h else { return false }

        resize?.w = cellsW
        resize?.h = cellsH
        resize?.displaced = VisionBoardLayout.displacements(
            moving: session.id,
            to: VisionBoardLayout.Slot(
                col: session.origin.col, row: session.origin.row, w: cellsW, h: cellsH
            ),
            in: blocks
        )
        return true
    }

    // MARK: - Ending

    /// Close whatever is in hand and hand back everything that has to be
    /// written, as ONE dictionary.
    ///
    /// One write, because a cascade is one user action — one drop — and split
    /// across two saves there is a moment where the mover has committed and its
    /// victims have not, and that moment is an overlapping board.
    ///
    /// `settling` is set here, synchronously, so a second ending is a no-op. The
    /// caller must clear `drag` and `resize` only AFTER the write lands: drop
    /// them first and the card renders for a frame at its pre-gesture frame, so
    /// it springs backwards and then jumps forwards.
    ///
    /// - Returns: nil when nothing was in hand, so the caller can tell "no
    ///   gesture" from "a gesture that moved nothing".
    func finishManipulation() -> [UUID: VisionBoardLayout.Slot]? {
        guard isManipulating else { return nil }
        var frames: [UUID: VisionBoardLayout.Slot] = [:]

        if let session = drag, !session.settling {
            drag?.settling = true
            frames.merge(session.displaced) { current, _ in current }
            if let target = session.target, target != session.origin {
                frames[session.id] = target
            }
        }

        if let session = resize, !session.settling {
            resize?.settling = true
            frames.merge(session.displaced) { current, _ in current }
            if session.target != session.origin {
                frames[session.id] = session.target
            }
        }

        return frames
    }

    /// Escape. Drop whatever is in hand without committing it; the block springs
    /// back to where it started.
    ///
    /// Costs nothing to implement because displacement is never written to a
    /// block, only overlaid on the canvas as a ghost, so dropping the session IS
    /// the undo rather than a thing that has to remember what to put back.
    func cancelManipulation() {
        guard isManipulating else { return }
        NSCursor.openHand.set()
        withAnimation(settle) {
            drag = nil
            resize = nil
        }
        VisionProbe.line("cancelled")
    }

    // MARK: - Render

    /// Where every displaced block's ghost outline goes, in a stable order.
    ///
    /// Sorted by id rather than left in dictionary order, so the `ForEach` that
    /// draws them has stable identity between samples and does not rebuild the
    /// whole set every time the cascade changes by one.
    var displacementGhosts: [(id: UUID, slot: VisionBoardLayout.Slot)] {
        let frames = drag?.displaced ?? resize?.displaced ?? [:]
        return frames
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { (id: $0.key, slot: $0.value) }
    }

    /// Where a block draws.
    ///
    /// Two cases only: in hand, or at rest. Displacement deliberately does NOT
    /// appear here any more. A block the cascade would push stays exactly where
    /// it is for the whole gesture and moves on release, because a preview that
    /// rearranges the board has already done the thing you were only checking.
    func renderOrigin(for block: VisionBlock, canvas: CGSize) -> CGPoint {
        let size = VisionGrid.blockSize(columns: block.w, rows: block.h)
        if let drag, drag.id == block.id {
            return VisionBoardLayout.clampedOrigin(drag.position, size: size, in: canvas)
        }
        return VisionBoardLayout.clampedOrigin(
            VisionGrid.origin(col: block.col, row: block.row), size: size, in: canvas
        )
    }

    /// How a block's own offset animates.
    ///
    /// Nil for whatever is under the pointer — the block in hand must track it
    /// 1:1, and the block being resized is following its own continuous size —
    /// and a short spring for everything else, which is what makes the board
    /// read as pushing back rather than teleporting when the drop lands. Per
    /// block rather than on the container on purpose: a container animation
    /// would also catch the dragged block's offset.
    func displacementAnimation(for id: UUID) -> Animation? {
        guard drag?.id != id, resize?.id != id else { return nil }
        guard !reduceMotion else { return nil }
        return .spring(response: 0.24, dampingFraction: 0.9)
    }

    /// The block's frame as it should TIER right now: quantised, so the layout
    /// changes once per cell crossed rather than flickering on the boundary.
    func liveFrame(for block: VisionBlock) -> VisionBlock {
        guard let resize, resize.id == block.id else { return block }
        var live = block
        live.w = resize.w
        live.h = resize.h
        return live
    }

    /// The block's rendered size in points: continuous under the pointer, and
    /// still continuous through the settle, so the spring has somewhere to
    /// travel from when the session finally clears.
    func liveSize(for block: VisionBlock) -> CGSize? {
        guard let resize, resize.id == block.id else { return nil }
        return resize.live
    }

    /// Drives the readout and the dashed outline, which both belong to the part
    /// of a resize the user is still steering — not to the spring afterwards.
    func isResizing(_ id: UUID) -> Bool {
        guard let resize, resize.id == id else { return false }
        return !resize.settling
    }
}

#endif
