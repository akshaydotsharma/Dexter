import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// Does ONE click put the caret in an item? (#446)
///
/// Reported: *"I need to click on the text two times to edit it. It doesn't
/// happen on the first time."* The first click is what flips `isEditing`, so the
/// question this file answers is narrower and testable: when a row is rendered
/// with `isEditing: true`, does its field actually take first responder?
///
/// A real `NSWindow` is needed and is allowed — `makeFirstResponder` works on an
/// off-screen window, and none of this requires the window to be KEY, which is
/// the thing an agent-launched app can never get. Hosting the row for real is
/// what makes the answer trustworthy: the focus hop goes SwiftUI state →
/// `updateNSView` → a deferred `applyFocusIfNeeded`, and every step of that is
/// invisible to a pure unit test.
@MainActor
final class VisionTileRowFocusTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    override func tearDown() async throws {
        window = nil
        try await super.tearDown()
    }

    /// Let SwiftUI render, `updateNSView` run, and the deferred focus hop land.
    private func settle(_ turns: Int = 12) async {
        for _ in 0..<turns {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The field, wherever SwiftUI put it in the hierarchy.
    private func field(in view: NSView) -> ClearBackgroundTextField? {
        if let found = view as? ClearBackgroundTextField { return found }
        for sub in view.subviews {
            if let found = self.field(in: sub) { return found }
        }
        return nil
    }

    private func host(_ row: VisionRow, isEditing: Bool) -> NSHostingView<VisionTileRow> {
        let view = NSHostingView(
            rootView: VisionTileRow(
                row: row,
                showsDue: false,
                isEditing: isEditing,
                onToggle: {},
                onBeginEdit: {},
                onCommit: { _, _ in },
                onCancel: {},
                onRemoveFromBoard: nil,
                onRemove: {}
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        window.contentView = view
        return view
    }

    /// Clicking an item leaves a CARET at the end, not the line selected.
    ///
    /// Reported: *"when I select an item to be edited, it selects the whole text
    /// and then I need to click again to add a text."* AppKit selects the whole
    /// string when a field takes first responder, so the next keystroke replaced
    /// the line — which is why a second click was needed to get a caret.
    func testTheCaretLandsAtTheEndOfTheExistingText() async throws {
        let item = VisionItem(text: "Product Design")
        let view = host(.item(item), isEditing: true)
        await settle()

        let field = try XCTUnwrap(self.field(in: view))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field is editing")

        XCTAssertEqual(
            editor.selectedRange(),
            NSRange(location: "Product Design".count, length: 0),
            "an empty selection at the end: a caret, ready to type the next character"
        )
    }

    /// And typing appends rather than replacing, which is the thing the person
    /// actually noticed. Asserted through the field editor because that is the
    /// only writer the field listens to.
    func testTypingAfterOneClickAppendsInsteadOfReplacing() async throws {
        let item = VisionItem(text: "Product")
        let view = host(.item(item), isEditing: true)
        await settle()

        let field = try XCTUnwrap(self.field(in: view))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(" Sense", replacementRange: editor.selectedRange())

        XCTAssertEqual(field.stringValue, "Product Sense")
    }

    /// A row rendered in edit must have a field, and that field must hold the
    /// caret. If it does not, the click that opened the edit is spent making the
    /// row swap its `Text` for a `TextField` and the NEXT click is what actually
    /// focuses it — which is the reported two-click rename exactly.
    func testARowRenderedInEditHoldsTheCaret() async throws {
        let item = VisionItem(text: "Third item")
        let view = host(.item(item), isEditing: true)
        await settle()

        let field = try XCTUnwrap(self.field(in: view), "the edit field mounted")
        XCTAssertEqual(field.stringValue, "Third item", "and it carries the row's text")
        XCTAssertTrue(field.isEditingNow, "one click, one caret")
    }

    /// The text must not be lost or blanked by the swap.
    func testTheFieldNeverStartsEmptyOverANonEmptyItem() async throws {
        let item = VisionItem(text: "Get three quotes")
        let view = host(.item(item), isEditing: true)
        await settle()

        let field = try XCTUnwrap(self.field(in: view))
        XCTAssertEqual(field.stringValue, "Get three quotes")
    }
}
