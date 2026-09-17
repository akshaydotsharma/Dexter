import XCTest
import SwiftUI
@testable import PersonalDashboard

#if os(iOS)
/// What one keystroke costs in the note editor (#614).
///
/// Typing in a long note stuttered. Per character the editor was serialising the
/// whole note to markdown in `textViewDidChange`, serialising it AGAIN in
/// `updateUIView` to decide whether the binding had diverged, comparing the two
/// full strings, and then laying out the entire document because
/// `sizeThatFits` measures a `UITextView` with `isScrollEnabled = false`.
///
/// The real store's longest note is 10,902 characters, so these tests work at
/// that scale rather than at toy sizes, where every one of these costs rounds to
/// zero and the test proves nothing.
@MainActor
final class NoteEditorTypingCostTests: XCTestCase {

    /// The real store's longest note, near enough.
    private static let longNoteBody = String(repeating: "The quick brown fox. ", count: 520)

    private func makeEditor(text: String) -> PaddedTextView {
        let tv = PaddedTextView()
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.textColor = .label
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setNoteMarkdown(text)
        return tv
    }

    func testTheLongNoteFixtureIsActuallyLong() {
        XCTAssertGreaterThan(
            Self.longNoteBody.count, 10_000,
            "the fixture shrank, so these tests are no longer measuring the case that hurt"
        )
    }

    // MARK: - Markdown serialisation

    /// Reading the markdown twice serialises once.
    func testRepeatedMarkdownReadsAreMemoised() {
        let tv = makeEditor(text: Self.longNoteBody)

        let first = tv.currentNoteMarkdown
        let second = tv.currentNoteMarkdown
        XCTAssertEqual(first, second)

        // The memo must be a memo, not a copy that can drift: a real edit has to
        // be visible through it.
        tv.text = Self.longNoteBody + " appended"
        XCTAssertEqual(
            tv.currentNoteMarkdown, Self.longNoteBody + " appended",
            "the markdown memo survived an edit, so the editor would publish stale text"
        )
    }

    /// Every mutation path clears the memo.
    ///
    /// This is the property the cache lives or dies on. A missed invalidation
    /// here does not show up as a slow editor, it shows up as a note that saves
    /// the wrong body, which is the worse failure by a distance.
    func testEveryMutationPathClearsTheMemo() {
        let tv = makeEditor(text: "original")
        XCTAssertEqual(tv.currentNoteMarkdown, "original")

        tv.text = "via text setter"
        XCTAssertEqual(tv.currentNoteMarkdown, "via text setter")

        tv.attributedText = NSAttributedString(string: "via attributedText setter")
        XCTAssertEqual(tv.currentNoteMarkdown, "via attributedText setter")

        tv.setNoteMarkdown("via setNoteMarkdown")
        XCTAssertEqual(tv.currentNoteMarkdown, "via setNoteMarkdown")

        // The user's own typing does not go through any setter. The coordinator
        // clears the memo by hand for exactly this case; simulate that contract.
        tv.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: tv.textStorage.length),
            with: "as if typed"
        )
        tv.invalidateNoteMarkdownCache()
        XCTAssertEqual(tv.currentNoteMarkdown, "as if typed")
    }

    // MARK: - Layout measurement

    /// Re-measuring at the same width and content does not lay out again.
    ///
    /// SwiftUI calls `sizeThatFits` several times per layout pass with different
    /// proposals, and a layout pass happens on every keystroke. Collapsing the
    /// repeats within one pass is the win; a miss across keystrokes is correct.
    func testRepeatedMeasurementAtTheSameWidthIsMemoised() {
        let tv = makeEditor(text: Self.longNoteBody)
        let width: CGFloat = 353

        let cold = Date()
        let first = tv.measuredHeight(fittingWidth: width)
        let coldMS = Date().timeIntervalSince(cold) * 1000

        let warm = Date()
        for _ in 0..<50 { _ = tv.measuredHeight(fittingWidth: width) }
        let warmMS = Date().timeIntervalSince(warm) * 1000

        XCTAssertGreaterThan(first, 0)
        print("[#614] note height measure — first: \(String(format: "%.1f", coldMS))ms, next 50: \(String(format: "%.1f", warmMS))ms")

        XCTAssertLessThan(
            warmMS, coldMS,
            "fifty repeat measurements cost more than the first one, so the memo is not "
            + "working and every SwiftUI layout pass still lays out the whole note"
        )
    }

    /// The memo must not outlive the thing it measured.
    func testMeasurementIsRecomputedWhenTheContentChanges() {
        let tv = makeEditor(text: "one line")
        let width: CGFloat = 353

        let short = tv.measuredHeight(fittingWidth: width)
        tv.text = Self.longNoteBody
        let tall = tv.measuredHeight(fittingWidth: width)

        XCTAssertGreaterThan(
            tall, short,
            "the height memo survived a content change, so a growing note would be "
            + "clipped to the height of its first line"
        )
    }

    /// A different width must re-measure, or rotation clips the note.
    func testMeasurementIsRecomputedWhenTheWidthChanges() {
        let tv = makeEditor(text: Self.longNoteBody)

        let narrow = tv.measuredHeight(fittingWidth: 200)
        let wide = tv.measuredHeight(fittingWidth: 700)

        XCTAssertGreaterThan(
            narrow, wide,
            "the same text did not get taller when the column got narrower, so the "
            + "width is not part of the memo key"
        )
    }
}
#endif
