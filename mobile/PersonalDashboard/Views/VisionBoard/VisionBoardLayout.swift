import Foundation
import CoreGraphics

/// Pure grid arithmetic for the vision board (#446).
///
/// Kept out of the view and the view model on purpose: overlap resolution and the
/// lattice migration are the two pieces of this feature that are genuinely easy
/// to get subtly wrong AND the two whose failure scrambles a real board, and they
/// are the two pieces that can be reasoned about with no SwiftUI, no store, and
/// no gesture state in scope. Everything in here is a pure function of its
/// arguments and is unit-tested in `VisionBoardLayoutTests`.
enum VisionBoardLayout {

    /// One block's occupied rectangle, in cells.
    struct Slot: Equatable {
        var col: Int
        var row: Int
        var w: Int
        var h: Int

        var bottom: Int { row + h }

        func overlaps(_ other: Slot) -> Bool {
            col < other.col + other.w
                && other.col < col + w
                && row < other.row + other.h
                && other.row < row + h
        }
    }

    /// A block reduced to the only two things the solver cares about.
    ///
    /// The solver takes these rather than `VisionBlock` so a test can state a
    /// board in one line, and so nothing about a block's content can leak into a
    /// layout decision.
    struct Placement: Equatable {
        let id: UUID
        var slot: Slot

        init(id: UUID, slot: Slot) {
            self.id = id
            self.slot = slot
        }

        init(_ block: VisionBlock) {
            self.id = block.id
            self.slot = Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        }
    }

    // MARK: - Overlap

    /// Whether `slot` can be placed without touching any block other than
    /// `excluding`.
    ///
    /// Still used by CREATION, which refuses rather than displaces: a plus drawn
    /// on a specific cell has made a promise about that cell, and the honest
    /// answer where it cannot be kept is no plus at all. Moving and resizing no
    /// longer ask this question — they push (see `settle`).
    static func isFree(_ slot: Slot, in blocks: [VisionBlock], excluding: UUID?) -> Bool {
        guard slot.col >= 0, slot.row >= 0 else { return false }
        for block in blocks where block.id != excluding {
            let occupied = Slot(col: block.col, row: block.row, w: block.w, h: block.h)
            if slot.overlaps(occupied) { return false }
        }
        return true
    }

    /// The nearest legal slot to `desired`, searching outward in rings.
    ///
    /// The board no longer nudges anything a POINTER is steering — the block goes
    /// where you put it and the others move. This survives for the two callers
    /// that have no pointer and no block in hand: ⌘N and the toolbar plus, which
    /// need somewhere sensible to put a brand-new block and have no business
    /// shoving the board around to do it.
    ///
    /// Ring order rather than a scan of the whole canvas because the answer is
    /// almost always one cell away.
    static func nearestFreeSlot(
        to desired: Slot,
        in blocks: [VisionBlock],
        excluding: UUID?,
        maxRings: Int = 24
    ) -> Slot? {
        if isFree(desired, in: blocks, excluding: excluding) { return desired }

        for ring in 1...maxRings {
            var best: Slot?
            var bestDistance = Double.greatestFiniteMagnitude

            for dRow in -ring...ring {
                for dCol in -ring...ring {
                    // Only the perimeter of this ring; the interior was covered
                    // by a previous, strictly nearer pass.
                    guard abs(dRow) == ring || abs(dCol) == ring else { continue }
                    var candidate = desired
                    candidate.col += dCol
                    candidate.row += dRow
                    guard candidate.col >= 0, candidate.row >= 0 else { continue }
                    guard isFree(candidate, in: blocks, excluding: excluding) else { continue }

                    // Euclidean, so a diagonal neighbour loses to an orthogonal
                    // one at the same ring. Chebyshev rings with a Euclidean
                    // tie-break is what makes the nudge feel like it went the
                    // short way rather than the first way found.
                    let distance = Double(dCol * dCol + dRow * dRow)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = candidate
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    // MARK: - The push solver

    /// Resolve the board with one block PINNED at `target`, pushing whatever it
    /// overlaps out of the way.
    ///
    /// This is the whole interaction model, and it is the inverse of what the
    /// board did first. The dragged block used to be nudged to the nearest free
    /// slot, which meant the one thing under your hand was the one thing that
    /// would not go where you put it. Now it goes exactly where you put it and
    /// the board rearranges around it — the react-grid-layout shape, and the one
    /// the user described: *"the box that's already there shows that it would
    /// move until I actually drop the first box."*
    ///
    /// ### The push direction is ALWAYS DOWN
    ///
    /// Not "along the drag's direction of travel", which was the other
    /// candidate and which is worse on three counts.
    ///
    /// 1. **Determinism.** Pushing along travel makes the result a function of
    ///    the pointer's PATH, not its destination. Approach the same cell from
    ///    the left and from below and you get two different boards, and a drag
    ///    that wanders produces something nobody could have predicted. Down is a
    ///    function of the destination alone, so the same drop always yields the
    ///    same arrangement.
    /// 2. **Learnability.** One rule, held everywhere, beats a rule that changes
    ///    under you. Every grid layout a person has already used — CSS grid
    ///    auto-flow, Trello, Notion, react-grid-layout itself — pushes down, so
    ///    the model arrives already known.
    /// 3. **Room.** The canvas grows downward without limit and the window
    ///    scrolls that way naturally; sideways is the awkward axis on a Mac and
    ///    a block shoved off to the right is genuinely hard to find again.
    ///
    /// Down also happens to be what makes the solver provably safe, below.
    ///
    /// ### Why the pinned block can never itself be displaced
    ///
    /// A pushed block is placed at `mover.bottom`, so its top is at or below the
    /// mover's bottom edge and the two cannot overlap. Anything IT then pushes
    /// goes lower still. By induction every block in a cascade sits strictly
    /// below the pinned block, so nothing in the cascade can ever reach back up
    /// and touch it. The `filter` that skips the pinned id below is therefore
    /// belt and braces, not the mechanism.
    ///
    /// ### Termination
    ///
    /// The sweep visits each block exactly once, in reading order, settling it
    /// against the set already settled. A block's row is raised only to the
    /// bottom of something it overlaps, so each raise is strictly downward AND
    /// puts it permanently clear of at least one more settled block (rows only
    /// ever increase, so a block it has cleared can never catch it again). With
    /// `k` blocks already settled a candidate can therefore be raised at most
    /// `k` times, giving at most `n(n-1)/2` raises for the whole sweep. There is
    /// no cycle to enter and no fixed point to iterate toward.
    ///
    /// - Returns: every block OTHER than the mover, at its resolved slot.
    static func settle(
        moving id: UUID,
        to target: Slot,
        among placements: [Placement]
    ) -> [Placement] {
        var pinned = target
        pinned.col = max(0, pinned.col)
        pinned.row = max(0, pinned.row)
        return sweep(
            settled: [Placement(id: id, slot: pinned)],
            loose: placements.filter { $0.id != id }
        )
    }

    /// The same sweep with nothing pinned: the topmost block wins and everything
    /// below it gives way. Used by the migration to heal any overlap its
    /// rounding produced, and it is a no-op on a board that has none.
    static func settleAll(_ placements: [Placement]) -> [Placement] {
        sweep(settled: [], loose: placements)
    }

    /// One top-to-bottom pass. `settled` blocks never move; `loose` ones are
    /// visited in reading order and pushed down until they clear everything
    /// already placed.
    private static func sweep(settled: [Placement], loose: [Placement]) -> [Placement] {
        // Reading order, with the id as the last tie-break so the answer cannot
        // depend on the order the caller happened to hand them over in. Two
        // blocks can never share a (row, col) — that would be an overlap — so
        // the tie-break only ever fires on a board that is already broken, and
        // it is there to make even that case deterministic.
        let queue = loose.sorted {
            if $0.slot.row != $1.slot.row { return $0.slot.row < $1.slot.row }
            if $0.slot.col != $1.slot.col { return $0.slot.col < $1.slot.col }
            return $0.id.uuidString < $1.id.uuidString
        }

        var placed = settled
        var resolved: [Placement] = []
        resolved.reserveCapacity(queue.count)

        for candidate in queue {
            var moved = candidate
            moved.slot.col = max(0, moved.slot.col)
            moved.slot.row = max(0, moved.slot.row)

            // Bounded by construction: see the termination note above. The
            // counter is a tripwire for a future change that breaks the
            // invariant, not a guard the current code needs.
            var raises = 0
            while raises <= placed.count {
                let hits = placed.filter { $0.slot.overlaps(moved.slot) }
                guard let floor = hits.map({ $0.slot.bottom }).max() else { break }
                moved.slot.row = floor
                raises += 1
            }

            placed.append(moved)
            resolved.append(moved)
        }
        return resolved
    }

    /// The push solver against the board's own DTOs, returning only what
    /// actually moved.
    ///
    /// Only the changes, because that is what both callers want: the drag
    /// preview overlays them on the resting layout, and the commit writes them.
    /// A block that did not move must not be written — the board is mostly
    /// stationary during any one drag, and a write per block per drop would
    /// churn `updatedAt` across the whole board for a two-block rearrangement.
    static func displacements(
        moving id: UUID,
        to target: Slot,
        in blocks: [VisionBlock]
    ) -> [UUID: Slot] {
        let before = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, Placement($0).slot) })
        let after = settle(moving: id, to: target, among: blocks.map(Placement.init))

        var changed: [UUID: Slot] = [:]
        for placement in after where before[placement.id] != placement.slot {
            changed[placement.id] = placement.slot
        }
        return changed
    }

    // MARK: - Square-lattice migration

    /// A stored block's frame plus the lattice generation it was written under.
    ///
    /// Deliberately not `VisionBlock`: the DTO does not carry `gridVersion`
    /// (nothing above the store needs it) and the migration must run over
    /// archived and soft-deleted rows too, which never become DTOs at all.
    struct StoredFrame: Equatable {
        let id: UUID
        var col: Int
        var row: Int
        var w: Int
        var h: Int
        var gridVersion: Int

        init(id: UUID, col: Int, row: Int, w: Int, h: Int, gridVersion: Int) {
            self.id = id
            self.col = col
            self.row = row
            self.w = w
            self.h = h
            self.gridVersion = gridVersion
        }
    }

    /// How much wider one column used to be. 184 / 68 ≈ 2.7059.
    static let squareGridColumnScale = 184.0 / VisionGrid.cell

    /// Rescale every block written on the old 184pt-wide lattice onto the square
    /// one, and return ONLY the rows that need writing.
    ///
    /// ### Why it cannot apply twice
    ///
    /// The transform is gated on `gridVersion`, a marker stored ON THE ROW, and
    /// it sets that marker to `VisionGrid.schemaVersion` as part of the same
    /// value it returns — so the caller writes the new coordinates and the new
    /// marker in one `save()`, and a row is either wholly on the old lattice or
    /// wholly on the new one. A second call sees no row below the current
    /// version and returns `[]` before doing any arithmetic at all. That is
    /// stronger than idempotence of the arithmetic (which does not hold: scaling
    /// twice really would be 7.3× and really would scramble the board) — the
    /// arithmetic is simply never reached a second time.
    ///
    /// It is also not a heuristic. Nothing here inspects the coordinates to
    /// guess whether they "look migrated", which is the version of this that
    /// breaks the first time somebody legitimately makes a very wide block.
    ///
    /// ### Why the edges are scaled, not the extents
    ///
    /// The obvious transform is `col × s` and `w × s`, each rounded. It creates
    /// overlaps. Two blocks that were flush (`A.col + A.w == B.col`) can round
    /// apart: at `s ≈ 2.7059`, `col 1 w 1` becomes `col 3 w 3` and ends at 6,
    /// while its neighbour at `col 2` becomes `col 5` — a one-cell collision out
    /// of nowhere, on a board the user had arranged deliberately.
    ///
    /// So both EDGES are scaled instead and the width is their difference:
    ///
    ///     col' = round(col × s)
    ///     w'   = round((col + w) × s) − col'
    ///
    /// Rounding is monotonic, so `A.col + A.w ≤ B.col` implies
    /// `A.col' + A.w' ≤ B.col'`: a pair that did not overlap horizontally cannot
    /// start to. Rows are untouched (the vertical pitch did not change), so a
    /// pair separated vertically stays separated too. **The rescale therefore
    /// cannot introduce an overlap.** The cost is that an individual width can
    /// wobble by one cell either way, which is 68pt — visible, but the
    /// alternative is a board that has to be untangled by hand.
    ///
    /// The one thing that CAN collide is the minimum-size clamp: an old
    /// single-column block rescales to 2 or 3 cells and the new minimum is 3, so
    /// the 2-cell case has to grow by one and may land on its neighbour. That is
    /// what the `settleAll` pass at the end is for, and it is also a free repair
    /// for any board that was already overlapping for some other reason.
    ///
    /// - Parameters:
    ///   - frames: every stored block, live or not.
    ///   - liveIDs: the blocks actually on the board. Only these take part in
    ///     the overlap repair — an archived block must not shove a visible one
    ///     down from a position nobody can see.
    static func migrateToSquareGrid(
        _ frames: [StoredFrame],
        repairingOverlapsAmong liveIDs: Set<UUID>
    ) -> [StoredFrame] {
        guard frames.contains(where: { $0.gridVersion < VisionGrid.schemaVersion }) else { return [] }

        func scaledEdge(_ column: Int) -> Int {
            Int((Double(max(0, column)) * squareGridColumnScale).rounded())
        }

        var rescaled: [UUID: StoredFrame] = [:]
        for frame in frames {
            var next = frame
            if frame.gridVersion < VisionGrid.schemaVersion {
                // `max(1, w)` is the OLD lattice's minimum, applied before the
                // scale. Clamping to the NEW minimum here instead would scale a
                // one-column block as if it had been three, and turn a 172pt
                // card into a 540pt one.
                let leading = scaledEdge(frame.col)
                let trailing = scaledEdge(frame.col + max(1, frame.w))
                next.col = leading
                next.w = max(VisionGrid.minColumns, trailing - leading)
                next.row = max(0, frame.row)
                next.h = max(VisionGrid.minRows, frame.h)
                next.gridVersion = VisionGrid.schemaVersion
            }
            rescaled[frame.id] = next
        }

        // Repair, over the live subset only.
        let live = frames.compactMap { rescaled[$0.id] }.filter { liveIDs.contains($0.id) }
        let repaired = settleAll(live.map {
            Placement(id: $0.id, slot: Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h))
        })
        for placement in repaired {
            rescaled[placement.id]?.col = placement.slot.col
            rescaled[placement.id]?.row = placement.slot.row
            rescaled[placement.id]?.w = placement.slot.w
            rescaled[placement.id]?.h = placement.slot.h
        }

        // Only the rows that actually differ, in the caller's own order so the
        // write is stable run to run.
        return frames.compactMap { original in
            guard let next = rescaled[original.id], next != original else { return nil }
            return next
        }
    }

    // MARK: - Geometry

    /// The only way a block's top-left is allowed to be computed.
    ///
    /// Every render path on the board funnels through here — the resting
    /// position AND the live position under a dragging pointer — so "block
    /// rendered outside the canvas" is not a state the view can express. That
    /// matters beyond tidiness: a stuck drag session used to leave a block at a
    /// negative x, where it drew underneath the sidebar and looked lost rather
    /// than misplaced (#446 follow-up).
    static func clampedOrigin(_ point: CGPoint, size: CGSize, in canvas: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(0, point.x), max(0, canvas.width  - size.width)),
            y: min(max(0, point.y), max(0, canvas.height - size.height))
        )
    }

    /// The canvas size needed to hold `blocks`, plus room to keep going.
    ///
    /// The canvas grows on demand, which is what makes "pushed off the board"
    /// unreachable: a displacement cascade can always run further down, and the
    /// commit that lands it extends the scroll extent to match.
    ///
    /// Deliberately computed from the COMMITTED blocks only, and deliberately
    /// NOT from a live displacement preview. This value is the `.frame` of an
    /// ancestor of every block, including the one under the pointer, and
    /// mutating an ancestor's modifier mid-gesture is the documented way to have
    /// SwiftUI tear an in-flight gesture down (#446). A cascade that previews
    /// past the current extent simply draws past it for the duration and becomes
    /// scrollable the instant it commits.
    ///
    /// `viewport` sets the floor so an empty or sparse board still fills the
    /// window and double-click-to-create works anywhere you can see.
    static func canvasSize(for blocks: [VisionBlock], viewport: CGSize) -> CGSize {
        let maxCol = blocks.map { $0.col + $0.w }.max() ?? 0
        let maxRow = blocks.map { $0.row + $0.h }.max() ?? 0
        // Two spare cells past the last block in each axis: enough to drop a new
        // block beyond everything without the scroll extent jumping as you drag.
        let width  = CGFloat(maxCol + 2) * VisionGrid.cellWidth
        let height = CGFloat(maxRow + 2) * VisionGrid.cellHeight
        return CGSize(
            width:  max(width,  viewport.width),
            height: max(height, viewport.height)
        )
    }
}
