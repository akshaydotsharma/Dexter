import XCTest
@testable import PersonalDashboard

/// The iOS half of the plain-field placeholder fork (#576).
///
/// macOS draws the placeholder itself, because `.textFieldStyle(.plain)` makes
/// AppKit render it at near-ink strength. iOS has no such problem: UIKit draws a
/// plain field's placeholder muted already, so the field keeps its own title and
/// nothing about the phone changes.
///
/// That is worth a test rather than a comment. The fork lives in one function,
/// and the cheapest way to break the phone while fixing the Mac is to make that
/// function return an empty string on both platforms. The composer would then
/// show no example at all on iOS, and no macOS test would notice.
final class PlainFieldPlaceholderTests: XCTestCase {

    func testTheFieldKeepsItsOwnPlaceholderOnIOS() {
        XCTAssertEqual(
            PlainFieldPlaceholder.title(MealComposer.placeholderExample),
            MealComposer.placeholderExample,
            "iOS hands the example to the field, the same as before the macOS fix"
        )
    }

    func testTheExampleMealIsStillTheOneTheComposerAdvertises() {
        XCTAssertEqual(
            MealComposer.placeholderExample,
            "Two eggs on toast with butter and a flat white"
        )
    }
}
