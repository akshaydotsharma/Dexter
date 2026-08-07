import XCTest
@testable import DexterMac

/// Editing items on a block, stated as the experience it is meant to be (#446).
///
/// Written after a bug that only a person could find: adding a SECOND item left
/// the new row uneditable, because the outgoing field tore down after the new
/// item had taken the caret and its teardown commit cleared a caret it did not
/// own. Nothing in the suite could have caught it, because the rules lived in a
/// view's `@State` where the only way to run them is to click.
///
/// So these tests are the specification, not a description of the code. Each one
/// names a thing the person doing it expects, and the sequence of calls is the
/// sequence the views actually produce — including the two orderings AppKit can
/// deliver a blur in, which is where the bug lived.
///
/// The whole point of `VisionItemEditor` existing is that this file can be
/// written at all.
@MainActor
final class VisionItemEditorTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: VisionBoardService!
    private var viewModel: VisionBoardViewModel!
    private var editor: VisionItemEditor!
    private var blockID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = VisionBoardService(store: store)
        viewModel = VisionBoardViewModel(board: service, todos: TodoService(store: store))
        editor = VisionItemEditor(viewModel: viewModel)
        blockID = try await service.create(title: "Renovate the kitchen", col: 0, row: 0).id
        await viewModel.load()
    }

    override func tearDown() async throws {
        blockID = nil
        editor = nil
        viewModel = nil
        service = nil
        store = nil
        try await super.tearDown()
    }

    /// What the block currently says, in display order.
    private func texts() throws -> [String] {
        let block = try XCTUnwrap(viewModel.blocks.first { $0.id == blockID })
        return block.items.map(\.text)
    }

    /// The caret, or nil.
    private var caret: UUID? { editor.editingID }

    // MARK: - Making one

    /// Click `+`. A blank row appears and the caret is already in it, so the
    /// next thing you do is type.
    func testAddingAnItemPutsTheCaretInIt() async throws {
        await editor.addItem(to: blockID)

        XCTAssertEqual(try texts(), [""])
        XCTAssertNotNil(caret)
        XCTAssertEqual(caret, try XCTUnwrap(viewModel.blocks.first { $0.id == blockID }).items.first?.id)
    }

    /// Type, click away. The text is saved and the caret is gone.
    func testTypingThenClickingAwaySavesIt() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)

        await editor.commit(id, in: blockID, text: "Get three quotes")

        XCTAssertEqual(try texts(), ["Get three quotes"])
        XCTAssertNil(caret)
    }

    /// Click `+`, then click away without typing. Nothing is left behind — a
    /// blank row you never filled in is not something you meant to keep.
    func testAddingThenAbandoningLeavesNothingBehind() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)

        await editor.commit(id, in: blockID, text: "")

        XCTAssertEqual(try texts(), [])
        XCTAssertNil(caret)
    }

    /// `+` is a big target and gets clicked twice. The second click makes a
    /// second row and moves the caret, which tears down the first row's field,
    /// which reports empty text — so the blank it abandoned removes itself and
    /// you are left with one row, not one row and an orphan.
    ///
    /// This replaced a test of an explicit in-flight guard. The guard wrapped an
    /// `await` that does not reliably suspend on the main actor, so it fired
    /// sometimes and not others; the ordinary commit path already gets this
    /// right, deterministically, which is what this asserts.
    func testASecondAddRemovesTheBlankRowItAbandoned() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)
        await editor.addItem(to: blockID)
        let second = try XCTUnwrap(caret)

        // The abandoned row's field notices it is going away and reports empty.
        await editor.commit(first, in: blockID, text: "")

        XCTAssertEqual(try texts(), [""], "one blank row left, the one with the caret")
        XCTAssertEqual(caret, second)
    }

    // MARK: - Making a second one

    /// THE BUG. Add an item, type into it, then click `+` again.
    ///
    /// A SwiftUI `Button` does not take first responder on macOS, so the first
    /// field is still focused through the click and only tears down once the
    /// re-render replaces it — AFTER the new item has taken the caret. Its
    /// teardown commit then arrives for a row the caret has already left.
    ///
    /// It must save the first item's text and leave the caret exactly where the
    /// add put it. Before the fix this cleared the caret, and the second item
    /// was uneditable: clicking it did nothing, and it kept the placeholder.
    func testASecondItemKeepsTheCaretWhenTheFirstFieldTearsDownLate() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)

        // The click on `+` lands while the first field is still focused.
        await editor.addItem(to: blockID)
        let second = try XCTUnwrap(caret)
        XCTAssertNotEqual(first, second, "precondition: a new row was made")

        // Only now does the old field notice it is going away.
        await editor.commit(first, in: blockID, text: "Get three quotes")

        XCTAssertEqual(caret, second, "the caret belongs to the row the add put it in")
        XCTAssertEqual(try texts(), ["Get three quotes", ""])
    }

    /// The other ordering AppKit can produce: the field resigns before the
    /// button's action runs. Same outcome, which is the point — a race that
    /// resolves differently depending on ordering is not fixed, it is hidden.
    func testTheSameSequenceWorksWhenTheFieldResignsFirst() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)

        await editor.commit(first, in: blockID, text: "Get three quotes")
        await editor.addItem(to: blockID)
        let second = try XCTUnwrap(caret)

        XCTAssertEqual(caret, second)
        XCTAssertEqual(try texts(), ["Get three quotes", ""])
    }

    /// Three in a row. The failure was not specific to the second one; it was
    /// specific to there being a field open when the next add landed.
    func testAddingThreeInARowLeavesTheCaretOnTheThird() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)
        await editor.addItem(to: blockID)
        let second = try XCTUnwrap(caret)
        await editor.commit(first, in: blockID, text: "One")
        await editor.addItem(to: blockID)
        let third = try XCTUnwrap(caret)
        await editor.commit(second, in: blockID, text: "Two")

        XCTAssertEqual(caret, third)
        XCTAssertEqual(try texts(), ["One", "Two", ""])
    }

    // MARK: - Moving between items

    /// Click item B's text while item A is being edited. B gets the caret, and
    /// A's late teardown commit saves A without stealing it back.
    func testClickingAnotherItemMovesTheCaretAndStillSavesTheOldOne() async throws {
        await editor.addItem(to: blockID)
        let a = try XCTUnwrap(caret)
        await editor.commit(a, in: blockID, text: "First")
        await editor.addItem(to: blockID)
        let b = try XCTUnwrap(caret)
        await editor.commit(b, in: blockID, text: "Second")

        editor.begin(a)
        editor.begin(b)                                    // clicked B while A was open
        await editor.commit(a, in: blockID, text: "First, edited")   // A's late blur

        XCTAssertEqual(caret, b)
        XCTAssertEqual(try texts(), ["First, edited", "Second"])
    }

    /// Clicking an existing item's text puts the caret in it. The obvious case,
    /// asserted because it is the one the user reported as broken.
    func testClickingAnItemStartsAnEdit() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)
        await editor.commit(id, in: blockID, text: "Get three quotes")
        XCTAssertNil(caret, "precondition")

        editor.begin(id)

        XCTAssertEqual(caret, id)
    }

    // MARK: - Return

    /// Return saves the line and opens the next one, so a list can be typed
    /// without reaching for the mouse between lines.
    func testReturnSavesAndOpensTheNextItem() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)

        await editor.commit(first, in: blockID, text: "Get three quotes", continuing: true)

        XCTAssertEqual(try texts(), ["Get three quotes", ""])
        let second = try XCTUnwrap(caret)
        XCTAssertNotEqual(second, first, "the caret moved to the new row")
    }

    /// Return on a blank row ends the run: no new item, no blank left behind.
    /// That is how you stop typing a list.
    func testReturnOnABlankRowEndsTheRun() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)
        await editor.commit(first, in: blockID, text: "Get three quotes", continuing: true)
        let second = try XCTUnwrap(caret)

        await editor.commit(second, in: blockID, text: "", continuing: true)

        XCTAssertEqual(try texts(), ["Get three quotes"])
        XCTAssertNil(caret)
    }

    /// A late blur from an abandoned row must not chain a new item onto the
    /// block, however it is reported. Only the row holding the caret may
    /// continue the run.
    func testALateBlurCannotOpenANewItem() async throws {
        await editor.addItem(to: blockID)
        let first = try XCTUnwrap(caret)
        await editor.addItem(to: blockID)
        let second = try XCTUnwrap(caret)

        await editor.commit(first, in: blockID, text: "First", continuing: true)

        XCTAssertEqual(caret, second)
        XCTAssertEqual(try texts(), ["First", ""], "no third row was chained on")
    }

    // MARK: - Escape

    /// Escape on a just-created row undoes the creation.
    func testEscapeOnANewBlankItemRemovesIt() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)

        await editor.cancel(id, in: blockID)

        XCTAssertEqual(try texts(), [])
        XCTAssertNil(caret)
    }

    /// Escape on an item that already has text leaves that text alone. The field
    /// throws away its own edit; there is nothing to roll back here.
    func testEscapeOnAnExistingItemKeepsIt() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)
        await editor.commit(id, in: blockID, text: "Get three quotes")
        editor.begin(id)

        await editor.cancel(id, in: blockID)

        XCTAssertEqual(try texts(), ["Get three quotes"])
        XCTAssertNil(caret)
    }

    // MARK: - Editing text

    /// Clearing an item's text removes it. Emptying something is the obvious way
    /// to ask for it to go, and reverting instead would leave you holding a row
    /// you had already told the interface to drop.
    func testClearingAnItemsTextRemovesIt() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)
        await editor.commit(id, in: blockID, text: "Get three quotes")
        editor.begin(id)

        await editor.commit(id, in: blockID, text: "   ")

        XCTAssertEqual(try texts(), [])
    }

    /// Clicking into an item and clicking straight back out writes nothing, so
    /// the block does not look edited when it was only looked at.
    func testAnUnchangedEditWritesNothing() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)
        await editor.commit(id, in: blockID, text: "Get three quotes")
        let before = try XCTUnwrap(viewModel.blocks.first { $0.id == blockID }).updatedAt

        editor.begin(id)
        await editor.commit(id, in: blockID, text: "Get three quotes")

        let after = try XCTUnwrap(viewModel.blocks.first { $0.id == blockID }).updatedAt
        XCTAssertEqual(before, after)
    }

    /// A commit for a row that has since been removed does not resurrect it. The
    /// popover and the card can both hold a reference to the same item, so this
    /// is reachable by removing from one while the other has it open.
    func testCommittingAnItemThatIsGoneDoesNotBringItBack() async throws {
        await editor.addItem(to: blockID)
        let id = try XCTUnwrap(caret)
        await editor.commit(id, in: blockID, text: "Get three quotes")
        await viewModel.deleteItem(id, from: blockID)

        await editor.commit(id, in: blockID, text: "Typed after removal")

        XCTAssertEqual(try texts(), [])
    }
}
