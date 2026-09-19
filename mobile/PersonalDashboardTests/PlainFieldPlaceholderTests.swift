import XCTest
@testable import PersonalDashboard

/// The plain-field placeholder forks, and it forks TWICE (#576, #627).
///
/// **Single line.** macOS draws the placeholder itself, because
/// `.textFieldStyle(.plain)` makes AppKit render it at near-ink strength. iOS has
/// no such problem: UIKit draws a plain field's placeholder muted already, so the
/// field keeps its own title and nothing about the phone changes.
///
/// **Multi line.** Both platforms draw it themselves, because the problem there
/// is position rather than colour: UIKit centres a placeholder vertically in the
/// text container, which on a three-line composer puts the example halfway down
/// a box whose caret is at the top of line one.
///
/// That is worth tests rather than comments. Each fork lives in one function,
/// and the cheapest way to break one platform while fixing the other is to make
/// a function answer the same on both.
final class PlainFieldPlaceholderTests: XCTestCase {

    func testASingleLineFieldKeepsItsOwnPlaceholderOnIOS() {
        XCTAssertEqual(
            PlainFieldPlaceholder.title(MealComposer.placeholderExample),
            MealComposer.placeholderExample,
            "iOS hands the example to a single-line field, the same as before the macOS fix"
        )
    }

    /// The multi-line half, added in #627, forks the OTHER way: empty on both
    /// platforms.
    ///
    /// Worth its own test for the reason the one above is worth having. The fix
    /// lives in one function, and the cheapest way to reintroduce the bug is to
    /// make this one return the example on iOS "for consistency" with `title`.
    /// The field would then draw the native placeholder AND the overlay, two
    /// copies of the example in two different places, one of them where the
    /// caret is not.
    func testAMultilineFieldDrawsItsOwnPlaceholderOnBothPlatforms() {
        XCTAssertTrue(
            PlainFieldPlaceholder.multilineTitle(MealComposer.placeholderExample).isEmpty,
            """
            a multi-line field must be handed NO native placeholder. UIKit draws \
            one vertically centred, which on a three-line box sits nowhere near \
            the caret on line one (#627).
            """
        )
    }

    /// The two halves must disagree. If they ever returned the same thing, one
    /// of them is wrong and the fork has been flattened.
    func testTheSingleAndMultilineTitlesAreNotTheSameAnswer() {
        XCTAssertNotEqual(
            PlainFieldPlaceholder.title(MealComposer.placeholderExample),
            PlainFieldPlaceholder.multilineTitle(MealComposer.placeholderExample),
            "on iOS a single-line field keeps its native placeholder and a multi-line one does not"
        )
    }

    func testTheExampleMealIsStillTheOneTheComposerAdvertises() {
        XCTAssertEqual(
            MealComposer.placeholderExample,
            "Two eggs on toast with butter and a flat white"
        )
    }
}
