import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// Return in an item's field must LOG what was typed (#453).
///
/// Reported: *"when i write the text in the sub item and press enter, it does
/// not identify it as a signal to log my input and clears the text and i need
/// to write again."*
///
/// The row is hosted in a real window, the field is typed into the way AppKit
/// types into it (through the field editor, which is the only writer the
/// coordinator listens to), and Return is delivered as the command the field
/// editor actually sends. Every commit the row reports is recorded, because the
/// defect is not in the FIRST commit — it is in the one that arrives afterwards,
/// when the caret moves on and the field tears down.
@MainActor
final class VisionTileRowSubmitTests: XCTestCase {

    private var window: NSWindow!
    private var commits: [(text: String, continuing: Bool)] = []

    override func setUp() async throws {
        try await super.setUp()
        commits = []
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    override func tearDown() async throws {
        window = nil
        try await super.tearDown()
    }

    private func settle(_ turns: Int = 12) async {
        for _ in 0..<turns {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func field(in view: NSView) -> ClearBackgroundTextField? {
        if let found = view as? ClearBackgroundTextField { return found }
        for sub in view.subviews {
            if let found = self.field(in: sub) { return found }
        }
        return nil
    }

    /// A blank item in edit, which is exactly the state `addItem` leaves behind.
    private func hostBlankItemInEdit() -> NSHostingView<VisionTileRow> {
        let view = NSHostingView(
            rootView: VisionTileRow(
                row: .item(VisionItem(text: "")),
                showsDue: false,
                isEditing: true,
                onToggle: {},
                onBeginEdit: {},
                onCommit: { [self] text, continuing in
                    commits.append((text, continuing))
                },
                onCancel: {},
                onRemoveFromBoard: nil,
                onRemove: {}
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        window.contentView = view
        return view
    }

    /// Type the way a person does: into the field editor, not the binding.
    private func type(_ text: String, into field: ClearBackgroundTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field is editing")
        editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    private func pressReturn(in field: ClearBackgroundTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// Return reports the typed text, and asks for the next line.
    func testReturnCommitsTheTypedText() async throws {
        let view = hostBlankItemInEdit()
        await settle()
        let field = try XCTUnwrap(self.field(in: view))

        try type("Book the flights", into: field)
        try pressReturn(in: field)

        XCTAssertEqual(commits.first?.text, "Book the flights")
        XCTAssertEqual(commits.first?.continuing, true, "Return chains into the next item")
    }

    /// The commit that arrives AFTER Return must carry the same text.
    ///
    /// This is the reported bug. Return chains, which moves the caret to a new
    /// row, which tears this field down, which fires the blur commit. If the
    /// Return handler has meanwhile emptied the field, that blur reports "" for
    /// an item that was just saved — and empty text removes an item. Created,
    /// saved, deleted, in one keypress, leaving a blank row to type into again.
    func testTheFieldStillHoldsTheTextAfterReturn() async throws {
        let view = hostBlankItemInEdit()
        await settle()
        let field = try XCTUnwrap(self.field(in: view))

        try type("Book the flights", into: field)
        try pressReturn(in: field)

        XCTAssertEqual(field.stringValue, "Book the flights", "Return must not blank the row")

        // The teardown blur, delivered the way a re-render delivers it.
        window.makeFirstResponder(nil)
        await settle()

        let blur = try XCTUnwrap(commits.last)
        XCTAssertEqual(blur.text, "Book the flights", "the late blur must not report an empty item")
    }
}
