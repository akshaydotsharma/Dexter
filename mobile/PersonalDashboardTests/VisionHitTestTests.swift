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

    /// A full-width row at the block's foot has a rect that reaches under the
    /// grip, which is drawn on top of it. Resolve the other way round and a wide
    /// block could not be resized at all.
    func testTheGripOutranksAnOverlappingExclusion() {
        let block = frame(1, col: 0, row: 0)
        let footRow = CGRect(x: 12, y: 154, width: 304, height: 26)
        XCTAssertTrue(footRow.contains(CGPoint(x: 310, y: 174)), "precondition: the rects overlap")

        let hit = VisionHitTest.resolve(
            point: CGPoint(x: 310, y: 174), blocks: [block], exclusions: [footRow]
        )

        XCTAssertEqual(hit, .grip(Self.id(1)))
    }

    /// The reported defect: the grip's target used to stop `Space.sm` short of
    /// the block's corner, so the last 8pt diagonally into the corner was body.
    /// That is precisely where a person aims, because it is where every window
    /// and every spreadsheet cell puts its handle, and landing there began a
    /// MOVE. A block sliding away when you meant to widen it reads as the board
    /// being broken, not as a missed 8pt.
    func testTheVeryCornerOfABlockIsGripAndNotBody() {
        let block = frame(1, col: 0, row: 0)

        // One point in from the corner, on the diagonal: as close as a pointer
        // can get to the handle without leaving the block.
        let corner = CGPoint(x: block.rect.maxX - 1, y: block.rect.maxY - 1)

        XCTAssertEqual(
            VisionHitTest.resolve(point: corner, blocks: [block], exclusions: []),
            .grip(Self.id(1))
        )
    }

    /// The other half of the same rule: widening the target must not eat the
    /// card. A point just inside the grip's reach is grip; a point just outside
    /// it is still body, so the block stays draggable everywhere else.
    func testJustBeyondTheGripsReachIsStillBody() {
        let block = frame(1, col: 0, row: 0)
        let grip = VisionHitTest.gripRect(in: block.rect)

        let justOutside = CGPoint(x: grip.minX - 1, y: grip.minY - 1)

        XCTAssertEqual(
            VisionHitTest.resolve(point: justOutside, blocks: [block], exclusions: []),
            .body(Self.id(1))
        )
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

    /// The target is deliberately LARGER than the glyph, and the relationship
    /// between them is the thing worth pinning.
    ///
    /// This test used to assert they were identical. That was the defect: the
    /// glyph is inset `Space.sm` for looks, so an exact match left the corner
    /// itself as body and aiming at the handle moved the block. The glyph still
    /// draws where it drew; the target now swallows the inset and runs out to
    /// the corner, so both still derive from the same two constants and cannot
    /// silently drift apart.
    func testTheGripTargetCoversTheGlyphAndReachesTheCorner() {
        let rect = CGRect(x: 68, y: 136, width: 328, height: 192)
        let glyph = CGRect(
            x: rect.maxX - Space.sm - VisionBlockMetrics.resizeTarget,
            y: rect.maxY - Space.sm - VisionBlockMetrics.resizeTarget,
            width: VisionBlockMetrics.resizeTarget,
            height: VisionBlockMetrics.resizeTarget
        )

        let grip = VisionHitTest.gripRect(in: rect)

        XCTAssertTrue(grip.contains(glyph), "everything drawn must be grabbable")
        XCTAssertEqual(grip.maxX, rect.maxX, "the target reaches the trailing edge")
        XCTAssertEqual(grip.maxY, rect.maxY, "the target reaches the bottom edge")
        XCTAssertEqual(grip.width, VisionBlockMetrics.resizeTarget + Space.sm)
        XCTAssertEqual(grip.height, VisionBlockMetrics.resizeTarget + Space.sm)
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
