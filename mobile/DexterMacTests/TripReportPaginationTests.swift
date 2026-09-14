import XCTest
@testable import DexterMac

/// Pagination of the trip expense report (#528).
///
/// The unit of packing is the row, so nothing can be cut in half. What still
/// needs proving is the rest: no page overflows, no heading is orphaned at the
/// foot of a page, a day broken across a boundary says so at the top of the
/// next one, and nothing is dropped or duplicated on the way.
final class TripReportPaginationTests: XCTestCase {

    private func ledgerRow(_ index: Int) -> ReportBlock {
        .ledgerRow(
            TripExpenseReport.LedgerRow(
                id: "row-\(index)",
                dateLabel: "3 Jun",
                title: "Expense \(index)",
                category: "Food & Dining",
                amount: "EUR 12.00",
                isRefund: false,
                payer: "You paid",
                split: "Your cost in full"
            )
        )
    }

    /// One heading, one day, and enough rows to run well past a page.
    private func longDay(rows: Int) -> [ReportBlock] {
        var blocks: [ReportBlock] = [
            .sectionHeader(title: "Daily ledger", note: "Every expense on this trip, newest first."),
            .dayHeader(title: "Wed 3 Jun 2026", total: "SGD 240.00", continued: false)
        ]
        blocks.append(contentsOf: (0..<rows).map(ledgerRow))
        return blocks
    }

    private func pages(_ blocks: [ReportBlock]) -> [[ReportBlock]] {
        TripExpenseReportPaginator.pack(blocks, pageHeight: ReportPageMetrics.contentHeight)
    }

    // MARK: - Nothing overflows

    func testNoPageIsTallerThanThePage() {
        for page in pages(longDay(rows: 90)) {
            let height = page.reduce(0) { $0 + $1.height }
            XCTAssertLessThanOrEqual(height, ReportPageMetrics.contentHeight, "Page overflowed at \(height)")
        }
    }

    func testAShortReportStaysOnOnePage() {
        XCTAssertEqual(pages(longDay(rows: 4)).count, 1)
    }

    // MARK: - Every row survives exactly once

    func testEveryRowIsListedOnceAndInOrder() {
        let titles = pages(longDay(rows: 90))
            .flatMap { $0 }
            .compactMap { block -> String? in
                if case .ledgerRow(let row) = block { return row.title }
                return nil
            }
        XCTAssertEqual(titles, (0..<90).map { "Expense \($0)" })
    }

    // MARK: - Continuation headers

    /// A page of ledger rows with no date on it is unreadable on its own, so a
    /// day broken across a boundary restates its heading.
    func testABrokenDayRepeatsItsHeaderMarkedAsContinued() throws {
        let packed = pages(longDay(rows: 90))
        XCTAssertGreaterThan(packed.count, 1)

        for (index, page) in packed.enumerated() where index > 0 {
            let first = try XCTUnwrap(page.first)
            guard case .dayHeader(let title, _, let continued) = first else {
                return XCTFail("Page \(index + 1) opens with \(first) instead of a day header")
            }
            XCTAssertEqual(title, "Wed 3 Jun 2026")
            XCTAssertTrue(continued, "A repeated header must say it is a continuation")
        }
    }

    /// The header is only repeated while a day is still being listed. Once the
    /// ledger ends, later sections must not inherit it.
    func testTheDayHeaderIsNotCarriedIntoALaterSection() {
        var blocks = longDay(rows: 40)
        blocks.append(.gap(14))
        blocks.append(.sectionHeader(title: "Participant breakdown", note: nil))
        blocks.append(.columnHeader(.participants))
        blocks.append(contentsOf: (0..<30).map { index in
            ReportBlock.participantRow(
                TripExpenseReport.ParticipantRow(
                    id: "p\(index)", name: "Person \(index)",
                    paid: 0, spent: 0, net: 0,
                    paidText: "SGD 0.00", spentText: "SGD 0.00", netText: "SGD 0.00"
                )
            )
        })

        let packed = pages(blocks)
        let afterSection = packed
            .flatMap { $0 }
            .drop { block in
                if case .sectionHeader(let title, _) = block { return title != "Participant breakdown" }
                return true
            }
        for block in afterSection {
            if case .dayHeader = block { XCTFail("A day header leaked into the participant table") }
        }
    }

    // MARK: - Orphans

    /// A heading alone at the foot of a page makes the reader turn over to find
    /// out what it introduced.
    func testAHeadingIsNeverTheLastBlockOnAPage() {
        var blocks = longDay(rows: 21)
        blocks.append(.gap(14))
        blocks.append(.sectionHeader(title: "Participant breakdown", note: "Over every expense."))
        blocks.append(.columnHeader(.participants))
        blocks.append(
            .participantRow(
                TripExpenseReport.ParticipantRow(
                    id: "", name: "You", paid: 1, spent: 1, net: 0,
                    paidText: "SGD 1.00", spentText: "SGD 1.00", netText: "SGD 0.00"
                )
            )
        )

        for size in 14...30 {
            var variant = longDay(rows: size)
            variant.append(contentsOf: blocks.suffix(4))
            for page in pages(variant) {
                guard let last = page.last else { continue }
                XCTAssertFalse(last.keepsWithNext, "A \(last.id) was orphaned at the foot of a page")
            }
        }
    }

    // MARK: - Whitespace

    func testAPageNeverOpensWithAGap() {
        var blocks = longDay(rows: 30)
        // A gap lands exactly where the break falls for some row counts; run a
        // spread so at least one of them hits it.
        for size in 20...34 {
            blocks = longDay(rows: size)
            blocks.append(.gap(10))
            blocks.append(.sectionHeader(title: "Category analysis", note: nil))
            blocks.append(.columnHeader(.categories))
            blocks.append(
                .categoryRow(
                    TripExpenseReport.CategoryRow(
                        id: "food", name: "Food & Dining", total: 10, count: 1,
                        share: 1, totalText: "SGD 10.00", shareText: "100%"
                    )
                )
            )
            for page in pages(blocks) {
                XCTAssertFalse(page.first?.isGap ?? false, "A page opened with whitespace at size \(size)")
            }
        }
    }
}
