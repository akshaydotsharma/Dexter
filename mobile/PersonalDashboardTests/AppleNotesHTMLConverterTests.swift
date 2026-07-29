import XCTest
@testable import PersonalDashboard

/// Apple Notes HTML to Dexter markdown (#396).
///
/// The converter is the part of the import most likely to be quietly wrong: a bad
/// rule does not crash, it just produces notes that read slightly badly, across
/// hundreds of them at once. These pin the shapes measured in a real 324-note
/// library on 2026-07-30 — `div` per line, `br`, `ul`/`ol`/`li`, `h1`–`h3`, `b`,
/// `i`, `u`, `strike`, `font`, plus inline base64 `img`.
final class AppleNotesHTMLConverterTests: XCTestCase {

    // MARK: - Title

    /// Notes repeats the note's title as a leading `<h1>`. Left in the body, every
    /// imported note would show its title twice.
    func testLeadingHeadingBecomesTheTitleAndLeavesTheBody() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<div><h1>Shot list</h1></div><div>First line.</div>"
        )
        XCTAssertEqual(result.title, "Shot list")
        XCTAssertEqual(result.markdown, "First line.")
    }

    /// A heading further down is a real section heading and must survive as one.
    func testHeadingAfterBodyTextStaysAHeading() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<div>Intro line.</div><div><h1>Section</h1></div><div>More.</div>"
        )
        XCTAssertNil(result.title, "only a LEADING heading is the title")
        XCTAssertTrue(result.markdown.contains("# Section"))
        XCTAssertTrue(result.markdown.hasPrefix("Intro line."))
    }

    func testNoHeadingMeansNoTitle() {
        let result = AppleNotesHTMLConverter.convert(html: "<div>Just a line.</div>")
        XCTAssertNil(result.title)
        XCTAssertEqual(result.markdown, "Just a line.")
    }

    // MARK: - Inline styling

    func testBoldItalicAndStrikeBecomeMarkdown() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<div><b>bold</b> and <i>italic</i> and <strike>gone</strike></div>"
        )
        XCTAssertEqual(result.markdown, "**bold** and *italic* and ~~gone~~")
    }

    /// Underline has no markdown equivalent and the renderer has no underline, so
    /// the tag goes and the text stays rather than inventing syntax that would
    /// render as literal characters.
    func testUnderlineKeepsItsTextWithoutInventingSyntax() {
        let result = AppleNotesHTMLConverter.convert(html: "<div><u>plain</u></div>")
        XCTAssertEqual(result.markdown, "plain")
    }

    func testLinksBecomeMarkdownLinks() {
        let result = AppleNotesHTMLConverter.convert(
            html: #"<div><a href="https://example.com">a link</a></div>"#
        )
        XCTAssertEqual(result.markdown, "[a link](https://example.com)")
    }

    // MARK: - Lists

    func testUnorderedListBecomesBullets() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<ul><li>one</li><li>two</li></ul>"
        )
        XCTAssertEqual(result.markdown, "- one\n- two")
    }

    /// Numbering is generated, not copied: the source has no numbers, so an
    /// off-by-one here would renumber every ordered list in the library.
    func testOrderedListNumbersFromOne() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<ol><li>first</li><li>second</li><li>third</li></ol>"
        )
        XCTAssertEqual(result.markdown, "1. first\n2. second\n3. third")
    }

    /// A nested list has to restore its parent's kind when it closes, otherwise
    /// items after the nested block take the wrong marker.
    func testNestedListIndentsAndRestoresTheParentKind() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<ol><li>outer one</li><ul><li>inner</li></ul><li>outer two</li></ol>"
        )
        let lines = result.markdown.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "1. outer one")
        XCTAssertTrue(
            lines.contains(where: { $0.hasPrefix("    - inner") }),
            "nested item should indent, got \(lines)"
        )
        XCTAssertTrue(
            lines.contains("2. outer two"),
            "numbering should resume in the outer list, got \(lines)"
        )
    }

    func testChecklistBecomesTaskListItems() {
        let result = AppleNotesHTMLConverter.convert(
            html: #"<ul class="checklist"><li>todo</li></ul>"#
        )
        XCTAssertEqual(result.markdown, "- [ ] todo")
    }

    // MARK: - Images

    /// The finding the whole import rests on: images are inlined as base64 data
    /// URIs in document POSITION, so the body alone carries both the picture and
    /// where it belongs.
    func testInlineImageBecomesAPlaceholderInPosition() throws {
        let payload = Data("hello".utf8).base64EncodedString()
        let result = AppleNotesHTMLConverter.convert(
            html: "<div>before</div><div><img src=\"data:image/png;base64,\(payload)\"></div><div>after</div>"
        )
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images.first?.data, Data("hello".utf8))
        XCTAssertEqual(result.images.first?.index, 0)

        let placeholder = AppleNotesHTMLConverter.placeholder(0)
        let lines = result.markdown.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["before", placeholder, "after"],
                       "the image must land between the two paragraphs")
    }

    func testMultipleImagesAreNumberedInDocumentOrder() {
        let first = Data("one".utf8).base64EncodedString()
        let second = Data("two".utf8).base64EncodedString()
        let result = AppleNotesHTMLConverter.convert(
            html: """
            <div><img src="data:image/png;base64,\(first)"></div>\
            <div>middle</div>\
            <div><img src="data:image/tiff;base64,\(second)"></div>
            """
        )
        XCTAssertEqual(result.images.map(\.index), [0, 1])
        XCTAssertEqual(result.images.map(\.data), [Data("one".utf8), Data("two".utf8)])
        XCTAssertTrue(result.markdown.contains(AppleNotesHTMLConverter.placeholder(0)))
        XCTAssertTrue(result.markdown.contains(AppleNotesHTMLConverter.placeholder(1)))
    }

    /// An `<img>` with nothing decodable must not leave a dangling tag or a
    /// placeholder that no image will ever fill.
    func testUndecodableImageIsDroppedEntirely() {
        let result = AppleNotesHTMLConverter.convert(
            html: #"<div>text<img src="https://example.com/remote.png"></div>"#
        )
        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.markdown, "text")
        XCTAssertFalse(result.markdown.contains("{{dexter-image"))
    }

    /// Notes reports every attachment, but only images are inlined. PDFs and scans
    /// are counted so the import can say what it could not carry across instead of
    /// dropping them silently.
    func testNonImageAttachmentsAreCounted() {
        let payload = Data("img".utf8).base64EncodedString()
        let result = AppleNotesHTMLConverter.convert(
            html: "<div><img src=\"data:image/png;base64,\(payload)\"></div>",
            attachmentCount: 4
        )
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.nonImageAttachmentCount, 3)
    }

    func testAttachmentCountBelowImageCountCannotGoNegative() {
        let payload = Data("img".utf8).base64EncodedString()
        let result = AppleNotesHTMLConverter.convert(
            html: "<div><img src=\"data:image/png;base64,\(payload)\"></div>",
            attachmentCount: 0
        )
        XCTAssertEqual(result.nonImageAttachmentCount, 0)
    }

    // MARK: - Entities and whitespace

    func testEntitiesAreDecodedWithAmpersandLast() {
        // `&amp;lt;` must survive as the literal text "&lt;", not become "<".
        // Decoding `&amp;` first is the classic way to turn escaped text into
        // markup.
        let result = AppleNotesHTMLConverter.convert(
            html: "<div>&quot;quoted&quot; &amp; &lt;tag&gt; &amp;lt;escaped&amp;gt;</div>"
        )
        XCTAssertEqual(result.markdown, "\"quoted\" & <tag> &lt;escaped&gt;")
    }

    func testNumericEntitiesDecodeDecimalAndHex() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<div>&#8212; and &#x2019;</div>"
        )
        XCTAssertEqual(result.markdown, "— and \u{2019}")
    }

    /// Notes emits a `<div>` per line plus its own breaks, so newline runs pile up
    /// fast. Blank lines the user typed should survive as one blank line, not as
    /// six.
    func testExcessBlankLinesCollapseButParagraphBreaksSurvive() {
        let result = AppleNotesHTMLConverter.convert(
            html: "<div>one</div><div><br></div><div><br></div><div><br></div><div>two</div>"
        )
        XCTAssertEqual(result.markdown, "one\n\ntwo")
    }

    func testFontTagsAreStrippedWithoutLosingText() {
        let result = AppleNotesHTMLConverter.convert(
            // `##"…"##`: the colour value contains `"#`, which would close a
            // single-hash raw string early.
            html: ##"<div><font color="#ff0000">red text</font></div>"##
        )
        XCTAssertEqual(result.markdown, "red text")
    }

    func testEmptyBodyProducesEmptyMarkdown() {
        XCTAssertEqual(AppleNotesHTMLConverter.convert(html: "").markdown, "")
        XCTAssertEqual(AppleNotesHTMLConverter.convert(html: "<div></div>").markdown, "")
    }
}
