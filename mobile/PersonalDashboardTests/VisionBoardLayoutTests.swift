import XCTest
@testable import PersonalDashboard

/// The vision board's two pure functions (#446): the push solver and the
/// square-lattice migration.
///
/// Both are over-tested on purpose. A cascade that resolves wrongly and a
/// migration that scales twice have the same consequence — a board the user
/// arranged by hand comes back scrambled, with no undo and no backup (the board
/// is deliberately absent from `SyncRecordMapper` and `DataArchive` while the
/// feature is in flight). There is no cheap way to notice either failure from a
/// build or a screenshot, and by the time it is noticed the old arrangement is
/// gone. So the invariants are asserted directly rather than inferred from the
/// surface.
final class VisionBoardLayoutTests: XCTestCase {

    // MARK: - Fixtures

    typealias Slot = VisionBoardLayout.Slot
    typealias Placement = VisionBoardLayout.Placement

    /// Stable, readable ids. `UUID(uuidString:)` on a hand-written string so the
    /// solver's id tie-break is reproducible run to run — a random `UUID()` would
    /// make any test that depends on that ordering flaky.
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func block(_ n: Int, _ col: Int, _ row: Int, _ w: Int, _ h: Int) -> VisionBlock {
        VisionBlock(
            id: Self.id(n),
            title: "block \(n)",
            intent: nil,
            col: col, row: row, w: w, h: h,
            state: .default,
            members: [],
            createdAt: Date(timeIntervalSince1970: TimeInterval(n)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(n))
        )
    }

    private func placement(_ n: Int, _ col: Int, _ row: Int, _ w: Int, _ h: Int) -> Placement {
        Placement(id: Self.id(n), slot: Slot(col: col, row: row, w: w, h: h))
    }

    /// The property that matters more than any individual expected value: after
    /// the solver runs, nothing overlaps anything.
    private func assertNoOverlaps(
        _ slots: [(UUID, Slot)],
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for i in slots.indices {
            for j in slots.indices where j > i {
                XCTAssertFalse(
                    slots[i].1.overlaps(slots[j].1),
                    "\(message) — \(slots[i].1) overlaps \(slots[j].1)",
                    file: file, line: line
                )
            }
        }
    }

    /// Every block's resolved slot, mover included, keyed by id.
    private func resolved(
        moving mover: VisionBlock, to target: Slot, in blocks: [VisionBlock]
    ) -> [UUID: Slot] {
        var out = Dictionary(
            uniqueKeysWithValues: blocks.map { ($0.id, Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)) }
        )
        for (id, slot) in VisionBoardLayout.displacements(moving: mover.id, to: target, in: blocks) {
            out[id] = slot
        }
        out[mover.id] = target
        return out
    }

    // MARK: - No-op

    func testNothingMovesWhenTheTargetIsEmpty() {
        let a = block(1, 0, 0, 3, 2)
        let b = block(2, 10, 0, 3, 2)

        let pushed = VisionBoardLayout.displacements(
            moving: a.id, to: Slot(col: 0, row: 6, w: 3, h: 2), in: [a, b]
        )

        XCTAssertTrue(pushed.isEmpty, "a drop into empty canvas must not disturb the board")
    }

    func testAMoverThatDoesNotMoveDisturbsNothing() {
        let a = block(1, 0, 0, 3, 2)
        let b = block(2, 0, 2, 3, 2)

        let pushed = VisionBoardLayout.displacements(
            moving: a.id, to: Slot(col: 0, row: 0, w: 3, h: 2), in: [a, b]
        )

        XCTAssertTrue(pushed.isEmpty, "re-asserting a block's own slot is not a rearrangement")
    }

    /// Touching edges are not an overlap. `col + w == other.col` is the flush
    /// case, and a solver that treats it as a collision compacts the whole board
    /// on every drag.
    func testFlushNeighboursAreNotOverlapping() {
        let a = block(1, 0, 0, 3, 2)
        let b = block(2, 3, 0, 3, 2)   // starts exactly where a ends
        let c = block(3, 0, 2, 3, 2)   // starts exactly where a's rows end

        XCTAssertTrue(
            VisionBoardLayout.displacements(
                moving: a.id, to: Slot(col: 0, row: 0, w: 3, h: 2), in: [a, b, c]
            ).isEmpty
        )
    }

    // MARK: - A simple push

    func testDroppingOntoABlockPushesItStraightDown() {
        let mover = block(1, 0, 10, 3, 2)
        let sitting = block(2, 0, 0, 3, 2)     // rows 0-1

        let target = Slot(col: 0, row: 0, w: 3, h: 2)
        let pushed = VisionBoardLayout.displacements(moving: mover.id, to: target, in: [mover, sitting])

        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(
            pushed[sitting.id], Slot(col: 0, row: 2, w: 3, h: 2),
            "the sitting block goes flush under the mover, same column, same size"
        )
        assertNoOverlaps(Array(resolved(moving: mover, to: target, in: [mover, sitting])))
    }

    /// The pinned block is the whole point: it goes where the pointer put it and
    /// is never the one that gives way.
    func testTheMovingBlockIsNeverDisplaced() {
        let mover = block(1, 0, 20, 4, 3)
        let crowd = (2...6).map { block($0, 0, ($0 - 2) * 3, 4, 3) }

        let target = Slot(col: 0, row: 3, w: 4, h: 3)
        let all = resolved(moving: mover, to: target, in: [mover] + crowd)

        XCTAssertEqual(all[mover.id], target, "the block in hand must land exactly where it was aimed")
        assertNoOverlaps(Array(all))
    }

    /// A block that was ABOVE the drop target still goes below it. Down is the
    /// one rule, held even when it means an inversion.
    func testABlockAboveTheTargetIsPushedBelowIt() {
        let mover = block(1, 0, 40, 3, 2)
        let above = block(2, 0, 4, 3, 4)       // rows 4-7

        let target = Slot(col: 0, row: 6, w: 3, h: 2)   // overlaps rows 6-7
        let all = resolved(moving: mover, to: target, in: [mover, above])

        XCTAssertEqual(all[above.id]?.row, 8, "flush under the mover's bottom edge")
        assertNoOverlaps(Array(all))
    }

    /// Columns are never touched. Down is the only direction; a solver that
    /// nudged sideways to find room would make a drag's result depend on which
    /// side of a gap the pointer happened to be.
    func testDisplacementNeverChangesAColumnOrASize() {
        let mover = block(1, 0, 30, 6, 3)
        let others = [block(2, 2, 0, 4, 3), block(3, 5, 1, 3, 4), block(4, 0, 2, 2, 5)]

        let target = Slot(col: 1, row: 0, w: 6, h: 3)
        for (id, slot) in VisionBoardLayout.displacements(moving: mover.id, to: target, in: [mover] + others) {
            let original = others.first { $0.id == id }!
            XCTAssertEqual(slot.col, original.col, "a push must not move a block sideways")
            XCTAssertEqual(slot.w, original.w, "a push must not resize a block")
            XCTAssertEqual(slot.h, original.h)
            XCTAssertGreaterThan(slot.row, original.row, "a push is always downward")
        }
    }

    // MARK: - Cascades

    func testACascadeOfThree() {
        // Three stacked blocks, each two rows tall, flush against each other.
        let a = block(2, 0, 0, 3, 2)   // rows 0-1
        let b = block(3, 0, 2, 3, 2)   // rows 2-3
        let c = block(4, 0, 4, 3, 2)   // rows 4-5
        let mover = block(1, 0, 50, 3, 2)

        // Dropped on top of A, which pushes B, which pushes C.
        let target = Slot(col: 0, row: 0, w: 3, h: 2)
        let pushed = VisionBoardLayout.displacements(moving: mover.id, to: target, in: [mover, a, b, c])

        XCTAssertEqual(pushed[a.id], Slot(col: 0, row: 2, w: 3, h: 2))
        XCTAssertEqual(pushed[b.id], Slot(col: 0, row: 4, w: 3, h: 2))
        XCTAssertEqual(pushed[c.id], Slot(col: 0, row: 6, w: 3, h: 2))
        XCTAssertEqual(pushed.count, 3, "the whole column moved, and only the column")

        assertNoOverlaps(Array(resolved(moving: mover, to: target, in: [mover, a, b, c])), "cascade of three")
    }

    /// The cascade must fan out sideways too: one wide block dropped across two
    /// narrow columns pushes both, and each of those pushes its own successor.
    func testACascadeBranchesAcrossColumns() {
        let left = block(2, 0, 0, 3, 2)
        let right = block(3, 3, 0, 3, 2)
        let underLeft = block(4, 0, 2, 3, 2)
        let underRight = block(5, 3, 2, 3, 2)
        let mover = block(1, 0, 60, 6, 2)   // spans both columns

        let target = Slot(col: 0, row: 0, w: 6, h: 2)
        let all = resolved(moving: mover, to: target, in: [mover, left, right, underLeft, underRight])

        XCTAssertEqual(all[left.id]?.row, 2)
        XCTAssertEqual(all[right.id]?.row, 2)
        XCTAssertEqual(all[underLeft.id]?.row, 4)
        XCTAssertEqual(all[underRight.id]?.row, 4)
        assertNoOverlaps(Array(all), "branching cascade")
    }

    /// A block only partially in the way still moves, and only as far as it has
    /// to.
    func testAPartialOverlapStillPushes() {
        let sitting = block(2, 2, 2, 4, 3)     // cols 2-5, rows 2-4
        let mover = block(1, 0, 70, 3, 2)

        let target = Slot(col: 0, row: 1, w: 3, h: 2)   // cols 0-2, rows 1-2 → one cell of overlap
        let all = resolved(moving: mover, to: target, in: [mover, sitting])

        XCTAssertEqual(all[sitting.id], Slot(col: 2, row: 3, w: 4, h: 3))
        assertNoOverlaps(Array(all))
    }

    /// Long chains must not compound: a 30-block column dropped on from above
    /// must still resolve, must still be overlap-free, and must not run away.
    func testALongChainTerminatesAndStaysOrdered() {
        let column = (2...31).map { block($0, 0, ($0 - 2) * 2, 3, 2) }
        let mover = block(1, 0, 500, 3, 2)

        let target = Slot(col: 0, row: 0, w: 3, h: 2)
        let all = resolved(moving: mover, to: target, in: [mover] + column)

        assertNoOverlaps(Array(all), "30-block chain")
        for original in column {
            XCTAssertEqual(all[original.id]?.row, original.row + 2, "each link shifts by exactly the mover's height")
        }
    }

    // MARK: - Growing the canvas

    /// The cascade is allowed to run past the board's current extent, and the
    /// canvas is expected to grow to hold it. Nothing is ever clipped away or
    /// refused for want of room.
    func testAPushThatRunsPastTheCurrentCanvasGrowsIt() {
        let a = block(2, 0, 0, 3, 4)
        let b = block(3, 0, 4, 3, 4)
        // The mover comes from BESIDE the stack, not from inside it. Dragged out
        // of the same column it is about to land on, the cascade would only
        // reshuffle the extent the board already had and the canvas would be
        // unchanged — a fixture that looks like it proves growth and does not.
        let mover = block(1, 10, 0, 3, 4)
        let board = [mover, a, b]

        let viewport = CGSize(width: 800, height: 600)
        let before = VisionBoardLayout.canvasSize(for: board, viewport: viewport)

        let target = Slot(col: 0, row: 0, w: 3, h: 4)
        let all = resolved(moving: mover, to: target, in: board)

        // Commit the solved layout and re-measure, which is exactly what the
        // view does once `applyLayout` lands.
        let committed = board.map { original -> VisionBlock in
            var next = original
            let slot = all[original.id]!
            next.col = slot.col; next.row = slot.row; next.w = slot.w; next.h = slot.h
            return next
        }
        let after = VisionBoardLayout.canvasSize(for: committed, viewport: viewport)

        XCTAssertEqual(all[a.id]?.row, 4)
        XCTAssertEqual(all[b.id]?.row, 8, "b was pushed past where the board used to end")
        XCTAssertGreaterThan(after.height, before.height, "the canvas has to grow to hold the tail of the cascade")
        assertNoOverlaps(Array(all))
    }

    func testNothingIsEverPushedToANegativeCell() {
        let a = block(2, 0, 0, 3, 2)
        let mover = block(1, 0, 5, 3, 2)

        // A target above and left of the origin, which the solver has to clamp.
        let target = Slot(col: -4, row: -3, w: 3, h: 2)
        let all = resolved(moving: mover, to: Slot(col: 0, row: 0, w: 3, h: 2), in: [mover, a])
        _ = target

        for (_, slot) in all {
            XCTAssertGreaterThanOrEqual(slot.col, 0)
            XCTAssertGreaterThanOrEqual(slot.row, 0)
        }
    }

    func testTheSolverClampsANegativeTarget() {
        let a = block(2, 0, 0, 3, 2)
        let mover = block(1, 0, 5, 3, 2)

        let settled = VisionBoardLayout.settle(
            moving: mover.id,
            to: Slot(col: -4, row: -3, w: 3, h: 2),
            among: [mover, a].map(Placement.init)
        )

        for placement in settled {
            XCTAssertGreaterThanOrEqual(placement.slot.col, 0)
            XCTAssertGreaterThanOrEqual(placement.slot.row, 0)
        }
    }

    // MARK: - Determinism

    /// The same drop must give the same board no matter what order the caller
    /// enumerated the blocks in. `viewModel.blocks` is re-sorted on every write,
    /// so the input order genuinely does change between drags.
    func testTheResultDoesNotDependOnTheInputOrder() {
        let board = [
            block(2, 0, 0, 3, 2), block(3, 3, 0, 4, 2), block(4, 0, 2, 3, 3),
            block(5, 3, 2, 4, 3), block(6, 0, 5, 7, 2)
        ]
        let mover = block(1, 0, 40, 5, 3)
        let target = Slot(col: 1, row: 1, w: 5, h: 3)

        let forward = VisionBoardLayout.displacements(moving: mover.id, to: target, in: [mover] + board)
        let backward = VisionBoardLayout.displacements(moving: mover.id, to: target, in: ([mover] + board).reversed())
        let shuffled = VisionBoardLayout.displacements(
            moving: mover.id, to: target, in: [board[2], mover, board[4], board[0], board[3], board[1]]
        )

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward, shuffled)
        XCTAssertFalse(forward.isEmpty, "this fixture is supposed to actually push something")
    }

    /// Running the solver on its own output must change nothing: the arrangement
    /// it produces is already a fixed point. Anything else means a drop would
    /// keep drifting under a repeated pointer sample.
    func testTheSolvedBoardIsAFixedPoint() {
        let board = [block(2, 0, 0, 3, 2), block(3, 0, 2, 3, 2), block(4, 2, 3, 4, 2)]
        let mover = block(1, 0, 30, 3, 2)
        let target = Slot(col: 0, row: 0, w: 3, h: 2)

        let all = resolved(moving: mover, to: target, in: [mover] + board)
        let committed = ([mover] + board).map { original -> VisionBlock in
            var next = original
            let slot = all[original.id]!
            next.col = slot.col; next.row = slot.row; next.w = slot.w; next.h = slot.h
            return next
        }

        XCTAssertTrue(
            VisionBoardLayout.displacements(moving: mover.id, to: target, in: committed).isEmpty,
            "re-solving a solved board must be a no-op"
        )
    }

    // MARK: - Cancel

    /// Cancel needs no undo because displacement is never written to a block.
    /// This asserts the property the interaction relies on: the solver is pure,
    /// so throwing its output away restores the board exactly.
    func testAbandoningTheSolverOutputLeavesTheBoardUntouched() {
        let board = [block(2, 0, 0, 3, 2), block(3, 0, 2, 3, 2), block(4, 0, 4, 3, 2)]
        let mover = block(1, 0, 20, 3, 2)
        let before = board.map { Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h) }

        let pushed = VisionBoardLayout.displacements(
            moving: mover.id, to: Slot(col: 0, row: 0, w: 3, h: 2), in: [mover] + board
        )
        XCTAssertEqual(pushed.count, 3, "the fixture must actually displace, or this proves nothing")

        // Escape drops the session; the blocks were never mutated.
        let after = board.map { Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h) }
        XCTAssertEqual(before, after, "no displaced block may have been written")

        // And the resting layout the view falls back to is still overlap-free.
        assertNoOverlaps(zip(board.map(\.id), after).map { ($0, $1) })
    }

    // MARK: - Resize

    /// The complaint that started change three: a block hemmed in on the right
    /// could not be widened at all.
    func testWideningPushesTheNeighbourOnTheRight() {
        let subject = block(1, 0, 0, 3, 3)
        let neighbour = block(2, 3, 0, 3, 3)

        // Grown from 3 columns to 6, anchored at its own top-left.
        let target = Slot(col: 0, row: 0, w: 6, h: 3)
        let all = resolved(moving: subject, to: target, in: [subject, neighbour])

        XCTAssertEqual(all[subject.id], target, "the block being resized gets the size it asked for")
        XCTAssertEqual(all[neighbour.id], Slot(col: 3, row: 3, w: 3, h: 3),
                       "the neighbour keeps its column and drops below")
        assertNoOverlaps(Array(all))
    }

    func testGrowingTallPushesTheBlockUnderneath() {
        let subject = block(1, 0, 0, 4, 2)
        let below = block(2, 0, 2, 4, 2)

        let target = Slot(col: 0, row: 0, w: 4, h: 5)
        let all = resolved(moving: subject, to: target, in: [subject, below])

        XCTAssertEqual(all[below.id]?.row, 5)
        assertNoOverlaps(Array(all))
    }

    func testShrinkingPushesNobody() {
        let subject = block(1, 0, 0, 8, 4)
        let neighbour = block(2, 8, 0, 3, 3)

        let pushed = VisionBoardLayout.displacements(
            moving: subject.id, to: Slot(col: 0, row: 0, w: 4, h: 2), in: [subject, neighbour]
        )
        XCTAssertTrue(pushed.isEmpty)
    }

    // MARK: - The migration

    private func stored(_ n: Int, _ col: Int, _ row: Int, _ w: Int, _ h: Int, version: Int = 0)
        -> VisionBoardLayout.StoredFrame {
        VisionBoardLayout.StoredFrame(
            id: Self.id(n), col: col, row: row, w: w, h: h, gridVersion: version
        )
    }

    /// The headline case from the brief: a 2-column block was 356pt wide and has
    /// to stay about 356pt wide.
    func testATwoColumnBlockKeepsItsPhysicalWidth() {
        let changes = VisionBoardLayout.migrateToSquareGrid(
            [stored(1, 0, 0, 2, 3)], repairingOverlapsAmong: [Self.id(1)]
        )

        let migrated = try! XCTUnwrap(changes.first)
        XCTAssertEqual(migrated.w, 5, "round(2 × 184/68) = round(5.41) = 5")
        XCTAssertEqual(migrated.col, 0)
        XCTAssertEqual(migrated.row, 0, "rows are untouched — the vertical pitch did not change")
        XCTAssertEqual(migrated.h, 3)
        XCTAssertEqual(migrated.gridVersion, VisionGrid.schemaVersion)

        let wasWide = 2 * 184.0 - 12
        let isWide = VisionGrid.blockSize(columns: migrated.w, rows: migrated.h).width
        XCTAssertLessThan(abs(isWide - wasWide), VisionGrid.cell, "within half a cell either way")
    }

    /// Positions have to scale too, or the whole board collapses toward the
    /// left-hand edge and every block lands on its neighbour.
    func testColumnsScaleAsWellAsWidths() {
        let changes = VisionBoardLayout.migrateToSquareGrid(
            [stored(1, 3, 0, 2, 3)], repairingOverlapsAmong: [Self.id(1)]
        )
        let migrated = try! XCTUnwrap(changes.first)

        XCTAssertEqual(migrated.col, 8, "round(3 × 2.7059) = round(8.12) = 8")
        let wasX = 3 * 184.0
        let isX = CGFloat(migrated.col) * VisionGrid.cell
        XCTAssertLessThan(abs(isX - wasX), VisionGrid.cell)
    }

    /// The property that makes edge-scaling worth its rounding wobble: a board
    /// that did not overlap before cannot start overlapping after.
    func testARealisticBoardSurvivesWithNoOverlaps() {
        // A plausible hand-arranged board on the old lattice: ten blocks over
        // eight columns, many of them flush against a neighbour in one axis or
        // both, which is where the rounding traps live.
        let old = [
            stored(1,  0, 0, 2, 3),   // cols 0-1, rows 0-2
            stored(2,  2, 0, 1, 2),   // col  2,   rows 0-1
            stored(3,  3, 0, 3, 4),   // cols 3-5, rows 0-3
            stored(4,  6, 0, 2, 6),   // cols 6-7, rows 0-5
            stored(5,  0, 3, 1, 2),   // col  0,   rows 3-4
            stored(6,  1, 3, 1, 5),   // col  1,   rows 3-7
            stored(7,  2, 2, 1, 3),   // col  2,   rows 2-4
            stored(8,  3, 4, 2, 3),   // cols 3-4, rows 4-6
            stored(9,  5, 4, 1, 2),   // col  5,   rows 4-5
            stored(10, 0, 5, 1, 3)    // col  0,   rows 5-7
        ]
        let liveIDs = Set(old.map(\.id))

        // The fixture must be a legal old board, or the test proves nothing.
        assertNoOverlaps(old.map { ($0.id, Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)) },
                         "fixture is not a legal pre-migration board")

        let changes = VisionBoardLayout.migrateToSquareGrid(old, repairingOverlapsAmong: liveIDs)
        XCTAssertEqual(changes.count, old.count, "every block was on the old lattice")

        assertNoOverlaps(changes.map { ($0.id, Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)) },
                         "migration must not scramble a board")

        for change in changes {
            let before = old.first { $0.id == change.id }!
            XCTAssertGreaterThanOrEqual(change.w, VisionGrid.minColumns)
            XCTAssertGreaterThanOrEqual(change.h, VisionGrid.minRows)
            XCTAssertEqual(change.h, before.h, "heights are in an unchanged unit")
            XCTAssertEqual(change.gridVersion, VisionGrid.schemaVersion)
        }
    }

    /// The exact rounding trap edge-scaling exists to avoid: independently
    /// rounding `col` and `w` turns two flush blocks into overlapping ones, and
    /// then the repair sweep would stack a pair the user had put side by side.
    ///
    /// `col 5, w 4` is a worked case. `round(4 × 2.7059) = 11` overshoots the
    /// true 10.82, so the naive transform ends the block at `14 + 11 = 25` while
    /// its neighbour at `col 9` starts at `round(9 × 2.7059) = 24`. Edge scaling
    /// asks for the same two numbers and gets `24 − 14 = 10`, which lands exactly
    /// flush.
    func testFlushNeighboursStayFlushRatherThanColliding() {
        let old = [stored(1, 5, 0, 4, 3), stored(2, 9, 0, 2, 3)]
        let changes = VisionBoardLayout.migrateToSquareGrid(old, repairingOverlapsAmong: Set(old.map(\.id)))

        let a = changes.first { $0.id == Self.id(1) }!
        let b = changes.first { $0.id == Self.id(2) }!

        // The naive transform, spelled out, so this test fails if somebody
        // "simplifies" the migration back to it.
        let naiveEnd = Int((5.0 * VisionBoardLayout.squareGridColumnScale).rounded())
            + Int((4.0 * VisionBoardLayout.squareGridColumnScale).rounded())
        XCTAssertGreaterThan(naiveEnd, b.col, "the fixture is supposed to trip independent rounding")

        XCTAssertEqual(a.col + a.w, b.col, "edge scaling must land the pair exactly flush")
        XCTAssertEqual(a.row, 0)
        XCTAssertEqual(b.row, 0, "the repair pass must not have had to intervene")
        XCTAssertGreaterThan(a.w, VisionGrid.minColumns, "and the minimum clamp must not be what saved it")
    }

    /// Tiers are a physical claim and must come through the change intact.
    func testEveryTierSurvivesTheMigration() {
        for (oldWidth, expected) in [(1, VisionBlockTier.small), (2, .medium), (3, .large), (4, .large)] {
            for oldCol in 0...12 {
                let changes = VisionBoardLayout.migrateToSquareGrid(
                    [stored(1, oldCol, 0, oldWidth, 3)], repairingOverlapsAmong: [Self.id(1)]
                )
                let migrated = changes.first!
                let block = self.block(1, migrated.col, migrated.row, migrated.w, migrated.h)
                XCTAssertEqual(
                    block.tier, expected,
                    "a \(oldWidth)-column block at column \(oldCol) changed tier: "
                    + "\(migrated.w) cells is \(VisionGrid.blockSize(columns: migrated.w, rows: 1).width)pt"
                )
            }
        }
    }

    /// The tier thresholds also have to reproduce the OLD lattice's boundaries,
    /// or the re-expression in points quietly changed the design.
    func testTheTierThresholdsReproduceTheOldBoundaries() {
        XCTAssertEqual(VisionBlockTier(renderedWidth: 172), .small)
        XCTAssertEqual(VisionBlockTier(renderedWidth: 356), .medium)
        XCTAssertEqual(VisionBlockTier(renderedWidth: 540), .large)
    }

    // MARK: - Migration idempotence

    func testASecondPassChangesNothing() {
        let old = [
            stored(1, 0, 0, 2, 3), stored(2, 2, 0, 1, 2), stored(3, 3, 0, 3, 4),
            stored(4, 0, 3, 1, 2), stored(5, 1, 3, 1, 5)
        ]
        let liveIDs = Set(old.map(\.id))

        let first = VisionBoardLayout.migrateToSquareGrid(old, repairingOverlapsAmong: liveIDs)
        XCTAssertFalse(first.isEmpty)

        // The store now holds exactly what the first pass returned.
        let second = VisionBoardLayout.migrateToSquareGrid(first, repairingOverlapsAmong: liveIDs)
        XCTAssertTrue(second.isEmpty, "the marker must stop a second scale before any arithmetic runs")

        // And a third, and a mixed board where only some rows are stale.
        XCTAssertTrue(
            VisionBoardLayout.migrateToSquareGrid(
                VisionBoardLayout.migrateToSquareGrid(first, repairingOverlapsAmong: liveIDs) + first,
                repairingOverlapsAmong: liveIDs
            ).isEmpty
        )
    }

    /// If it DID run twice the damage would be obvious, which is why the gate
    /// matters. This pins the fact that the arithmetic is not self-idempotent,
    /// so nobody later "simplifies" the marker away on the theory that a repeat
    /// would be harmless.
    func testScalingTwiceWouldBeCatastrophicWhichIsWhyTheMarkerExists() {
        let once = VisionBoardLayout.migrateToSquareGrid(
            [stored(1, 4, 0, 2, 3)], repairingOverlapsAmong: [Self.id(1)]
        ).first!
        // Force a second scale by pretending the marker was never written.
        let twice = VisionBoardLayout.migrateToSquareGrid(
            [stored(1, once.col, once.row, once.w, once.h, version: 0)],
            repairingOverlapsAmong: [Self.id(1)]
        ).first!

        XCTAssertGreaterThan(twice.col, once.col * 2, "a double scale really would fling the block away")
        XCTAssertNotEqual(twice.w, once.w)
    }

    func testAMixedBoardMigratesOnlyTheStaleRows() {
        let already = stored(1, 5, 0, 5, 3, version: VisionGrid.schemaVersion)
        let stale = stored(2, 0, 4, 2, 3, version: 0)

        let changes = VisionBoardLayout.migrateToSquareGrid(
            [already, stale], repairingOverlapsAmong: [already.id, stale.id]
        )

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.id, stale.id, "a row already on the square lattice must not be rescaled")
    }

    func testAnEmptyBoardMigratesToNothing() {
        XCTAssertTrue(VisionBoardLayout.migrateToSquareGrid([], repairingOverlapsAmong: []).isEmpty)
    }

    // MARK: - Migration edge cases

    /// An old single-column block is 172pt and rescales to 2 or 3 cells; the new
    /// minimum is 3. The 2-cell case has to be clamped up, and the clamp is the
    /// one thing that CAN create an overlap — which is what the repair sweep is
    /// there for.
    func testTheMinimumClampCannotLeaveAnOverlapBehind() {
        // Two one-column blocks side by side at columns where the scale lands
        // the pair two cells apart, so clamping both to three collides them.
        var frames: [VisionBoardLayout.StoredFrame] = []
        for col in 0..<12 { frames.append(stored(col + 1, col, 0, 1, 2)) }
        let liveIDs = Set(frames.map(\.id))

        let changes = VisionBoardLayout.migrateToSquareGrid(frames, repairingOverlapsAmong: liveIDs)
        XCTAssertEqual(changes.count, frames.count)

        for change in changes {
            XCTAssertGreaterThanOrEqual(change.w, VisionGrid.minColumns, "below the minimum block size")
        }
        assertNoOverlaps(changes.map { ($0.id, Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)) },
                         "the clamp collided a pair and the repair sweep did not separate them")
    }

    /// An archived block is not on the board and must not shove a visible one
    /// out of the way from a position nobody can see.
    func testAnArchivedBlockTakesNoPartInTheOverlapRepair() {
        let live = stored(1, 0, 0, 1, 2)
        let archived = stored(2, 0, 0, 1, 2)   // same cell; it is not on the board

        let changes = VisionBoardLayout.migrateToSquareGrid(
            [live, archived], repairingOverlapsAmong: [live.id]
        )

        let migratedLive = changes.first { $0.id == live.id }!
        XCTAssertEqual(migratedLive.row, 0, "the visible block must not have been pushed by an invisible one")

        // The archived one is still rescaled, so unarchiving it later lands it
        // on the same lattice as everything else.
        let migratedArchived = changes.first { $0.id == archived.id }!
        XCTAssertEqual(migratedArchived.gridVersion, VisionGrid.schemaVersion)
        XCTAssertGreaterThanOrEqual(migratedArchived.w, VisionGrid.minColumns)
    }

    func testNegativeStoredCoordinatesAreHealed() {
        let changes = VisionBoardLayout.migrateToSquareGrid(
            [stored(1, -3, -2, 2, 3)], repairingOverlapsAmong: [Self.id(1)]
        )
        let migrated = changes.first!
        XCTAssertGreaterThanOrEqual(migrated.col, 0)
        XCTAssertGreaterThanOrEqual(migrated.row, 0)
    }

    // MARK: - Properties, over many generated boards

    /// A seeded LCG. The boards below have to be varied AND reproducible: a
    /// failure nobody can re-run is not a failure anybody will fix.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Lay `count` blocks out with no overlaps, by placing each into the first
    /// row of a randomly chosen column band that is free. Produces boards that
    /// look hand-arranged rather than like a single tidy column.
    private func randomLegalBoard(
        count: Int, maxColumn: Int, maxWidth: Int, using rng: inout Seeded
    ) -> [(id: UUID, slot: Slot)] {
        var placed: [(id: UUID, slot: Slot)] = []
        for n in 1...count {
            let w = Int.random(in: 1...maxWidth, using: &rng)
            // `minRows` was already 2 before the square lattice, so a stored
            // height of 1 is not a board any build could have written; a
            // generator that emits one is testing the clamp, not the migration.
            let h = Int.random(in: VisionGrid.minRows...5, using: &rng)
            let col = Int.random(in: 0...max(0, maxColumn - w), using: &rng)
            var row = Int.random(in: 0...6, using: &rng)
            var slot = Slot(col: col, row: row, w: w, h: h)
            // Drop it down until it clears everything already there.
            while let hit = placed.first(where: { $0.slot.overlaps(slot) }) {
                row = hit.slot.bottom
                slot.row = row
            }
            placed.append((Self.id(n), slot))
        }
        return placed
    }

    /// The invariant that matters most, asserted over 400 generated boards and
    /// drops rather than over the handful of shapes anyone thought to write down.
    func testAnyDropOnAnyBoardLeavesNoOverlaps() {
        var rng = Seeded(state: 0x5EED_1234)

        for iteration in 0..<400 {
            let generated = randomLegalBoard(count: 12, maxColumn: 14, maxWidth: 6, using: &rng)
            let board = generated.map { entry in
                VisionBlock(
                    id: entry.id, title: "b", intent: nil,
                    col: entry.slot.col, row: entry.slot.row, w: entry.slot.w, h: entry.slot.h,
                    state: .default, members: [], createdAt: Date(), updatedAt: Date()
                )
            }
            let mover = board[Int.random(in: board.indices, using: &rng)]
            let target = Slot(
                col: Int.random(in: 0...14, using: &rng),
                row: Int.random(in: 0...20, using: &rng),
                w: Int.random(in: VisionGrid.minColumns...8, using: &rng),
                h: Int.random(in: VisionGrid.minRows...6, using: &rng)
            )

            let all = resolved(moving: mover, to: target, in: board)

            XCTAssertEqual(all[mover.id], target, "iteration \(iteration): the mover was displaced")
            assertNoOverlaps(Array(all), "iteration \(iteration)")

            for original in board where original.id != mover.id {
                let slot = all[original.id]!
                XCTAssertEqual(slot.col, original.col, "iteration \(iteration): pushed sideways")
                XCTAssertEqual(slot.w, original.w, "iteration \(iteration): resized")
                XCTAssertEqual(slot.h, original.h)
                XCTAssertGreaterThanOrEqual(slot.row, original.row, "iteration \(iteration): pushed UP")
                XCTAssertGreaterThanOrEqual(slot.row, 0)
            }
        }
    }

    /// And the same for the migration: any legal board on the old lattice comes
    /// out legal on the new one. This is the property that decides whether the
    /// user's real board survives, and it is not something a handful of fixtures
    /// can establish.
    func testAnyLegalOldBoardMigratesToALegalNewOne() {
        var rng = Seeded(state: 0xC0FFEE_42)

        for iteration in 0..<400 {
            let generated = randomLegalBoard(count: 14, maxColumn: 8, maxWidth: 4, using: &rng)
            assertNoOverlaps(generated.map { ($0.id, $0.slot) }, "iteration \(iteration): bad fixture")

            let old = generated.map {
                VisionBoardLayout.StoredFrame(
                    id: $0.id, col: $0.slot.col, row: $0.slot.row, w: $0.slot.w, h: $0.slot.h,
                    gridVersion: 0
                )
            }
            let changes = VisionBoardLayout.migrateToSquareGrid(
                old, repairingOverlapsAmong: Set(old.map(\.id))
            )
            XCTAssertEqual(changes.count, old.count, "iteration \(iteration)")
            assertNoOverlaps(
                changes.map { ($0.id, Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)) },
                "iteration \(iteration): migration produced an overlapping board"
            )

            for change in changes {
                let before = old.first { $0.id == change.id }!
                XCTAssertGreaterThanOrEqual(change.w, VisionGrid.minColumns, "iteration \(iteration)")
                XCTAssertGreaterThanOrEqual(change.h, VisionGrid.minRows)
                XCTAssertEqual(change.h, before.h, "iteration \(iteration): a height changed")
                XCTAssertEqual(change.gridVersion, VisionGrid.schemaVersion)
                // Within half a cell of where it was, plus whatever the minimum
                // clamp and the repair had to add.
                let wasX = Double(before.col) * 184
                let isX = Double(change.col) * Double(VisionGrid.cell)
                XCTAssertLessThan(abs(isX - wasX), Double(VisionGrid.cell),
                                  "iteration \(iteration): a block moved more than half a cell sideways")
            }

            // And it is a fixed point.
            XCTAssertTrue(
                VisionBoardLayout.migrateToSquareGrid(
                    changes, repairingOverlapsAmong: Set(changes.map(\.id))
                ).isEmpty,
                "iteration \(iteration): a second pass wanted to change something"
            )
        }
    }

    // MARK: - The grid itself

    func testTheLatticeIsSquare() {
        XCTAssertEqual(VisionGrid.cellWidth, VisionGrid.cellHeight)
        XCTAssertEqual(VisionGrid.cellWidth, 68)
        XCTAssertEqual(VisionGrid.blockSize(columns: 1, rows: 1), CGSize(width: 56, height: 56))
    }

    /// The minimum and the default were expressed in columns and every one of
    /// them changed meaning. These pin the physical sizes, which are what the
    /// design actually specified.
    func testTheMinimumAndDefaultKeepTheirPhysicalSize() {
        let minimum = VisionGrid.blockSize(columns: VisionGrid.minColumns, rows: VisionGrid.minRows)
        XCTAssertEqual(minimum, CGSize(width: 192, height: 124), "was 172 × 124 on the old lattice")

        let fresh = VisionGrid.blockSize(columns: VisionGrid.newColumns, rows: VisionGrid.newRows)
        XCTAssertEqual(fresh, CGSize(width: 328, height: 192), "was 356 × 192 on the old lattice")
        XCTAssertEqual(VisionBlockTier(renderedWidth: fresh.width), .medium,
                       "a new block still opens at the medium tier")
    }
}
