import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The chip flow's one invariant: it reports the height it will place (#571).
///
/// It used to carry the arithmetic twice, once in `sizeThatFits` and once in
/// `placeSubviews`, wrapping against two different widths. On a suspect meal
/// row the passes ran at 292 pt and at 232 pt, so the layout reported two
/// lines and laid out three, and the nutrient pills were drawn over the third
/// chip.
///
/// What makes this worth a file of its own is that measuring at 390 pt would
/// not have caught it. At the full phone width the chips fit fewer lines and
/// the two passes happened to agree, so the existing row test rendered a clean
/// image of a broken layout. Every case below therefore states a width, and
/// the narrow ones are the point.
final class ChipFlowLayoutTests: XCTestCase {

    private let spacing = Space.xs

    /// Three chips of the rough proportions the row draws: "Check this",
    /// "Possible duplicate" and a confidence band, all one line tall.
    private let threeChips = [
        CGSize(width: 96, height: 21),
        CGSize(width: 148, height: 21),
        CGSize(width: 132, height: 21),
    ]

    private func solve(_ sizes: [CGSize], _ width: CGFloat) -> ChipFlowLayout.Solution {
        ChipFlowLayout.solve(sizes, width: width, spacing: spacing)
    }

    // MARK: - The invariant

    /// What the layout says it needs is what it goes on to use, at every width
    /// worth asking about.
    ///
    /// 232 pt is the width the real bug was placed into and 292 pt is the width
    /// it was measured at, so both are named rather than left to a range.
    func testMeasuredHeightEqualsPlacedHeightAtEveryWidth() {
        let widths: [CGFloat] = [1_000, 420, 390, 292, 260, 232, 200, 150, 96, 40, 1]
        for width in widths {
            let solution = solve(threeChips, width)
            XCTAssertEqual(
                solution.size.height, solution.placedHeight(of: threeChips), accuracy: 0.001,
                "at \(width) pt the flow reserves \(solution.size.height) pt and uses \(solution.placedHeight(of: threeChips)) pt"
            )
        }
    }

    /// The same for an unspecified proposal, which is the one case with no
    /// width to wrap against at all.
    func testMeasuredHeightEqualsPlacedHeightForAnUnspecifiedProposal() {
        let solution = solve(threeChips, .infinity)
        XCTAssertEqual(
            solution.size.height, solution.placedHeight(of: threeChips), accuracy: 0.001
        )
        // And it is one line, because nothing ever crosses an infinite edge.
        XCTAssertTrue(solution.offsets.allSatisfy { $0.y == 0 })
    }

    /// And for a width narrower than a single chip, where every chip takes a
    /// line of its own and each one overflows its line.
    func testMeasuredHeightEqualsPlacedHeightBelowTheWidthOfOneChip() {
        let solution = solve(threeChips, 40)
        XCTAssertEqual(
            solution.size.height, solution.placedHeight(of: threeChips), accuracy: 0.001
        )
        XCTAssertEqual(solution.offsets.map(\.y), [0, 21 + spacing, 2 * (21 + spacing)])
        // Placed, not dropped. Losing a flag is worse than clipping one.
        XCTAssertEqual(solution.offsets.count, threeChips.count)
    }

    // MARK: - The width it claims

    /// The flow reports the width it wrapped against, not the width its longest
    /// line reaches. Reporting the shorter figure is what let the parent hand
    /// back a narrower box than the one the height was measured for.
    func testTheReportedWidthIsTheWidthItWrappedAgainst() {
        for width: CGFloat in [1_000, 390, 292, 232, 96] {
            XCTAssertEqual(solve(threeChips, width).size.width, width, accuracy: 0.001)
        }
    }

    /// Except on an unspecified proposal, where there is no width to claim and
    /// the longest line is the honest answer.
    func testAnUnspecifiedProposalReportsItsLongestLine() {
        let expected = threeChips.map(\.width).reduce(0, +) + spacing * 2
        XCTAssertEqual(solve(threeChips, .infinity).size.width, expected, accuracy: 0.001)
    }

    // MARK: - Nothing moved that already fitted

    /// A row that fits one line is laid out exactly as it was: everything on
    /// the first line, each chip one spacing after the last.
    func testASingleLineRowIsUnchanged() {
        let solution = solve(threeChips, 1_000)
        XCTAssertEqual(solution.offsets.map(\.y), [0, 0, 0])
        XCTAssertEqual(solution.offsets.map(\.x), [
            0,
            96 + spacing,
            96 + spacing + 148 + spacing,
        ])
        XCTAssertEqual(solution.size.height, 21, accuracy: 0.001)
    }

    /// Chips always start at the leading edge of their line, at every width, so
    /// claiming the full proposed width cannot have pushed anything sideways.
    func testEveryLineStartsAtTheLeadingEdge() {
        for width: CGFloat in [1_000, 292, 232, 150, 40] {
            let solution = solve(threeChips, width)
            let firstOfEachLine = Dictionary(grouping: solution.offsets, by: \.y)
                .values
                .compactMap { $0.map(\.x).min() }
            XCTAssertTrue(
                firstOfEachLine.allSatisfy { $0 == 0 },
                "a line does not start at 0 at \(width) pt"
            )
        }
    }

    /// An empty flow is an empty box, not a box one negative spacing wide.
    func testAnEmptyFlowIsZero() {
        XCTAssertEqual(solve([], 390).size, .zero)
        XCTAssertEqual(solve([], .infinity).size, .zero)
    }

    // MARK: - The real chips, at the real widths

    /// The case from the bug, with the sizes the row actually draws rather than
    /// with stand-ins.
    ///
    /// The chip column is what is left of a phone once the row's padding, the
    /// icon gutter and the calorie column are taken off, which is narrower than
    /// the 390 pt the row tests measure at. That difference is the whole
    /// reason the defect survived a test suite and a screenshot.
    @MainActor
    func testTheRealSuspectChipsReserveWhatTheyUseAcrossTheColumnWidths() throws {
        let chips = [
            MealFlagChip("Check this", systemImage: "exclamationmark.triangle", tint: Tokens.danger),
            MealFlagChip("Possible duplicate", systemImage: "doc.on.doc", tint: Tokens.info),
            MealFlagChip("Medium confidence", tint: Tokens.muted),
        ]
        let sizes = try chips.map { chip in
            try XCTUnwrap(ImageRenderer(content: chip).uiImage?.size)
        }

        // Every width from a roomy tablet column down to a squeezed phone one.
        for width in stride(from: CGFloat(400), through: 120, by: -4) {
            let solution = ChipFlowLayout.solve(sizes, width: width, spacing: spacing)
            XCTAssertEqual(
                solution.size.height, solution.placedHeight(of: sizes), accuracy: 0.001,
                "at \(width) pt the flow reserves \(solution.size.height) pt and uses \(solution.placedHeight(of: sizes)) pt"
            )
        }

        // And at 232 pt, the width the row placed into when it broke, the three
        // really do need more than one line. A test that passed here because
        // everything fitted would be pinning nothing.
        let squeezed = ChipFlowLayout.solve(sizes, width: 232, spacing: spacing)
        XCTAssertGreaterThan(squeezed.offsets.map(\.y).max() ?? 0, 0)
    }
}
