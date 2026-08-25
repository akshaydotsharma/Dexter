import XCTest
import AppKit
@testable import DexterMac

/// The AppKit half of multi-level bullets (#459).
///
/// `MarkdownListSyntax` decides WHAT a list edit should produce and is covered
/// on the iOS side. What only exists here is how that result is put into an
/// `NSTextView`: as the smallest replacement that produces it, so the text
/// storage either side of the change — inline image attachments included — is
/// left alone.
///
/// The alternative, assigning the whole string, compiles and looks right on a
/// note with no pictures. It silently drops every attachment on a note that has
/// them, which is the failure this file exists to keep out.
final class MacListEditingTests: XCTestCase {

    private func makeTextView(_ text: String) -> NSTextView {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 16)
        tv.textColor = .labelColor
        tv.string = text
        return tv
    }

    func testAnIndentIsAppliedToTheTextView() {
        let tv = makeTextView("- one\n- two")
        guard let edit = MarkdownListSyntax.shiftIndent(
            in: tv.string, selection: NSRange(location: 8, length: 0), by: 1
        ) else { return XCTFail("expected an indent") }

        tv.applyListEdit(edit)

        XCTAssertEqual(tv.string, "- one\n  - two")
        XCTAssertEqual(tv.selectedRange().location, 10)
    }

    func testAnEditOnlyTouchesTheRunThatDiffers() {
        // An attachment stands in for an inline note image. It survives only
        // because the replacement is narrowed to the marker run; a whole-string
        // assignment would leave the character and lose the attachment behind it.
        let tv = makeTextView("")
        let body = NSMutableAttributedString(string: "- one\n- two\n")
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 10, height: 10))
        body.append(NSAttributedString(attachment: attachment))
        tv.textStorage?.setAttributedString(body)

        guard let edit = MarkdownListSyntax.shiftIndent(
            in: tv.string, selection: NSRange(location: 8, length: 0), by: 1
        ) else { return XCTFail("expected an indent") }
        tv.applyListEdit(edit)

        var found = 0
        tv.attributedString().enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: tv.attributedString().length), options: []
        ) { value, _, _ in
            if value != nil { found += 1 }
        }
        XCTAssertEqual(found, 1, "the inline image was dropped by a list edit")
        XCTAssertTrue(tv.string.hasPrefix("- one\n  - two\n"))
    }

    func testReturnContinuesTheListInTheTextView() {
        let tv = makeTextView("- one\n  - two")
        guard let edit = MarkdownListSyntax.returnPressed(
            in: tv.string, replacing: NSRange(location: 13, length: 0)
        ) else { return XCTFail("expected a continuation") }

        tv.applyListEdit(edit)

        XCTAssertEqual(tv.string, "- one\n  - two\n  - ")
        XCTAssertEqual(tv.selectedRange().location, 18)
    }
}
