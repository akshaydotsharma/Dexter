import XCTest
@testable import PersonalDashboard

/// The note-row preview scan (#614).
///
/// `markdownSnippetAttributed` used to split every line of a note into an array
/// in order to show one of them, on every note row that scrolled into view. The
/// replacement is a single pass that stops at the first line with something on
/// it. These tests pin the behaviour the old split had, because a preview that
/// silently starts showing the wrong line is worse than a slow one.
final class NoteSnippetScanTests: XCTestCase {

    func testTakesTheFirstLineWhenItHasText() {
        XCTAssertEqual(firstNonBlankLine(of: "Hello\nworld"), "Hello")
    }

    func testSkipsLeadingBlankLines() {
        XCTAssertEqual(firstNonBlankLine(of: "\n\n   \n  Real content\nmore"), "  Real content")
    }

    func testReturnsNilWhenEverythingIsBlank() {
        XCTAssertNil(firstNonBlankLine(of: ""))
        XCTAssertNil(firstNonBlankLine(of: "\n\n   \n\t\n"))
    }

    func testASingleLineWithNoTrailingNewlineIsReturned() {
        XCTAssertEqual(firstNonBlankLine(of: "just one line"), "just one line")
    }

    /// CRLF and the Unicode line separators counted as newlines under
    /// `components(separatedBy: .newlines)`, so they must here too.
    func testHandlesCarriageReturnsAndUnicodeSeparators() {
        XCTAssertEqual(firstNonBlankLine(of: "first\r\nsecond"), "first")
        XCTAssertEqual(firstNonBlankLine(of: "\r\nsecond"), "second")
        XCTAssertEqual(firstNonBlankLine(of: "alpha\u{2028}beta"), "alpha")
    }

    /// The whole point: cost must not scale with the rest of the note.
    func testDoesNotWalkPastTheFirstLine() {
        let hugeTail = String(repeating: "padding padding padding\n", count: 20_000)
        let source = "the only line that matters\n" + hugeTail

        let started = Date()
        let line = firstNonBlankLine(of: source)
        let elapsedMS = Date().timeIntervalSince(started) * 1000

        XCTAssertEqual(line, "the only line that matters")
        XCTAssertLessThan(
            elapsedMS, 5,
            "the scan took \(elapsedMS)ms on a note whose first line is 26 characters, "
            + "so it is still walking the whole note"
        )
    }

    /// The renderer still produces the same visible text through the new scan.
    func testSnippetStillRendersTheFirstMeaningfulLine() {
        let attributed = markdownSnippetAttributed("\n\n## A heading\nbody text")
        XCTAssertEqual(String(attributed.characters), "A heading")
    }
}
