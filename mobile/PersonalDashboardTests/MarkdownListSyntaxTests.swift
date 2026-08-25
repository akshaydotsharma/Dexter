import XCTest
@testable import PersonalDashboard

/// Multi-level bullets in note bodies (#459).
///
/// Two halves, and both used to be broken in a way a build could never catch.
/// The renderer threw a line's leading whitespace away before deciding what the
/// line was, so a sub-bullet came out level with its parent. The editors had no
/// way to produce that whitespace in the first place.
///
/// The cases below therefore fix the two things that make nesting either work or
/// silently flatten: that DEPTH is read off the indentation, and that an edit
/// which moves a line between levels leaves the rest of the note alone.
final class MarkdownListSyntaxTests: XCTestCase {

    // MARK: - Parsing

    func testParsesMarkerAfterIndent() {
        let item = MarkdownListSyntax.parse("    - child")
        XCTAssertEqual(item?.indent, "    ")
        XCTAssertEqual(item?.content, "child")
        XCTAssertEqual(item?.indentWidth, 4)
    }

    func testEveryBulletSpellingParses() {
        for line in ["- a", "* a", "+ a"] {
            XCTAssertEqual(MarkdownListSyntax.parse(line)?.content, "a", "failed on \(line)")
        }
    }

    func testOrderedMarkerCarriesItsNumber() {
        guard let item = MarkdownListSyntax.parse("  12. twelve") else {
            return XCTFail("expected an ordered item")
        }
        XCTAssertEqual(item.marker, .number(12))
        XCTAssertEqual(item.nextMarker, "13. ")
        XCTAssertEqual(item.content, "twelve")
    }

    func testMarkerNeedsItsTrailingSpace() {
        // A lone dash is a thematic break, not an empty bullet. Reading it as a
        // list item would make Return on a `---` line start a list.
        XCTAssertNil(MarkdownListSyntax.parse("-"))
        XCTAssertNil(MarkdownListSyntax.parse("---"))
        XCTAssertNil(MarkdownListSyntax.parse("1.no space"))
        XCTAssertNil(MarkdownListSyntax.parse("plain text"))
    }

    func testTabCountsAsFourColumns() {
        XCTAssertEqual(MarkdownListSyntax.parse("\t- a")?.indentWidth, 4)
    }

    // MARK: - Depth

    func testDepthFollowsTheWidthsInUseNotAFixedUnit() {
        // The editors write two spaces per level; the Apple Notes importer
        // writes four. Both have to nest, so depth comes from the ORDER of the
        // widths rather than from dividing by a constant.
        for unit in [2, 4] {
            var resolver = MarkdownListSyntax.DepthResolver()
            XCTAssertEqual(resolver.depth(forWidth: 0), 0, "unit \(unit)")
            XCTAssertEqual(resolver.depth(forWidth: unit), 1, "unit \(unit)")
            XCTAssertEqual(resolver.depth(forWidth: unit * 2), 2, "unit \(unit)")
            XCTAssertEqual(resolver.depth(forWidth: unit), 1, "unit \(unit)")
            XCTAssertEqual(resolver.depth(forWidth: 0), 0, "unit \(unit)")
        }
    }

    // MARK: - Rendering

    /// The regression itself: three levels in, three levels out.
    func testNestedBulletsRenderAtTheirOwnDepth() {
        let blocks = MarkdownParser.parse("""
        - one
          - two
            - three
        - back
        """)
        guard case .list(let items)? = blocks.first, blocks.count == 1 else {
            return XCTFail("expected a single list block, got \(blocks)")
        }
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(items.map(\.text), ["one", "two", "three", "back"])
        // A different glyph per level, so siblings read apart without counting
        // pixels of indent.
        XCTAssertEqual(Set(items.map(\.marker)).count, 3)
    }

    func testFourSpaceImportsNestToo() {
        // What `AppleNotesHTMLConverter` emits. These notes are already in the
        // library and rendered flat before this change.
        let blocks = MarkdownParser.parse("- one\n    - two")
        guard case .list(let items)? = blocks.first else {
            return XCTFail("expected a list block")
        }
        XCTAssertEqual(items.map(\.depth), [0, 1])
    }

    func testSubListIsPartOfTheListItSitsIn() {
        // One block, not three: a block boundary would open a visible gap
        // between a parent bullet and its numbered children.
        let blocks = MarkdownParser.parse("- parent\n  1. one\n  2. two\n- sibling")
        XCTAssertEqual(blocks.count, 1)
    }

    func testNestedNumberingRestartsPerLevelAndResumesAfterOne() {
        let blocks = MarkdownParser.parse("""
        1. one
           1. inner
           2. inner two
        2. two
        """)
        guard case .list(let items)? = blocks.first else {
            return XCTFail("expected a list block")
        }
        XCTAssertEqual(items.map(\.marker), ["1.", "1.", "2.", "2."])
    }

    func testFlatListStillRendersFlat() {
        let blocks = MarkdownParser.parse("- a\n- b\n- c")
        guard case .list(let items)? = blocks.first else {
            return XCTFail("expected a list block")
        }
        XCTAssertEqual(items.map(\.depth), [0, 0, 0])
        XCTAssertEqual(Set(items.map(\.marker)), ["\u{2022}"])
    }

    // MARK: - Return

    func testReturnContinuesAtTheSameIndent() {
        let text = "- one\n  - two"
        let edit = MarkdownListSyntax.returnPressed(
            in: text, replacing: NSRange(location: (text as NSString).length, length: 0)
        )
        XCTAssertEqual(edit?.text, "- one\n  - two\n  - ")
    }

    func testReturnOnAnEmptyNestedItemStepsOutOneLevel() {
        let text = "- one\n    - "
        let edit = MarkdownListSyntax.returnPressed(
            in: text, replacing: NSRange(location: (text as NSString).length, length: 0)
        )
        // Out one level, still a bullet: the list is not over, this level is.
        XCTAssertEqual(edit?.text, "- one\n  - ")
    }

    func testReturnOnAnEmptyTopLevelItemLeavesTheList() {
        let text = "- one\n- "
        let edit = MarkdownListSyntax.returnPressed(
            in: text, replacing: NSRange(location: (text as NSString).length, length: 0)
        )
        XCTAssertEqual(edit?.text, "- one\n")
    }

    func testReturnOnAnOrdinaryLineIsNotOurs() {
        XCTAssertNil(MarkdownListSyntax.returnPressed(
            in: "just a note", replacing: NSRange(location: 11, length: 0)
        ))
    }

    // MARK: - Indent and outdent

    func testIndentMovesTheLineOneLevelIn() {
        let text = "- one\n- two"
        let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 8, length: 0), by: 1
        )
        XCTAssertEqual(edit?.text, "- one\n  - two")
    }

    func testTheFirstItemOfAListCannotIndent() {
        // Markdown has nothing for it to nest under, and CommonMark reads an
        // indented first item as part of the paragraph above it.
        XCTAssertNil(MarkdownListSyntax.shiftIndent(
            in: "- only", selection: NSRange(location: 3, length: 0), by: 1
        ))
    }

    func testIndentingAnOrderedItemRenumbersItForItsNewSiblings() {
        let text = "1. one\n2. two\n3. three"
        let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 16, length: 0), by: 1
        )
        // "3." indented under "2." is the first of a new sub-list, so 1.
        XCTAssertEqual(edit?.text, "1. one\n2. two\n  1. three")
    }

    func testOutdentRenumbersAgainstTheLevelItRejoins() {
        let text = "1. one\n  1. inner"
        let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 12, length: 0), by: -1
        )
        XCTAssertEqual(edit?.text, "1. one\n2. inner")
    }

    func testOutdentAtTheMarginDoesNothing() {
        XCTAssertNil(MarkdownListSyntax.shiftIndent(
            in: "- a\n- b", selection: NSRange(location: 6, length: 0), by: -1
        ))
    }

    func testIndentOnAnOrdinaryLineDoesNothing() {
        // Four spaces in front of plain text is a code block, so a press that
        // "did something" here would change what the note says.
        XCTAssertNil(MarkdownListSyntax.shiftIndent(
            in: "a paragraph", selection: NSRange(location: 2, length: 0), by: 1
        ))
    }

    func testIndentMovesEveryListLineInASelection() {
        let text = "- one\n- two\n- three"
        let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 6, length: 13), by: 1
        )
        XCTAssertEqual(edit?.text, "- one\n  - two\n  - three")
    }

    func testAnEditLeavesTheRestOfTheNoteAlone() {
        let text = "# Title\n\nsome prose\n\n- one\n- two\n\nmore prose"
        guard let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 29, length: 0), by: 1
        ) else { return XCTFail("expected the indent to apply") }
        XCTAssertEqual(edit.text, "# Title\n\nsome prose\n\n- one\n  - two\n\nmore prose")
    }

    func testCaretFollowsTheTextItWasIn() {
        // The caret sat two characters into "two"; after the indent it has to
        // still be two characters into "two", not two characters into the
        // whitespace that was pushed in front of it.
        let text = "- one\n- two"
        let edit = MarkdownListSyntax.shiftIndent(
            in: text, selection: NSRange(location: 10, length: 0), by: 1
        )
        XCTAssertEqual(edit?.selection.location, 12)
    }
}
