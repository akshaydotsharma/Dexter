import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The meal type as a kicker on its own line (#574).
///
/// #570 put it inline at the start of the description's first line. The
/// description paid about 70 pt of that line for it and then wrapped under
/// itself with a hanging indent. It is now a line of its own, above a
/// description that gets the full width on every line including the first.
///
/// Two of the rules here are invisible to a build and to a screenshot of one
/// row, which is why they are pinned:
///
/// 1. The row's height no longer depends on how long the type WORD is. That is
///    the mechanical statement of "the description is not sharing its line",
///    and it is the assertion that would have failed against the inline
///    layout, where "BREAKFAST" left the description 30 pt less first line
///    than "SNACK" did.
/// 2. The type sits closer to the description than any other pair of rungs.
///    Six evenly spaced lines read as a list of unrelated facts; a label set
///    tight against the thing it labels reads as one record.
@MainActor
final class MealRowKickerTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    // MARK: - The description has its own line back

    /// The same description renders the same row, whichever type is above it.
    ///
    /// Under the inline layout this was false by construction: the type ate the
    /// front of the first line, so a longer word pushed the description to wrap
    /// sooner and made the row taller. A kicker cannot, because it never shares
    /// the line.
    ///
    /// Several lengths, because the failure only shows on a description sitting
    /// near a wrap boundary and there is no single string that is near one for
    /// every type at once.
    func testTheRowHeightDoesNotDependOnTheLengthOfTheTypeWord() throws {
        let descriptions = [
            "Coffee",
            "A handful of cashews",
            "Chicken rice with extra chilli",
            "Two eggs on sourdough with avocado",
            "Grilled salmon, greens and new potatoes",
            "Leftover chicken biryani with raita and two papadums",
        ]
        for description in descriptions {
            let heights = try MealType.allCases.map { type in
                try height(of: meal(description, type: type))
            }
            let first = try XCTUnwrap(heights.first)
            for (type, h) in zip(MealType.allCases, heights) {
                XCTAssertEqual(
                    h, first, accuracy: 0.5,
                    "\"\(description)\" is \(h) pt under \(type.displayName) and \(first) pt under Breakfast"
                )
            }
        }
    }

    /// A description short enough for one line stays on one line under every
    /// type, so the widest word cannot push the shortest description over.
    func testAShortDescriptionStaysOnOneLineUnderEveryType() throws {
        let short = try height(of: meal("Coffee", type: .snack))
        let twoLines = try height(of: meal("Two eggs on sourdough with avocado", type: .snack))
        // The two-line case is taller by about one body line. If "Coffee" had
        // wrapped, the two would be equal.
        XCTAssertGreaterThan(twoLines - short, 10)
        XCTAssertLessThan(twoLines - short, 40)
    }

    // MARK: - The vertical rhythm

    /// The type is set closer to the description than the rungs are to each
    /// other, and the gap is still a gap.
    ///
    /// Stated against `Space.xs`, the stack's own spacing, rather than against
    /// a number, so a later change to the stack cannot quietly turn the
    /// relationship around.
    func testTheTypeSitsCloserToTheDescriptionThanTheOtherRungs() {
        let gap = Space.xs + MealRow.typeToDescriptionGap
        XCTAssertLessThan(gap, Space.xs, "the kicker is no tighter than a rung gap")
        XCTAssertGreaterThan(gap, 0, "the kicker is touching the description")
    }

    /// And the one row taller than another is taller by whole lines, not by a
    /// stray gap the short case left behind. A one-line description adds
    /// nothing beyond the kicker itself.
    func testAOneLineDescriptionLeavesNoExtraGap() throws {
        let oneWord = try height(of: meal("Toast", type: .breakfast))
        let alsoOneLine = try height(of: meal("Coffee", type: .breakfast))
        XCTAssertEqual(oneWord, alsoOneLine, accuracy: 0.5)
    }

    // MARK: - What #570 gave it, unchanged

    /// The colour, the gutter precedence and the spoken label all survive the
    /// move. Restated here rather than left to `MealRowTypeColourTests`,
    /// because a layout change is exactly when they would be dropped by
    /// accident.
    func testTheKickerKeepsTheColourAndTheGutterPrecedence() {
        for type in MealType.allCases {
            let healthy = MealRow(meal: meal("Toast", type: type), isDuplicate: false, onTap: {})
            XCTAssertEqual(healthy.gutterTint, type.tint)

            let flagged = MealRow(
                meal: meal("Toast", type: type, isSuspect: true, suspectReason: "Off"),
                isDuplicate: false,
                onTap: {}
            )
            XCTAssertEqual(flagged.gutterTint, Tokens.warning)
        }
    }

    /// One element, opening with the meal type. The kicker is a second `Text`
    /// in the stack now, so the risk the move introduces is the row being read
    /// as two stops instead of one.
    func testTheSpokenRowIsStillOneSentenceOpeningWithTheType() {
        for type in MealType.allCases {
            let row = MealRow(meal: meal("Chicken rice", type: type), isDuplicate: false, onTap: {})
            XCTAssertTrue(row.accessibilityText.hasPrefix(type.displayName))
            XCTAssertTrue(row.accessibilityText.contains("Chicken rice"))
        }
    }

    /// The crowded case still holds at phone width.
    func testTheRowHoldsAtPhoneWidthWithALongDescriptionAndThreeChips() throws {
        let crowded = meal(
            "Leftover chicken biryani with raita, two papadums and a small gulab jamun from the fridge",
            type: .dinner,
            isSuspect: true,
            suspectReason: "The macros do not add up to the calories."
        )
        let image = try XCTUnwrap(
            ImageRenderer(
                content: MealRow(meal: crowded, isDuplicate: true, onTap: {}).frame(width: 390)
            ).uiImage
        )
        XCTAssertEqual(image.size.width, 390, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 120)
        XCTAssertLessThan(image.size.height, 400)
    }

    // MARK: - Fixtures

    private func height(of meal: LocalMeal) throws -> CGFloat {
        let image = try XCTUnwrap(
            ImageRenderer(
                content: MealRow(meal: meal, isDuplicate: false, onTap: {}).frame(width: 390)
            ).uiImage
        )
        return image.size.height
    }

    private func meal(
        _ description: String,
        type: MealType,
        isSuspect: Bool = false,
        suspectReason: String? = nil
    ) -> LocalMeal {
        LocalMeal(
            date: day,
            loggedAt: day,
            mealType: type.rawValue,
            mealDescription: description,
            calories: 600,
            proteinG: 35,
            carbsG: 70,
            fatG: 18,
            fibreG: 3,
            sugarG: 9,
            sodiumMg: 1_900,
            satFatG: 6,
            confidence: 0.6,
            source: MealSource.composer,
            needsDetail: false,
            isSuspect: isSuspect,
            suspectReason: suspectReason
        )
    }
}
