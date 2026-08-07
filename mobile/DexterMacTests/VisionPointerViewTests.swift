import XCTest
import AppKit
@testable import DexterMac

/// The vision board's pointer layer, driven headlessly (#446).
///
/// ### Why these tests exist in this shape
///
/// The block drag shipped four rounds of SwiftUI gesture fixes and never once
/// worked. Two confident diagnoses were wrong, and the reported symptom —
/// *"sometimes it expands, sometimes it doesn't"* — is the signature of
/// recogniser racing rather than of a logic error. None of that is visible in a
/// build or a screenshot.
///
/// Driving the real app was tried and cannot be made to work from an agent:
/// modern macOS cooperative activation refuses key-window status to a
/// background-launched app while another app holds focus, and mouse events
/// posted to a non-key window are treated as activation clicks rather than
/// drags. Every attempt logged `key=false active=false`, by direct binary
/// launch, by `open`, and by LaunchServices activation.
///
/// So the architecture was chosen to be assertable without any of that. These
/// tests construct `VisionPointerView` directly, synthesise `NSEvent`s, invoke
/// `mouseDown` / `mouseDragged` / `mouseUp` / `keyDown` by hand, and check both
/// the live `VisionInteraction` and what actually landed in an in-memory
/// SwiftData store. No window, no key status, no screen, no timing.
///
/// ### What this deliberately does not cover
///
/// `VisionPointerView.canvasPoint(for:)` calls `convert(_:from: nil)` when it
/// has a window and reads `locationInWindow` as canvas space when it does not.
/// These run in the second branch. The conversion itself, and AppKit's promise
/// to deliver `mouseUp` for an accepted `mouseDown`, are the two things that
/// stay a matter of documented AppKit behaviour rather than assertion.
@MainActor
final class VisionPointerViewTests: XCTestCase {

    // MARK: - Fixtures

    /// Generous, so nothing in these tests is accidentally testing the canvas
    /// clamp instead of the thing it names.
    private let canvas = CGSize(width: 2000, height: 1400)

    private var store: SwiftDataStore!
    private var service: VisionBoardService!
    private var viewModel: VisionBoardViewModel!
    private var interaction: VisionInteraction!
    private var view: VisionPointerView!
    /// Cells `onCreate` was asked for, so a click on empty canvas is checkable
    /// without going through the async create.
    private var createdCells: [(col: Int, row: Int)] = []

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = VisionBoardService(store: store)
        viewModel = VisionBoardViewModel(
            board: service, todos: TodoService(store: store)
        )
        interaction = VisionInteraction()
        createdCells = []

        view = VisionPointerView(frame: CGRect(origin: .zero, size: canvas))
        view.interaction = interaction
        view.canvasSize = canvas
        // The real wiring from `VisionBoardView`: the pointer layer hands the
        // frames to the view model, which writes them in one save.
        view.commit = { [viewModel] frames in await viewModel?.applyLayout(frames) }
        // Stands in for the board's `creationSlot` check: any cell not already
        // covered by a block accepts one.
        view.onCanvasClick = { [weak self] col, row in
            guard let self else { return false }
            let slot = VisionBoardLayout.Slot(
                col: col, row: row, w: VisionGrid.newColumns, h: VisionGrid.newRows
            )
            guard VisionBoardLayout.isFree(slot, in: self.viewModel.blocks, excluding: nil) else {
                return false
            }
            self.createdCells.append((col, row))
            return true
        }
    }

    override func tearDown() async throws {
        view = nil
        interaction = nil
        viewModel = nil
        service = nil
        store = nil
        try await super.tearDown()
    }

    /// Create a block and refresh both the view model and the pointer layer's
    /// snapshot of the board, the way a render would.
    @discardableResult
    private func makeBlock(
        _ title: String, col: Int, row: Int, w: Int = 5, h: Int = 3
    ) async throws -> VisionBlock {
        let block = try await service.create(title: title, col: col, row: row, w: w, h: h)
        await viewModel.load()
        view.blocks = viewModel.blocks
        return block
    }

    /// The block's frame as stored, read back from SwiftData rather than from
    /// the view model's in-memory patch. The point of the test is what landed.
    private func stored(_ id: UUID) async throws -> VisionBoardLayout.Slot {
        let block = try await service.list().first { $0.id == id }
        let found = try XCTUnwrap(block)
        return VisionBoardLayout.Slot(col: found.col, row: found.row, w: found.w, h: found.h)
    }

    private func rect(_ block: VisionBlock) -> CGRect {
        CGRect(
            origin: VisionGrid.origin(col: block.col, row: block.row),
            size: VisionGrid.blockSize(columns: block.w, rows: block.h)
        )
    }

    // MARK: - Event synthesis

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        )!
    }

    /// Down, a few samples, up — then wait for the write the release started.
    /// Awaiting the commit rather than sleeping is what keeps this suite from
    /// being the flakiest thing in the repo.
    private func drag(from: CGPoint, to: CGPoint, steps: Int = 4) async {
        view.mouseDown(with: mouse(.leftMouseDown, at: from))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            view.mouseDragged(with: mouse(
                .leftMouseDragged,
                at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            ))
        }
        view.mouseUp(with: mouse(.leftMouseUp, at: to))
        await view.commitTask?.value
    }

    private func grip(of block: VisionBlock) -> CGPoint {
        let grip = VisionHitTest.gripRect(in: rect(block))
        return CGPoint(x: grip.midX, y: grip.midY)
    }

    // MARK: - 1. Move

    func testDraggingTwoCellsRightAndOneDownCommitsThatPosition() async throws {
        let block = try await makeBlock("carry", col: 0, row: 0)
        let start = CGPoint(x: rect(block).midX, y: rect(block).midY)

        await drag(
            from: start,
            to: CGPoint(x: start.x + VisionGrid.cell * 2, y: start.y + VisionGrid.cell)
        )

        let landed = try await stored(block.id)
        XCTAssertEqual(landed, VisionBoardLayout.Slot(col: 2, row: 1, w: 5, h: 3))
        XCTAssertNil(interaction.drag, "the session must be cleared once the write lands")
        XCTAssertFalse(interaction.isManipulating)
    }

    /// The block goes exactly where the pointer put it — no nudge, no nearest
    /// free slot. That reversal is the heart of the interaction: the one object
    /// under your hand used to be the one object that would not obey you.
    func testDraggingOntoANeighbourDisplacesTheNeighbourAndNotTheDraggedBlock() async throws {
        let mover = try await makeBlock("mover", col: 0, row: 0)
        let neighbour = try await makeBlock("neighbour", col: 6, row: 0)
        let start = CGPoint(x: rect(mover).midX, y: rect(mover).midY)

        await drag(from: start, to: CGPoint(x: start.x + VisionGrid.cell * 5, y: start.y))

        let moverFrame = try await stored(mover.id)
        let neighbourFrame = try await stored(neighbour.id)
        XCTAssertEqual(
            moverFrame,
            VisionBoardLayout.Slot(col: 5, row: 0, w: 5, h: 3),
            "exactly where it was dropped"
        )
        XCTAssertEqual(
            neighbourFrame,
            VisionBoardLayout.Slot(col: 6, row: 3, w: 5, h: 3),
            "pushed DOWN, to the mover's bottom edge"
        )
    }

    // MARK: - 2. Resize, one axis at a time

    /// The axes are independent. This is the defect the user reported as
    /// *"I have to grow downward first before I can grow right"*, and the reason
    /// it existed was `VisionBoardLayout.largestFreeSize`, whose third pass was
    /// `while w > minColumns, !free(w, h) { w -= 1 }` — the WIDTH shrunk to
    /// accommodate the HEIGHT. Nothing may reintroduce a cross-axis cap.
    func testResizingWidthOnlyLeavesTheHeightAlone() async throws {
        let block = try await makeBlock("wide", col: 0, row: 0)
        let start = grip(of: block)

        await drag(from: start, to: CGPoint(x: start.x + VisionGrid.cell, y: start.y))

        let landed = try await stored(block.id)
        XCTAssertEqual(landed, VisionBoardLayout.Slot(col: 0, row: 0, w: 6, h: 3))
    }

    func testResizingHeightOnlyLeavesTheWidthAlone() async throws {
        let block = try await makeBlock("tall", col: 0, row: 0)
        let start = grip(of: block)

        await drag(from: start, to: CGPoint(x: start.x, y: start.y + VisionGrid.cell))

        let landed = try await stored(block.id)
        XCTAssertEqual(landed, VisionBoardLayout.Slot(col: 0, row: 0, w: 5, h: 4))
    }

    /// The same claim again, from the other side: a block hemmed in on the right
    /// widens without being grown downward first. That sequence is what the user
    /// had to perform, so it is worth asserting that it is no longer required.
    func testAHemmedInBlockWidensWithNoVerticalTravelAtAll() async throws {
        let block = try await makeBlock("hemmed", col: 0, row: 0)
        try await makeBlock("blocker", col: 6, row: 0)
        let start = grip(of: block)

        await drag(from: start, to: CGPoint(x: start.x + VisionGrid.cell * 2, y: start.y))

        let frame = try await stored(block.id)
        XCTAssertEqual(frame.w, 7)
        XCTAssertEqual(frame.h, 3, "height untouched by a purely horizontal drag")
    }

    // MARK: - 3. The preview is a shadow

    /// *"If I have not released the mouse, that means I have not expanded, I am
    /// just checking. It should show me just the shadow behaviour of how the new
    /// box will move and where it will move rather than actually moving it."*
    ///
    /// So the solver still runs live — the cascade has to be previewable — but
    /// nothing is written and nothing moves until the mouse comes up.
    func testANeighbourStaysPutDuringAResizeAndMovesOnRelease() async throws {
        let block = try await makeBlock("grower", col: 0, row: 0)
        let neighbour = try await makeBlock("neighbour", col: 6, row: 0)
        let before = VisionBoardLayout.Slot(col: 6, row: 0, w: 5, h: 3)
        let start = grip(of: block)

        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: CGPoint(x: start.x + VisionGrid.cell * 2, y: start.y)
        ))

        // Mid-gesture: the destination is known and drawn, and nothing else has
        // moved by a single point.
        XCTAssertEqual(
            interaction.resize?.displaced[neighbour.id],
            VisionBoardLayout.Slot(col: 6, row: 3, w: 5, h: 3),
            "the ghost outline's slot"
        )
        let midGesture = try await stored(neighbour.id)
        XCTAssertEqual(midGesture, before, "not written")
        XCTAssertEqual(
            viewModel.blocks.first { $0.id == neighbour.id }.map {
                VisionBoardLayout.Slot(col: $0.col, row: $0.row, w: $0.w, h: $0.h)
            },
            before,
            "not moved on screen either — `renderOrigin` no longer reads `displaced`"
        )
        let liveNeighbour = try XCTUnwrap(viewModel.blocks.first { $0.id == neighbour.id })
        XCTAssertEqual(
            interaction.renderOrigin(for: liveNeighbour, canvas: canvas),
            VisionGrid.origin(col: 6, row: 0)
        )

        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x + VisionGrid.cell * 2, y: start.y)))
        await view.commitTask?.value

        let settledNeighbour = try await stored(neighbour.id)
        let settledBlock = try await stored(block.id)
        XCTAssertEqual(
            settledNeighbour,
            VisionBoardLayout.Slot(col: 6, row: 3, w: 5, h: 3),
            "and only now does it move"
        )
        XCTAssertEqual(settledBlock.w, 7)
    }

    // MARK: - 4. Cancelling

    func testEscapeMidDragCommitsNothingAndClearsTheSession() async throws {
        let block = try await makeBlock("stay", col: 0, row: 0)
        let start = CGPoint(x: rect(block).midX, y: rect(block).midY)

        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: CGPoint(x: start.x + VisionGrid.cell * 3, y: start.y)
        ))
        XCTAssertNotNil(interaction.drag, "precondition: a drag is in flight")

        view.keyDown(with: key(53))   // Escape

        XCTAssertNil(interaction.drag)
        XCTAssertFalse(interaction.isManipulating)

        // The mouse still comes up afterwards, and must do nothing.
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x + VisionGrid.cell * 3, y: start.y)))
        await view.commitTask?.value

        let unchanged = try await stored(block.id)
        XCTAssertEqual(
            unchanged,
            VisionBoardLayout.Slot(col: 0, row: 0, w: 5, h: 3),
            "cancel needs no undo: displacement is never written, so dropping the session IS the undo"
        )
    }

    // MARK: - 5. The wedge class

    /// A gesture cannot be left open. AppKit delivers `mouseUp` for a
    /// `mouseDown` this view accepted even once the pointer has left it, which
    /// is what retired the `NSEvent` monitor the SwiftUI version needed.
    ///
    /// What is asserted here is this view's half of that contract: it commits
    /// from a `mouseUp` whose location is outside its own bounds, and it does so
    /// even though `hitTest` would refuse a NEW event at that same point.
    /// AppKit's half — that the event is delivered at all — is documented
    /// behaviour and is not reachable without a window.
    func testMouseUpOutsideTheViewStillCommits() async throws {
        let block = try await makeBlock("gone", col: 0, row: 0)
        let start = CGPoint(x: rect(block).midX, y: rect(block).midY)
        let outside = CGPoint(x: canvas.width + 500, y: canvas.height + 500)
        view.blocks = viewModel.blocks

        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(
            .leftMouseDragged, at: CGPoint(x: start.x + VisionGrid.cell * 2, y: start.y + VisionGrid.cell)
        ))
        XCTAssertNil(view.hitTest(outside), "the view would not accept a new event out there")

        view.mouseUp(with: mouse(.leftMouseUp, at: outside))
        await view.commitTask?.value

        let landed = try await stored(block.id)
        XCTAssertEqual(landed, VisionBoardLayout.Slot(col: 2, row: 1, w: 5, h: 3))
        XCTAssertFalse(interaction.isManipulating)
    }

    // MARK: - 6. Pass-through

    /// A checkbox click must reach SwiftUI. Two halves: `hitTest` makes the
    /// layer transparent, and the handler starts nothing even when called
    /// directly, so a future change to the layering cannot quietly turn a tick
    /// into a drag.
    func testAMouseDownOnAnExcludedChildStartsNoSession() async throws {
        let block = try await makeBlock("tiles", col: 0, row: 0)
        let tile = CGRect(x: rect(block).minX + 12, y: rect(block).minY + 70, width: 304, height: 26)
        view.exclusions = [tile]
        let inside = CGPoint(x: tile.midX, y: tile.midY)

        XCTAssertNil(view.hitTest(inside), "transparent over SwiftUI's own control")

        view.mouseDown(with: mouse(.leftMouseDown, at: inside))

        XCTAssertNil(interaction.drag)
        XCTAssertNil(interaction.resize)
        XCTAssertNil(interaction.selected, "and it does not steal the selection either")
    }

    // MARK: - 7. Canvas clicks and selection

    func testASingleClickOnEmptyCanvasAsksToCreateAtThatCell() async throws {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 68 * 7 + 20, y: 68 * 4 + 20)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 68 * 7 + 20, y: 68 * 4 + 20)))

        XCTAssertEqual(createdCells.count, 1)
        XCTAssertEqual(createdCells.first?.col, 7)
        XCTAssertEqual(createdCells.first?.row, 4)
    }

    /// One interaction, at most one block. A double click arrives as two
    /// separate `mouseDown`s and creation is async, so the second sees a board
    /// that does not yet hold what the first made.
    func testADoubleClickCreatesOnlyOneBlock() async throws {
        let point = CGPoint(x: 68 * 7 + 20, y: 68 * 4 + 20)

        view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 1))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 1))
        view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))

        XCTAssertEqual(createdCells.count, 1)
    }

    /// Where a block does not fit, the click means what it always meant. That
    /// absence is the only place a canvas click deselects, and the ghost is
    /// absent in exactly the same places, so what you see is what the click
    /// does.
    func testAClickWhereNoBlockFitsDeselectsInsteadOfCreating() async throws {
        let block = try await makeBlock("occupier", col: 0, row: 0)
        interaction.selected = block.id

        // In the 12pt gutter past the block's trailing edge, which is canvas
        // but still inside the block's LAST column — so a 5 × 3 block created
        // here would run straight through it.
        let point = CGPoint(x: 334, y: 30)
        XCTAssertEqual(
            VisionHitTest.resolve(
                point: point,
                blocks: viewModel.blocks.map(VisionHitTest.Frame.init),
                exclusions: []
            ),
            .canvas(col: 4, row: 0),
            "precondition: this point is canvas, not the block"
        )

        view.mouseDown(with: mouse(.leftMouseDown, at: point))
        view.mouseUp(with: mouse(.leftMouseUp, at: point))

        XCTAssertTrue(createdCells.isEmpty)
        XCTAssertNil(interaction.selected)
    }

    func testClickingABlockSelectsIt() async throws {
        let block = try await makeBlock("pick me", col: 0, row: 0)
        let point = CGPoint(x: rect(block).midX, y: rect(block).midY)

        view.mouseDown(with: mouse(.leftMouseDown, at: point))
        view.mouseUp(with: mouse(.leftMouseUp, at: point))
        await view.commitTask?.value

        let unmoved = try await stored(block.id)
        XCTAssertEqual(interaction.selected, block.id)
        XCTAssertEqual(
            unmoved,
            VisionBoardLayout.Slot(col: 0, row: 0, w: 5, h: 3),
            "a stationary click moves nothing"
        )
    }

    // MARK: - 7b. Dismissing a popover

    /// Reported 2026-08-07: *"when I click on the outer surface below Add item,
    /// it still doesn't go away."*
    ///
    /// `NSPopover`'s `.semitransient` dismissal did not fire for a click on this
    /// canvas — the pointer layer answers those clicks itself — so the overflow
    /// list sat over a board the user had already started dragging. The board's
    /// one popover is now state this layer owns, which is what makes the rule
    /// assertable here rather than by clicking.
    func testClickingABlockClosesAnOpenPopover() async throws {
        let block = try await makeBlock("overflowing", col: 0, row: 0)
        interaction.popover = .overflow(block.id)

        view.mouseDown(with: mouse(
            .leftMouseDown, at: CGPoint(x: rect(block).midX, y: rect(block).midY)
        ))

        XCTAssertNil(interaction.popover)
    }

    /// Empty canvas too. The click the user described was on a block, but a
    /// popover that survives a click anywhere on the board is the same defect.
    func testClickingEmptyCanvasClosesAnOpenPopover() async throws {
        let block = try await makeBlock("overflowing", col: 0, row: 0)
        interaction.popover = .overflow(block.id)

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 68 * 9 + 20, y: 68 * 6 + 20)))

        XCTAssertNil(interaction.popover)
    }

    /// The grip as well, so grabbing a corner to resize does not leave a popover
    /// floating over the block that is changing size under it.
    func testGrabbingTheGripClosesAnOpenPopover() async throws {
        let block = try await makeBlock("overflowing", col: 0, row: 0)
        interaction.popover = .overflow(block.id)

        view.mouseDown(with: mouse(.leftMouseDown, at: grip(of: block)))

        XCTAssertNil(interaction.popover)
    }

    /// But NOT a click on a pass-through control. That is where the `+N more`
    /// button itself lives: dismissing on its own click would close the popover
    /// in the same event that opened it, and it is also where an already-open
    /// popover's trigger sits while you are aiming at it.
    func testAClickOnAPassThroughControlLeavesThePopoverAlone() async throws {
        let block = try await makeBlock("overflowing", col: 0, row: 0)
        let more = CGRect(x: rect(block).minX + 12, y: rect(block).minY + 96, width: 60, height: 14)
        view.exclusions = [more]
        interaction.popover = .overflow(block.id)

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: more.midX, y: more.midY)))

        XCTAssertEqual(interaction.popover, .overflow(block.id))
    }

    /// A right click is a click. It selects a block, and a popover left hanging
    /// over the context menu it summons is the same wrongness as before.
    func testRightClickingTheBoardClosesAnOpenPopover() async throws {
        let block = try await makeBlock("overflowing", col: 0, row: 0)
        interaction.popover = .attach(block.id)

        view.rightMouseDown(with: mouse(
            .rightMouseDown, at: CGPoint(x: rect(block).midX, y: rect(block).midY)
        ))

        XCTAssertNil(interaction.popover)
    }

    // MARK: - 7c. Hover while a menu is open

    /// Reported 2026-08-07: *"the three dots disappear when I click on it."*
    ///
    /// The ellipsis is revealed on block hover, and opening its menu moves the
    /// pointer onto the menu's own window — so the tracking area reports
    /// `mouseExited`, hover clears, and the control vanishes from under the
    /// pointer that just pressed it. The menu is left floating with nothing on
    /// screen to say where it came from.
    ///
    /// A menu owns the pointer the same way a drag does, so hover freezes for
    /// exactly as long as it is up.
    func testAnOpenMenuKeepsTheBlockHovered() async throws {
        let block = try await makeBlock("hovered", col: 0, row: 0)
        view.mouseMoved(with: mouse(
            .mouseMoved, at: CGPoint(x: rect(block).midX, y: rect(block).midY)
        ))
        XCTAssertEqual(interaction.hoveredBlock, block.id)

        interaction.menuTracking = true
        // A move-typed event on purpose: `NSEvent.mouseEvent` returns nil for
        // `.mouseExited` (it wants `enterExitEvent`, which needs a real tracking
        // area), and `mouseExited(with:)` never reads the event anyway.
        view.mouseExited(with: mouse(.mouseMoved, at: .zero))

        XCTAssertEqual(interaction.hoveredBlock, block.id, "the ellipsis must stay visible under its own menu")
    }

    /// And a move onto another block while the menu is up must not re-point the
    /// hover either: the menu belongs to the block it was opened on.
    func testAMoveWhileTheMenuIsOpenDoesNotChangeWhatIsHovered() async throws {
        let block = try await makeBlock("hovered", col: 0, row: 0)
        let other = try await makeBlock("elsewhere", col: 6, row: 0)
        view.mouseMoved(with: mouse(
            .mouseMoved, at: CGPoint(x: rect(block).midX, y: rect(block).midY)
        ))

        interaction.menuTracking = true
        view.mouseMoved(with: mouse(
            .mouseMoved, at: CGPoint(x: rect(other).midX, y: rect(other).midY)
        ))

        XCTAssertEqual(interaction.hoveredBlock, block.id)
    }

    /// The freeze is for the menu's lifetime and not a moment longer, or the
    /// board would be stuck reporting a hover that has nothing to do with where
    /// the pointer is.
    func testHoverResumesOnceTheMenuHasClosed() async throws {
        let block = try await makeBlock("hovered", col: 0, row: 0)
        view.mouseMoved(with: mouse(
            .mouseMoved, at: CGPoint(x: rect(block).midX, y: rect(block).midY)
        ))
        interaction.menuTracking = true

        interaction.menuTracking = false
        view.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 68 * 9 + 20, y: 68 * 6 + 20)))

        XCTAssertNil(interaction.hoveredBlock)
    }

    // MARK: - 8. Keyboard parity

    /// Arrows and ⌥-arrows are the accessible equivalent of the drag and the
    /// grip. They moved off the card's `.focusable()` — the prime suspect for
    /// having eaten the block's mouse-down — and onto this view's `keyDown`, so
    /// they need asserting in their new home.
    func testArrowKeysMoveTheSelectedBlock() async throws {
        let block = try await makeBlock("keys", col: 1, row: 1)
        interaction.selected = block.id
        var moved: [(UUID, Int, Int)] = []
        view.onNudge = { id, dCol, dRow in moved.append((id, dCol, dRow)) }

        view.keyDown(with: key(124))   // right
        view.keyDown(with: key(125))   // down

        XCTAssertEqual(moved.count, 2)
        XCTAssertEqual(moved.first?.1, 1)
        XCTAssertEqual(moved.first?.2, 0)
        XCTAssertEqual(moved.last?.1, 0)
        XCTAssertEqual(moved.last?.2, 1)
    }

    func testOptionArrowsResizeOnOneAxisEach() async throws {
        let block = try await makeBlock("keys", col: 1, row: 1)
        interaction.selected = block.id
        var resized: [(UUID, Int, Int)] = []
        view.onResizeBy = { id, dW, dH in resized.append((id, dW, dH)) }

        view.keyDown(with: key(124, flags: .option))   // ⌥→
        view.keyDown(with: key(125, flags: .option))   // ⌥↓

        XCTAssertEqual(resized.map(\.1), [1, 0], "width delta")
        XCTAssertEqual(resized.map(\.2), [0, 1], "height delta")
    }

    func testTabWalksTheBoardInReadingOrder() async throws {
        let first = try await makeBlock("first", col: 0, row: 0)
        let second = try await makeBlock("second", col: 6, row: 0)
        let third = try await makeBlock("third", col: 0, row: 4)

        view.keyDown(with: key(48))
        XCTAssertEqual(interaction.selected, first.id)
        view.keyDown(with: key(48))
        XCTAssertEqual(interaction.selected, second.id)
        view.keyDown(with: key(48))
        XCTAssertEqual(interaction.selected, third.id)
        view.keyDown(with: key(48, flags: .shift))
        XCTAssertEqual(interaction.selected, second.id)
    }
}
