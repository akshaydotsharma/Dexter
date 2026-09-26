import XCTest
@testable import DexterMac

/// Archive and unarchive on the vision board (#671), through a real store.
///
/// An archived block has to leave the board without losing anything on it, and
/// come back without landing on top of a block that took its place.
@MainActor
final class VisionArchiveTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: VisionBoardService!
    private var viewModel: VisionBoardViewModel!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = VisionBoardService(store: store)
        viewModel = VisionBoardViewModel(board: service, todos: TodoService(store: store))
    }

    override func tearDown() async throws {
        viewModel = nil
        service = nil
        store = nil
        try await super.tearDown()
    }

    func testArchiveTakesTheBlockOffTheBoardAndIntoTheArchive() async throws {
        let block = try await service.create(title: "Kitchen", col: 0, row: 0)
        await viewModel.load()

        await viewModel.archiveBlock(block.id)

        XCTAssertTrue(viewModel.blocks.isEmpty)
        XCTAssertEqual(viewModel.archivedBlocks.map(\.id), [block.id])
        let live = try await service.list()
        XCTAssertTrue(live.isEmpty, "the store must agree with the view model")
    }

    func testUnarchiveKeepsEverythingOnTheBlock() async throws {
        let block = try await service.create(title: "Kitchen", col: 2, row: 3, state: .active)
        _ = try await service.addItem(to: block.id, text: "Budget is 20k")
        await viewModel.load()

        await viewModel.archiveBlock(block.id)
        await viewModel.unarchiveBlock(block.id)

        XCTAssertTrue(viewModel.archivedBlocks.isEmpty)
        let blocks = try await service.list()
        let restored = try XCTUnwrap(blocks.first)
        XCTAssertEqual(restored.title, "Kitchen")
        XCTAssertEqual(restored.state, .active)
        XCTAssertEqual(restored.items.map(\.text), ["Budget is 20k"])
        XCTAssertEqual([restored.col, restored.row], [2, 3], "an empty spot takes it back as it was")
    }

    func testUnarchiveNeverLandsOnABlockThatTookItsPlace() async throws {
        let archived = try await service.create(title: "Old", col: 0, row: 0)
        await viewModel.load()
        await viewModel.archiveBlock(archived.id)

        let squatter = try await service.create(title: "New", col: 0, row: 0)
        await viewModel.load()
        await viewModel.unarchiveBlock(archived.id)

        let blocks = try await service.list()
        let old = try XCTUnwrap(blocks.first { $0.id == archived.id })
        let new = try XCTUnwrap(blocks.first { $0.id == squatter.id })
        let a = VisionBoardLayout.Slot(col: old.col, row: old.row, w: old.w, h: old.h)
        XCTAssertTrue(
            VisionBoardLayout.isFree(a, in: [new], excluding: nil),
            "unarchived block overlaps the one that took its spot"
        )
    }
}
