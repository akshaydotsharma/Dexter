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

    /// The user's rule, on the raw arithmetic: one row's worth of space left
    /// means one more row on the card, not a `+N more` above it.
    func testOneRowOfSpareSpaceShowsOneMoreRowRatherThanAMoreButton() {
        let tight = VisionContentFit.fit(budget: budget(3), rows: 4)
        XCTAssertGreaterThan(tight.hidden, 0, "precondition: four rows do not fit in three")

        let roomier = VisionContentFit.fit(budget: budget(4), rows: 4)
        XCTAssertEqual(roomier.rows, 4)
        XCTAssertEqual(roomier.hidden, 0)
    }

    // MARK: - A whole block

    /// These go through `fit(for:rows:)` — the budget AND the division — because
    /// that seam is where the reported defect actually was.
    ///
    /// The budget lived in `VisionBlockCard` as a private computed property and
    /// capped medium blocks at three rows regardless of height. Every test above
    /// stayed green through it: the pure arithmetic was right, and the card
    /// handed it a number that was not. Moving the whole calculation here is what
    /// makes the following assertable at all.
    private func block(w: Int, h: Int, intent: String? = nil) -> VisionBlock {
        VisionBlock(
            id: UUID(),
            title: "Renovate the kitchen",
            intent: intent,
            col: 0, row: 0, w: w, h: h,
            state: .active,
            members: [],
            items: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Reported 2026-08-07, with a screenshot: a block showing two items, a
    /// blank third, `+2 more`, and then half a card of empty space beneath it.
    ///
    /// 6 × 5 cells is 396 × 328pt — the medium tier, and the block in that
    /// screenshot. Five rows fit in it with room to spare, so five rows show.
    func testTheReportedBlockShowsEveryRowRatherThanTwoMore() {
        let fit = VisionContentFit.fit(for: block(w: 6, h: 5), rows: 5)
        XCTAssertEqual(fit.rows, 5)
        XCTAssertEqual(fit.hidden, 0, "no `+N more` while the card has visible space")
    }

    /// The same block, filled past its height. Now the button is honest.
    func testAMediumBlockOverflowsOnlyWhenItActuallyRunsOutOfHeight() {
        let fit = VisionContentFit.fit(for: block(w: 6, h: 5), rows: 30)
        XCTAssertGreaterThan(fit.hidden, 0)
        XCTAssertEqual(fit.rows + fit.hidden, 30)
    }

    /// Growing a block downward shows more of it. The cap made this false — a
    /// medium block stopped gaining rows after three however far it was dragged,
    /// which is the resize silently doing nothing.
    func testMakingAMediumBlockTallerShowsMoreOfIt() {
        let short = VisionContentFit.fit(for: block(w: 6, h: 3), rows: 12)
        let tall = VisionContentFit.fit(for: block(w: 6, h: 8), rows: 12)
        XCTAssertGreaterThan(tall.rows, short.rows)
        XCTAssertGreaterThan(tall.rows, 3, "the old ceiling would have stopped here")
    }

    /// An intent line is real height and comes out of the same budget, so a
    /// block carrying one shows no more rows than the identical block without.
    func testAnIntentLineIsPaidForOutOfTheRows() {
        let bare = VisionContentFit.fit(for: block(w: 6, h: 5), rows: 12)
        let stated = VisionContentFit.fit(
            for: block(w: 6, h: 5, intent: "Finish before the winter"), rows: 12
        )
        XCTAssertLessThanOrEqual(stated.rows, bare.rows)
    }

    /// Small lists nothing at all, and that tier IS the anti-wall-of-text guard
    /// now that medium has no hidden cap. A whole tier of presentation is
    /// visible in a way a subtracted three never was.
    func testASmallBlockListsNothing() {
        let fit = VisionContentFit.fit(for: block(w: 3, h: 4), rows: 9)
        XCTAssertEqual(fit.rows, 0)
        XCTAssertEqual(fit.hidden, 0, "and shows no `+N more`, because it draws no stack")
    }

    /// Whatever a block shows, it fits. The guard against the budget drifting
    /// out from under the arithmetic: rows are 26pt on a card whose interior is
    /// its height less the rail, the padding, the title, the meta line, the gap
    /// and the add row.
    func testWhatABlockShowsAlwaysFitsInsideIt() {
        for w in [3, 5, 6, 8, 10] {
            for h in 2...10 {
                let subject = block(w: w, h: h)
                let fit = VisionContentFit.fit(for: subject, rows: 40)
                let interior = VisionGrid.blockSize(columns: w, rows: h).height
                XCTAssertLessThan(
                    VisionContentFit.height(ofRows: fit.rows), interior,
                    "\(w) × \(h) showed \(fit.rows) rows"
                )
            }
        }
    }

    // MARK: - Invariants

    /// The one property that must hold for every input: the card never claims to
    /// show more rows than exist, and never loses one.
    func testShownPlusHiddenAlwaysEqualsTheTotal() {
        for budget in stride(from: CGFloat(-50), through: 400, by: 7) {
            for rows in 0...12 {
                let fit = VisionContentFit.fit(budget: budget, rows: rows)
                XCTAssertEqual(fit.rows + fit.hidden, rows, "budget \(budget), \(rows) rows")
                XCTAssertLessThanOrEqual(fit.rows, rows)
                XCTAssertGreaterThanOrEqual(fit.rows, 0)
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
