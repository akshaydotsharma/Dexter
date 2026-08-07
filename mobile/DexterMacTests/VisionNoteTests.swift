import XCTest
@testable import DexterMac

/// A block's own line items, end to end through the store (#446).
///
/// Notes are the half of a block's contents that exists nowhere else. A task
/// wrongly dropped from a block is annoying and recoverable — it is still in
/// Tasks. A note wrongly dropped is gone, with no other surface to find it on.
/// So the write path gets asserted against a real `SwiftDataStore` rather than
/// reasoned about: the JSON blob round-trips, the id survives, and the two rules
/// with any subtlety in them (empty text deletes; a nil column reads as empty)
/// are named tests.
///
/// macOS-hosted alongside `VisionPointerViewTests`, and for the same reason: the
/// vision board is not built for iOS yet, so the iOS suite has no host for a
/// store-level test of it.
@MainActor
final class VisionNoteTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: VisionBoardService!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = VisionBoardService(store: store)
    }

    override func tearDown() async throws {
        service = nil
        store = nil
        try await super.tearDown()
    }

    private func makeBlock() async throws -> VisionBlock {
        try await service.create(title: "Renovate the kitchen", col: 0, row: 0)
    }

    /// Read the block back from the store rather than trusting the value the
    /// write returned. The blob is the thing under test, and a returned DTO
    /// built in memory would pass even if nothing were persisted.
    private func reload(_ id: UUID) async throws -> VisionBlock {
        let blocks = try await service.list()
        return try XCTUnwrap(blocks.first { $0.id == id })
    }

    // MARK: - Round trip

    func testANoteSurvivesTheStore() async throws {
        let block = try await makeBlock()
        _ = try await service.addNote(to: block.id, text: "Budget is 20k")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["Budget is 20k"])
    }

    func testNotesKeepTheOrderTheyWereAddedIn() async throws {
        let block = try await makeBlock()
        for text in ["First", "Second", "Third"] {
            _ = try await service.addNote(to: block.id, text: text)
        }

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["First", "Second", "Third"])
    }

    /// The id is what the card uses to put a caret in the note that was just
    /// made. If it did not survive the write, a new note would open blank and
    /// the typing would land nowhere.
    func testTheReturnedNoteIdIsTheOneThatWasStored() async throws {
        let block = try await makeBlock()
        let made = try await service.addNote(to: block.id, text: "Call the contractor")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.id), [made.note.id])
    }

    /// A block with no notes reads as an empty array, not as a crash and not as
    /// a decode failure. This is also the shape every row written before the
    /// column existed has.
    func testABlockWithNoNotesReadsAsEmpty() async throws {
        let block = try await makeBlock()
        XCTAssertEqual(block.notes, [])
        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes, [])
    }

    // MARK: - Editing

    func testEditingANoteChangesOnlyThatNote() async throws {
        let block = try await makeBlock()
        _ = try await service.addNote(to: block.id, text: "First")
        let target = try await service.addNote(to: block.id, text: "Second")
        _ = try await service.addNote(to: block.id, text: "Third")

        _ = try await service.setNoteText(target.note.id, in: block.id, to: "Second, edited")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["First", "Second, edited", "Third"])
    }

    func testEditingANoteKeepsItsPosition() async throws {
        let block = try await makeBlock()
        let first = try await service.addNote(to: block.id, text: "First")
        _ = try await service.addNote(to: block.id, text: "Second")

        _ = try await service.setNoteText(first.note.id, in: block.id, to: "Still first")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.first?.text, "Still first")
        XCTAssertEqual(reloaded.notes.first?.id, first.note.id)
    }

    /// The blank-note flow: "Add note" makes an empty one and opens it in edit.
    /// Clicking away commits empty text, and that has to leave the block exactly
    /// as it was rather than accumulating blank rows.
    func testCommittingEmptyTextDeletesTheNote() async throws {
        let block = try await makeBlock()
        let made = try await service.addNote(to: block.id)
        let before = try await reload(block.id)
        XCTAssertEqual(before.notes.count, 1, "precondition")

        _ = try await service.setNoteText(made.note.id, in: block.id, to: "")

        let after = try await reload(block.id)
        XCTAssertEqual(after.notes, [])
    }

    func testWhitespaceOnlyTextCountsAsEmpty() async throws {
        let block = try await makeBlock()
        let made = try await service.addNote(to: block.id, text: "Something")

        _ = try await service.setNoteText(made.note.id, in: block.id, to: "   \n  ")

        let after = try await reload(block.id)
        XCTAssertEqual(after.notes, [])
    }

    func testTextIsTrimmedOnTheWayIn() async throws {
        let block = try await makeBlock()
        _ = try await service.addNote(to: block.id, text: "  Padded  ")
        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["Padded"])
    }

    /// A note edited from the overflow popover while the card has been rebuilt
    /// underneath it. Nothing should be created, and nothing else disturbed.
    func testEditingANoteThatIsNoLongerThereIsANoOp() async throws {
        let block = try await makeBlock()
        _ = try await service.addNote(to: block.id, text: "Survivor")

        _ = try await service.setNoteText(UUID(), in: block.id, to: "Ghost")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["Survivor"])
    }

    // MARK: - Deleting

    func testDeletingANoteLeavesTheOthers() async throws {
        let block = try await makeBlock()
        _ = try await service.addNote(to: block.id, text: "Keep")
        let doomed = try await service.addNote(to: block.id, text: "Drop")
        _ = try await service.addNote(to: block.id, text: "Keep too")

        _ = try await service.deleteNote(doomed.note.id, from: block.id)

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.notes.map(\.text), ["Keep", "Keep too"])
    }

    // MARK: - Independence from tasks

    /// The load-bearing claim of the whole feature: a note is not a task. It
    /// must not appear in Tasks, and it must not touch the block's membership.
    func testAddingANoteCreatesNoTaskAndTouchesNoMembership() async throws {
        let todos = TodoService(store: store)
        let block = try await makeBlock()
        let task = try await todos.create(
            TodoCreateRequest(title: "Get three quotes", description: nil, dueDate: nil, tag: nil)
        )
        _ = try await service.attach(taskID: task.id, to: block.id)

        _ = try await service.addNote(to: block.id, text: "Budget is 20k")

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.members, [task.id], "membership is untouched")
        XCTAssertEqual(reloaded.notes.map(\.text), ["Budget is 20k"])
        let allTasks = try await todos.list()
        XCTAssertEqual(
            allTasks.map(\.title), ["Get three quotes"],
            "a note is not a task and must not appear in Tasks"
        )
    }

    /// Notes and members share one row and one JSON codec path each. A write to
    /// either must not clear the other — the failure mode that would look like a
    /// block spontaneously losing its tasks.
    func testDeletingANoteDoesNotDropTheBlocksTasks() async throws {
        let todos = TodoService(store: store)
        let block = try await makeBlock()
        let task = try await todos.create(
            TodoCreateRequest(title: "Get three quotes", description: nil, dueDate: nil, tag: nil)
        )
        _ = try await service.attach(taskID: task.id, to: block.id)
        let note = try await service.addNote(to: block.id, text: "Budget is 20k")

        _ = try await service.deleteNote(note.note.id, from: block.id)

        let reloaded = try await reload(block.id)
        XCTAssertEqual(reloaded.members, [task.id])
        XCTAssertEqual(reloaded.notes, [])
    }

    // MARK: - View model

    /// The card asks the view model for the new note's id and puts a caret in
    /// it. A nil here is a note the user cannot type into.
    func testTheViewModelHandsBackTheNewNotesId() async throws {
        let viewModel = VisionBoardViewModel(board: service, todos: TodoService(store: store))
        let block = try await makeBlock()
        await viewModel.load()

        let id = await viewModel.addNote(to: block.id)

        let noteID = try XCTUnwrap(id)
        let held = try XCTUnwrap(viewModel.blocks.first { $0.id == block.id })
        XCTAssertEqual(held.notes.map(\.id), [noteID], "the local copy carries the note too")
    }

    /// `apply` used to patch the local array only when it found the block. The
    /// note writes go through the same path, so the board must not need a reload
    /// to show a note that was just added.
    func testTheLocalCopyUpdatesWithoutAReload() async throws {
        let viewModel = VisionBoardViewModel(board: service, todos: TodoService(store: store))
        let block = try await makeBlock()
        await viewModel.load()

        let added = await viewModel.addNote(to: block.id, text: "Typed")
        let id = try XCTUnwrap(added)
        await viewModel.setNoteText(id, in: block.id, to: "Typed and edited")

        let held = try XCTUnwrap(viewModel.blocks.first { $0.id == block.id })
        XCTAssertEqual(held.notes.map(\.text), ["Typed and edited"])
    }
}
