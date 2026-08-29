import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// Two item rows, a real editor and a real store, driven the way a click drives
/// them (#492).
///
/// Hosts the actual rows, types into the actual field editor, and asserts on
/// what landed in the store: the end of the chain the reported defect broke —
/// *"if I'm editing an item and I click on another item, the change does not get
/// saved."*
///
/// **Honest limit.** This does not reproduce that defect. It passes against the
/// code that had it, because the missing piece is a real click: the caret is
/// released here by calling `begin` directly, and an `NSHostingView` in a test
/// window still resigns its field when the row stops rendering one. In the app
/// the release is triggered by a click on a SwiftUI row, which takes no focus and
/// resigns nothing, so the field kept the caret and the typed text went with the
/// view. `VisionItemEditorTests` asserts the fix where it can be seen — the field
/// is asked to commit BEFORE the caret is cleared. What this file is for is the
/// other direction: locking in the end-to-end outcome, so a future change to the
/// editor, the row or the field that quietly stops saving fails here.
@MainActor
final class VisionItemClickAwayTests: XCTestCase {

    private var window: NSWindow!
    private var store: SwiftDataStore!
    private var service: VisionBoardService!
    private var viewModel: VisionBoardViewModel!
    private var editor: VisionItemEditor!
    private var blockID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = VisionBoardService(store: store)
        viewModel = VisionBoardViewModel(board: service, todos: TodoService(store: store))
        editor = VisionItemEditor(viewModel: viewModel)
        blockID = try await service.create(title: "Renovate the kitchen", col: 0, row: 0).id
        await viewModel.load()
    }

    override func tearDown() async throws {
        window = nil
        blockID = nil
        editor = nil
        viewModel = nil
        service = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Harness

    /// The two rows, rendered from the editor exactly as `VisionBlockCard`
    /// renders them: one field at most, mounted for whichever item the editor
    /// says holds the caret.
    private struct Rows: View {
        let editor: VisionItemEditor
        let viewModel: VisionBoardViewModel
        let blockID: UUID

        var body: some View {
            VStack(spacing: 2) {
                ForEach(items, id: \.id) { item in
                    VisionTileRow(
                        row: .item(item),
                        showsDue: false,
                        isEditing: editor.editingID(in: .card) == item.id,
                        onToggle: {},
                        onBeginEdit: { editor.begin(item.id, in: .card) },
                        onCommit: { text, continuing in
                            Task {
                                await editor.commit(
                                    item.id, in: blockID, text: text,
                                    continuing: continuing, surface: .card
                                )
                            }
                        },
                        onCancel: { Task { await editor.cancel(item.id, in: blockID) } },
                        onRemoveFromBoard: nil,
                        onRemove: {}
                    )
                }
            }
        }

        private var items: [VisionItem] {
            viewModel.blocks.first { $0.id == blockID }?.items ?? []
        }
    }

    private func host() -> NSHostingView<Rows> {
        let view = NSHostingView(
            rootView: Rows(editor: editor, viewModel: viewModel, blockID: blockID)
        )
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        window.contentView = view
        return view
    }

    private func settle(_ turns: Int = 14) async {
        for _ in 0..<turns {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func fields(in view: NSView) -> [ClearBackgroundTextField] {
        if let found = view as? ClearBackgroundTextField { return [found] }
        return view.subviews.flatMap { fields(in: $0) }
    }

    private func texts() throws -> [String] {
        let block = try XCTUnwrap(viewModel.blocks.first { $0.id == blockID })
        return block.items.map(\.text)
    }

    // MARK: - The reported defect

    /// Type into a new item, then click another item's text. What was typed is
    /// saved.
    func testTypingThenClickingAnotherItemSavesWhatWasTyped() async throws {
        // An existing item to click on, and a blank one in edit — the state
        // `+ Add item` leaves behind.
        _ = try await service.addItem(to: blockID, text: "Existing")
        await viewModel.load()
        let view = host()
        await editor.addItem(to: blockID)
        await settle()

        let field = try XCTUnwrap(fields(in: view).first, "one field, on the row being edited")
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        fieldEditor.insertText("Tile samples", replacementRange: NSRange(location: 0, length: 0))

        // The click on the other row's text. Its tap calls `begin`.
        let other = try XCTUnwrap(viewModel.blocks.first { $0.id == blockID }?.items.first { $0.text == "Existing" })
        editor.begin(other.id, in: .card)
        await settle()

        XCTAssertEqual(try texts().sorted(), ["Existing", "Tile samples"])
    }
}
