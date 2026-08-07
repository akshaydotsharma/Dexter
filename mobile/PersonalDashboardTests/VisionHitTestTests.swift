import XCTest
@testable import PersonalDashboard

/// The vision board's pointer resolver (#446).
///
/// `VisionHitTest` is the piece the AppKit rewrite exists for. The board's drag
/// never worked through four rounds of SwiftUI gesture fixes because "which
/// recogniser owns this click" was not a question anyone could answer from the
/// outside, and it was not answered the same way twice. Making it a pure
/// function of rectangles turns it into something a test can state outright.
///
/// These run in the iOS-hosted target on purpose. The resolver carries no
/// AppKit, so it compiles on both platforms, and keeping it here means it runs
/// in the same command as `VisionBoardLayoutTests` rather than needing the
/// macOS host that the pointer view's own tests do.
final class VisionHitTestTests: XCTestCase {

    // MARK: - Fixtures

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    /// A block at the given cell, as the board would render it.
    private func frame(_ n: Int, col: Int, row: Int, w: Int = 5, h: Int = 3) -> VisionHitTest.Frame {
        VisionHitTest.Frame(
            id: Self.id(n),
            rect: CGRect(
                origin: VisionGrid.origin(col: col, row: row),
                size: VisionGrid.blockSize(columns: w, rows: h)
            )
        )
    }

    // MARK: - The four answers

    func testAPointInsideABlockIsItsBody() {
        let block = frame(1, col: 0, row: 0)

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 100, y: 60), blocks: [block], exclusions: []
        )

        XCTAssertEqual(hit, .body(Self.id(1)))
    }

    func testTheBottomRightCornerIsTheGrip() {
        let block = frame(1, col: 0, row: 0)
        // 5 × 3 renders 328 × 192. The grip is 20pt square, 8pt in from both
        // edges, so its centre is 18pt in from each: (310, 174).
        XCTAssertEqual(block.rect, CGRect(x: 0, y: 0, width: 328, height: 192))

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 310, y: 174), blocks: [block], exclusions: []
        )

        XCTAssertEqual(hit, .grip(Self.id(1)))
    }

    /// The grip has to be a small, deliberate target rather than "the bottom
    /// right quadrant", or half the block would resize instead of moving.
    func testJustOutsideTheGripIsStillBody() {
        let block = frame(1, col: 0, row: 0)

        XCTAssertEqual(
            VisionHitTest.resolve(
                point: CGPoint(x: 299, y: 174), blocks: [block], exclusions: []
            ),
            .body(Self.id(1)),
            "one point left of the grip's leading edge"
        )
        XCTAssertEqual(
            VisionHitTest.resolve(
                point: CGPoint(x: 310, y: 163), blocks: [block], exclusions: []
            ),
            .body(Self.id(1)),
            "one point above the grip's top edge"
        )
    }

    func testAPointOffEveryBlockIsCanvasAtThatCell() {
        let block = frame(1, col: 0, row: 0)

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 68 * 6 + 10, y: 68 * 4 + 10), blocks: [block], exclusions: []
        )

        XCTAssertEqual(hit, .canvas(col: 6, row: 4))
    }

    func testAPointOnAnExcludedChildPassesThrough() {
        let block = frame(1, col: 0, row: 0)
        // A tile row: full block width less the 12pt card padding, 26pt tall.
        let tile = CGRect(x: 12, y: 70, width: 304, height: 26)

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 20, y: 80), blocks: [block], exclusions: [tile]
        )

        XCTAssertEqual(
            hit, .passThrough,
            "a checkbox click must reach SwiftUI, not start a drag"
        )
    }

    // MARK: - Ordering

    /// Committed blocks never overlap, but a block being resized renders past
    /// its own cells and over its neighbour. The one the user is steering is
    /// drawn last and is the one they mean.
    func testOverlappingBlocksResolveToTheTopmost() {
        let under = VisionHitTest.Frame(id: Self.id(1), rect: CGRect(x: 0, y: 0, width: 328, height: 192))
        let over = VisionHitTest.Frame(id: Self.id(2), rect: CGRect(x: 100, y: 0, width: 328, height: 192))

        XCTAssertEqual(
            VisionHitTest.resolve(point: CGPoint(x: 150, y: 60), blocks: [under, over], exclusions: []),
            .body(Self.id(2)),
            "last in draw order wins"
        )
        XCTAssertEqual(
            VisionHitTest.resolve(point: CGPoint(x: 50, y: 60), blocks: [under, over], exclusions: []),
            .body(Self.id(1)),
            "outside the topmost, the one underneath still answers"
        )
    }

    /// At `large` the add-task field spans the block's foot and its rect reaches
    /// under the grip, which is drawn on top of it. Resolve the other way round
    /// and a wide block could not be resized at all.
    func testTheGripOutranksAnOverlappingExclusion() {
        let block = frame(1, col: 0, row: 0)
        let addRow = CGRect(x: 12, y: 154, width: 304, height: 26)
        XCTAssertTrue(addRow.contains(CGPoint(x: 310, y: 174)), "precondition: the rects overlap")

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 310, y: 174), blocks: [block], exclusions: [addRow]
        )

        XCTAssertEqual(hit, .grip(Self.id(1)))
    }

    // MARK: - Gutters and edges

    /// The gutter is the trailing 12pt of a cell, not a cell of its own: a 5 × 3
    /// block renders 328pt into a 340pt footprint. A point in the gap between
    /// two stacked blocks is therefore canvas, at the LAST row of the block
    /// above it. Asserted rather than assumed, because a click there creates a
    /// block and it has to land somewhere predictable.
    func testAPointInTheGutterBetweenTwoBlocksIsCanvas() {
        let top = frame(1, col: 0, row: 0)
        let bottom = frame(2, col: 0, row: 3)
        XCTAssertEqual(top.rect.maxY, 192)
        XCTAssertEqual(bottom.rect.minY, 204)

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 40, y: 198), blocks: [top, bottom], exclusions: []
        )

        XCTAssertEqual(hit, .canvas(col: 0, row: 2))
    }

    func testAnExclusionOffEveryBlockStillPassesThrough() {
        let button = CGRect(x: 500, y: 500, width: 120, height: 40)

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 540, y: 520), blocks: [], exclusions: [button]
        )

        XCTAssertEqual(hit, .passThrough)
    }

    /// A drag that runs off the leading or top edge pins to the first cell
    /// rather than producing a negative column no creation can satisfy.
    func testNegativePointsClampToTheFirstCell() {
        let hit = VisionHitTest.resolve(
            point: CGPoint(x: -40, y: -10), blocks: [], exclusions: []
        )

        XCTAssertEqual(hit, .canvas(col: 0, row: 0))
    }

    // MARK: - The grip rect itself

    /// What you can see and what you can grab come from the same two constants.
    /// They are separated in the card by a `.frame` and a `.padding`, and a
    /// silent drift between them is a defect nobody can photograph.
    func testGripRectMatchesTheDrawnGlyph() {
        let rect = CGRect(x: 68, y: 136, width: 328, height: 192)

        let grip = VisionHitTest.gripRect(in: rect)

        XCTAssertEqual(grip.width, VisionBlockMetrics.resizeTarget)
        XCTAssertEqual(grip.height, VisionBlockMetrics.resizeTarget)
        XCTAssertEqual(grip.maxX, rect.maxX - Space.sm)
        XCTAssertEqual(grip.maxY, rect.maxY - Space.sm)
    }

    // MARK: - Hover's separate question

    /// Hover asks which block, ignoring exclusions, so moving the pointer onto a
    /// tile does not read as leaving the block and flicker the grip and the
    /// ellipsis off.
    func testBlockLookupIgnoresExclusions() {
        let block = frame(1, col: 0, row: 0)

        XCTAssertEqual(VisionHitTest.block(at: CGPoint(x: 20, y: 80), in: [block]), Self.id(1))
        XCTAssertNil(VisionHitTest.block(at: CGPoint(x: 900, y: 80), in: [block]))
    }
}
