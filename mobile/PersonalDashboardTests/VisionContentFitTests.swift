import XCTest
@testable import PersonalDashboard

/// How a block divides its height between its notes and its tiles (#446).
///
/// Small arithmetic, and the reason it is tested rather than eyeballed is that
/// every way it goes wrong looks like a slightly-off card rather than like a
/// bug: a row clipped by the bottom edge, a `+N more` that lies about the count,
/// empty space under content that was hidden anyway. None of those announce
/// themselves, and the only manual check is resizing a block by hand and
/// counting rows — the loop this feature already spent four rounds in.
///
/// Written against the metrics rather than against hardcoded pixel budgets
/// wherever the intent is "exactly N rows fit", so a future change to
/// `noteRow` or `tileHeight` moves the tests with the design instead of
/// breaking them.
final class VisionContentFitTests: XCTestCase {

    // MARK: - Helpers

    /// A budget that holds exactly `count` tiles and nothing more.
    private func tileBudget(_ count: Int) -> CGFloat {
        CGFloat(count) * VisionBlockMetrics.tileHeight
            + CGFloat(max(0, count - 1)) * VisionBlockMetrics.tileSpacing
    }

    /// A budget that holds exactly `count` notes and nothing more.
    private func noteBudget(_ count: Int) -> CGFloat {
        VisionContentFit.height(ofNotes: count)
    }

    // MARK: - Tiles alone

    func testABudgetSizedToExactlyThreeTilesShowsThree() {
        let fit = VisionContentFit.fit(budget: tileBudget(3), notes: 0, tiles: 3)
        XCTAssertEqual(fit.tiles, 3)
        XCTAssertEqual(fit.hidden, 0)
    }

    /// The off-by-one this arithmetic is most likely to have. n rows occupy
    /// `n × height + (n − 1) × spacing`, so a budget that fits three exactly is
    /// one spacing short of being divisible by the unit.
    func testABudgetOneShortOfFourTilesShowsThreeNotTwo() {
        let budget = tileBudget(4) - 1
        let fit = VisionContentFit.fit(budget: budget, notes: 0, tiles: 4)
        XCTAssertEqual(fit.tiles, 3)
    }

    func testNoBudgetHidesEverything() {
        let fit = VisionContentFit.fit(budget: 0, notes: 2, tiles: 5)
        XCTAssertEqual(fit.notes, 0)
        XCTAssertEqual(fit.tiles, 0)
        XCTAssertEqual(fit.hidden, 7)
    }

    /// A block resized down past its own contents. Normal, and must not produce
    /// a negative row count.
    func testANegativeBudgetIsNotACrashOrANegativeCount() {
        let fit = VisionContentFit.fit(budget: -200, notes: 3, tiles: 3)
        XCTAssertEqual(fit.notes, 0)
        XCTAssertEqual(fit.tiles, 0)
        XCTAssertEqual(fit.hidden, 6)
    }

    // MARK: - The `+N more` row

    /// Overflow makes a button appear, and the button occupies space that was
    /// being counted for tiles. Failing to charge for it is what clips the row
    /// off the bottom edge.
    func testOverflowPaysForTheMoreRowOutOfTheSameBudget() {
        let budget = tileBudget(3)
        let exact = VisionContentFit.fit(budget: budget, notes: 0, tiles: 3)
        XCTAssertEqual(exact.tiles, 3, "precondition: three fit when nothing overflows")

        let overflowing = VisionContentFit.fit(budget: budget, notes: 0, tiles: 9)
        XCTAssertLessThan(overflowing.tiles, 3)
        XCTAssertEqual(overflowing.tiles + overflowing.hidden, 9, "every task is accounted for")
    }

    func testHiddenCountsNotesAndTilesTogether() {
        // Room for one note and nothing else.
        let fit = VisionContentFit.fit(budget: noteBudget(1), notes: 3, tiles: 4)
        XCTAssertEqual(fit.notes, 1)
        XCTAssertEqual(fit.tiles, 0)
        XCTAssertEqual(fit.hidden, 6, "2 notes + 4 tiles")
    }

    // MARK: - Notes take precedence

    /// Notes exist only on the board; a hidden task can still be found in Tasks.
    /// So when the two compete, the notes win.
    ///
    /// Sized to hold both exactly, and nothing overflows — which matters,
    /// because an overflow would summon the `+N more` row and the tile's space
    /// would go to that instead. That is correct behaviour and it is the next
    /// test; it just is not this one.
    func testNotesGetFirstClaimOnTheBudget() {
        let budget = noteBudget(2) + VisionBlockMetrics.tileSpacing + tileBudget(1)
        let fit = VisionContentFit.fit(budget: budget, notes: 2, tiles: 1)
        XCTAssertEqual(fit.notes, 2)
        XCTAssertEqual(fit.tiles, 1, "the leftover still holds a tile")
        XCTAssertEqual(fit.hidden, 0)
    }

    /// The same budget, one more task than fits. The `+N more` row now has to be
    /// drawn, and it costs more than the single tile that was going to fit — so
    /// the honest answer is to show the button and no tiles rather than a tile
    /// that would render past the card's bottom edge.
    func testAnOverflowingBlockGivesTheLeftoverToTheMoreRowNotToATile() {
        let budget = noteBudget(2) + VisionBlockMetrics.tileSpacing + tileBudget(1)
        let fit = VisionContentFit.fit(budget: budget, notes: 2, tiles: 4)
        XCTAssertEqual(fit.notes, 2, "notes still keep their claim")
        XCTAssertEqual(fit.tiles, 0)
        XCTAssertEqual(fit.hidden, 4)
    }

    /// Competition proper: room for three rows of either kind, and three of
    /// each asking for it. All three go to the notes.
    func testWhenBothCompeteForTheSameRowsTheNotesTakeThem() {
        let fit = VisionContentFit.fit(budget: noteBudget(3), notes: 3, tiles: 3)
        XCTAssertEqual(fit.notes, 3)
        XCTAssertEqual(fit.tiles, 0)
    }

    /// Four is the ceiling regardless of height, so a tall block does not turn
    /// into a wall of notes with its tasks pushed off the card.
    func testNotesAreCappedEvenWhenThereIsRoomForMore() {
        let fit = VisionContentFit.fit(budget: 2000, notes: 12, tiles: 0)
        XCTAssertEqual(fit.notes, VisionBlockMetrics.maxInlineNotes)
        XCTAssertEqual(fit.hidden, 12 - VisionBlockMetrics.maxInlineNotes)
    }

    /// The gap between the two groups is charged only when both are on screen.
    /// Charging it on a notes-only block would cost a row of nothing.
    func testTheGroupSeparatorIsNotChargedWhenThereAreNoTiles() {
        let budget = noteBudget(3)
        let fit = VisionContentFit.fit(budget: budget, notes: 3, tiles: 0)
        XCTAssertEqual(fit.notes, 3)
        XCTAssertEqual(fit.hidden, 0)
    }

    // MARK: - Tier ceiling

    /// Medium shows at most three tiles however tall it is, so a 2 × 8 block is
    /// not three hundred lines of task text. The ceiling must not touch notes.
    func testTheMediumCeilingCapsTilesAndNotNotes() {
        let fit = VisionContentFit.fit(budget: 2000, notes: 4, tiles: 20, tileCeiling: 3)
        XCTAssertEqual(fit.tiles, 3)
        XCTAssertEqual(fit.notes, 4)
        XCTAssertEqual(fit.hidden, 17)
    }

    func testACeilingedBlockWithNothingHiddenShowsNoMoreRow() {
        let fit = VisionContentFit.fit(budget: 2000, notes: 0, tiles: 3, tileCeiling: 3)
        XCTAssertEqual(fit.tiles, 3)
        XCTAssertEqual(fit.hidden, 0)
    }

    // MARK: - Invariants

    /// The one property that must hold for every input: the card never claims to
    /// show more rows than exist, and never loses one.
    func testShownPlusHiddenAlwaysEqualsTheTotal() {
        for budget in stride(from: CGFloat(-50), through: 400, by: 7) {
            for notes in 0...6 {
                for tiles in 0...8 {
                    for ceiling in [3, Int.max] {
                        let fit = VisionContentFit.fit(
                            budget: budget, notes: notes, tiles: tiles, tileCeiling: ceiling
                        )
                        XCTAssertEqual(
                            fit.notes + fit.tiles + fit.hidden,
                            notes + tiles,
                            "budget \(budget), \(notes) notes, \(tiles) tiles, ceiling \(ceiling)"
                        )
                        XCTAssertLessThanOrEqual(fit.notes, notes)
                        XCTAssertLessThanOrEqual(fit.tiles, tiles)
                        XCTAssertGreaterThanOrEqual(fit.notes, 0)
                        XCTAssertGreaterThanOrEqual(fit.tiles, 0)
                    }
                }
            }
        }
    }

    /// Growing a block never shows fewer rows than it did when it was smaller.
    /// Monotonicity is what makes a resize feel like a resize; without it a card
    /// would drop a row halfway through being dragged bigger.
    func testGrowingABlockNeverRemovesARowThatWasVisible() {
        for notes in 0...5 {
            for tiles in 0...6 {
                var previous = VisionContentFit.fit(budget: 0, notes: notes, tiles: tiles)
                for budget in stride(from: CGFloat(0), through: 400, by: 3) {
                    let fit = VisionContentFit.fit(budget: budget, notes: notes, tiles: tiles)
                    XCTAssertGreaterThanOrEqual(
                        fit.notes + fit.tiles,
                        previous.notes + previous.tiles,
                        "budget \(budget) showed fewer rows than \(budget - 3) with \(notes)/\(tiles)"
                    )
                    previous = fit
                }
            }
        }
    }
}
