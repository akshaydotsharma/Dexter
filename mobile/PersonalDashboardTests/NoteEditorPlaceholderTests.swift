import XCTest
import UIKit
@testable import PersonalDashboard

/// The note editor's placeholder (#424).
///
/// The bug: opening an existing note in edit mode drew the hint on top of the
/// note's first line. UIKit posts `textDidChangeNotification` only for user
/// edits, so a body loaded programmatically left the label at its default
/// visible state and nothing hid it until the next keystroke.
///
/// These assert on visibility after each way text can arrive, because the defect
/// has no other observable: the view builds, lays out, and reports the right
/// text while drawing two strings over each other.
@MainActor
final class NoteEditorPlaceholderTests: XCTestCase {

    private func makeEditor() -> PaddedTextView {
        let tv = PaddedTextView()
        tv.frame = CGRect(x: 0, y: 0, width: 320, height: 320)
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.textColor = .label
        tv.placeholderText = "Start writing."
        return tv
    }

    /// The reported case: content is already in hand when the editor is built,
    /// because a note opens in preview and the editor only exists once the
    /// pencil is tapped.
    func testPlaceholderHiddenWhenLoadedFromMarkdown() {
        let tv = makeEditor()
        tv.setNoteMarkdown("Career coach exploratory meeting.\n\n## Background\n\nMet with Amit.")
        XCTAssertFalse(tv.isPlaceholderVisible)
    }

    /// A brand-new note still needs the hint.
    func testPlaceholderVisibleWhenEmpty() {
        let tv = makeEditor()
        tv.setNoteMarkdown("")
        XCTAssertTrue(tv.isPlaceholderVisible)
    }

    /// Assigning the placeholder AFTER the body — the order `updateUIView` uses
    /// when SwiftUI hands down a changed placeholder — must not resurrect it.
    func testPlaceholderAssignedAfterBodyStaysHidden() {
        let tv = makeEditor()
        tv.setNoteMarkdown("Some existing note text.")
        tv.placeholderText = "Start writing. Use the bar above the keyboard…"
        XCTAssertFalse(tv.isPlaceholderVisible)
    }

    /// Emptying the note brings it back, so the fix is not "hide it forever".
    func testPlaceholderReturnsWhenBodyIsCleared() {
        let tv = makeEditor()
        tv.setNoteMarkdown("Something.")
        XCTAssertFalse(tv.isPlaceholderVisible)
        tv.setNoteMarkdown("")
        XCTAssertTrue(tv.isPlaceholderVisible)
    }

    /// The toolbar and the Return-key list continuation both rebuild the whole
    /// display string, which is a third programmatic path into the text.
    func testPlaceholderTracksDisplayStringReplacement() {
        let tv = makeEditor()
        tv.applyDisplayString("- first item")
        XCTAssertFalse(tv.isPlaceholderVisible)
        tv.applyDisplayString("")
        XCTAssertTrue(tv.isPlaceholderVisible)
    }

    /// The hint wraps to the visible column instead of laying out as one line
    /// running off the right edge: pinned to the scroll view's frame guide, not
    /// to the content-defining anchors it had before (#424).
    func testPlaceholderWrapsToTheVisibleWidth() throws {
        let tv = makeEditor()
        tv.placeholderText = String(repeating: "wrap this hint text ", count: 8)
        tv.setNoteMarkdown("")
        tv.layoutIfNeeded()

        let hint = try XCTUnwrap(tv.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertEqual(hint.bounds.width, tv.bounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(hint.bounds.height, 20, "should have wrapped onto several lines")
    }
}
