import XCTest
@testable import PersonalDashboard

/// How much of a block's list fits inside it (#446).
///
/// Small arithmetic, and the reason it is tested rather than eyeballed is that
/// every way it goes wrong looks like a slightly-off card rather than like a
/// bug: a row clipped by the bottom edge, a `+N more` that lies about the count,
/// content hidden while empty space sits under it. None of those announce
/// themselves, and the only manual check is resizing a block by hand and
/// counting rows — the loop this feature already spent four rounds in.
///
/// Written against the metrics rather than against hardcoded pixel budgets
/// wherever the intent is "exactly N rows fit", so a future change to
/// `tileHeight` moves the tests with the design instead of breaking them.
final class VisionContentFitTests: XCTestCase {

    /// A budget that holds exactly `count` rows and nothing more.
    private func budget(_ count: Int) -> CGFloat {
        VisionContentFit.height(ofRows: count)
    }

    // MARK: - Fitting

    func testABudgetSizedToExactlyThreeRowsShowsThree() {
        let fit = VisionContentFit.fit(budget: budget(3), rows: 3)
        XCTAssertEqual(fit.rows, 3)
        XCTAssertEqual(fit.hidden, 0)
    }

    /// The off-by-one this arithmetic is most likely to have. n rows occupy
    /// `n × height + (n − 1) × spacing`, so a budget that fits three exactly is
    /// one spacing short of being divisible by the unit.
    func testABudgetOneShortOfFourRowsShowsThreeNotTwo() {
        let fit = VisionContentFit.fit(budget: budget(4) - 1, rows: 4)
        XCTAssertEqual(fit.rows, 3)
    }

    func testNoBudgetHidesEverything() {
        let fit = VisionContentFit.fit(budget: 0, rows: 7)
        XCTAssertEqual(fit.rows, 0)
        XCTAssertEqual(fit.hidden, 7)
    }

    /// A block resized down past its own contents. Normal, and must not produce
    /// a negative row count.
    func testANegativeBudgetIsNotACrashOrANegativeCount() {
        let fit = VisionContentFit.fit(budget: -200, rows: 6)
        XCTAssertEqual(fit.rows, 0)
        XCTAssertEqual(fit.hidden, 6)
    }

    func testAnEmptyListFitsWithNothingHidden() {
        let fit = VisionContentFit.fit(budget: budget(3), rows: 0)
        XCTAssertEqual(fit, VisionContentFit.Fit(rows: 0, hidden: 0))
    }

    // MARK: - The `+N more` row

    /// Overflow makes a button appear, and the button occupies space that was
    /// being counted for rows. Failing to charge for it is what clips the last
    /// row off the bottom edge.
    func testOverflowPaysForTheMoreRowOutOfTheSameBudget() {
        let exact = VisionContentFit.fit(budget: budget(3), rows: 3)
        XCTAssertEqual(exact.rows, 3, "precondition: three fit when nothing overflows")

        let overflowing = VisionContentFit.fit(budget: budget(3), rows: 9)
        XCTAssertLessThan(overflowing.rows, 3)
        XCTAssertEqual(overflowing.rows + overflowing.hidden, 9, "every row is accounted for")
    }

    // MARK: - Tier ceiling

    /// Medium shows at most three rows however tall it is, so a 2 × 8 block is
    /// not three hundred lines of text.
    func testTheMediumCeilingCapsRowsRegardlessOfSpace() {
        let fit = VisionContentFit.fit(budget: 2000, rows: 20, ceiling: 3)
        XCTAssertEqual(fit.rows, 3)
        XCTAssertEqual(fit.hidden, 17)
    }

    func testACeilingedBlockWithNothingHiddenShowsNoMoreRow() {
        let fit = VisionContentFit.fit(budget: 2000, rows: 3, ceiling: 3)
        XCTAssertEqual(fit.rows, 3)
        XCTAssertEqual(fit.hidden, 0)
    }

    // MARK: - Invariants

    /// The one property that must hold for every input: the card never claims to
    /// show more rows than exist, and never loses one.
    func testShownPlusHiddenAlwaysEqualsTheTotal() {
        for budget in stride(from: CGFloat(-50), through: 400, by: 7) {
            for rows in 0...12 {
                for ceiling in [3, Int.max] {
                    let fit = VisionContentFit.fit(budget: budget, rows: rows, ceiling: ceiling)
                    XCTAssertEqual(
                        fit.rows + fit.hidden, rows,
                        "budget \(budget), \(rows) rows, ceiling \(ceiling)"
                    )
                    XCTAssertLessThanOrEqual(fit.rows, rows)
                    XCTAssertGreaterThanOrEqual(fit.rows, 0)
                }
            }
        }
    }

    /// Growing a block never shows fewer rows than it did when it was smaller.
    /// Monotonicity is what makes a resize feel like a resize; without it a card
    /// would drop a row halfway through being dragged bigger.
    func testGrowingABlockNeverRemovesARowThatWasVisible() {
        for rows in 0...10 {
            var previous = VisionContentFit.fit(budget: 0, rows: rows)
            for budget in stride(from: CGFloat(0), through: 400, by: 3) {
                let fit = VisionContentFit.fit(budget: budget, rows: rows)
                XCTAssertGreaterThanOrEqual(
                    fit.rows, previous.rows,
                    "budget \(budget) showed fewer rows than \(budget - 3) with \(rows) rows"
                )
                previous = fit
            }
        }
    }

    /// Adding a row to the list never REMOVES one that was already on screen,
    /// except by summoning the `+N more` button — and then by at most one.
    ///
    /// The guard against a naive re-fit that recounts from scratch and shrinks
    /// the list by more than the button costs, which would look like the block
    /// throwing away rows because you added one.
    func testAddingARowCostsAtMostOneVisibleRow() {
        for budget in stride(from: CGFloat(0), through: 400, by: 5) {
            for rows in 0...11 {
                let before = VisionContentFit.fit(budget: budget, rows: rows)
                let after = VisionContentFit.fit(budget: budget, rows: rows + 1)
                XCTAssertGreaterThanOrEqual(
                    after.rows, before.rows - 1,
                    "budget \(budget): \(rows) rows showed \(before.rows), \(rows + 1) showed \(after.rows)"
                )
            }
        }
    }
}
