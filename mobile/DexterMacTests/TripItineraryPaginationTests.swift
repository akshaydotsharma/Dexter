import XCTest
@testable import DexterMac

/// Pagination of the trip itinerary report (#532).
///
/// The packing algorithm is shared with the expense report (`ReportPager`), so
/// what needs proving here is the itinerary's own use of it: a stop's height
/// grows with its detail lines, a day that spills onto the next page restates
/// its header, no heading is orphaned, and nothing is dropped or duplicated.
final class TripItineraryPaginationTests: XCTestCase {

    private func stop(_ index: Int, details: Int = 1) -> ItineraryReportBlock {
        .stopRow(
            TripItineraryReport.StopRow(
                id: "stop-\(index)",
                time: "10:35",
                title: "Stop \(index)",
                kind: "Activity",
                icon: "figure.walk",
                details: (0..<details).map { "Detail \($0)" },
                isBooked: false
            )
        )
    }

    /// One heading, one day, and enough stops to run well past a page.
    private func longDay(stops: Int, details: Int = 1) -> [ItineraryReportBlock] {
        var blocks: [ItineraryReportBlock] = [
            .sectionHeader(title: "Day by day", note: TripItineraryReport.timeSentence),
            .dayHeader(title: "Day 1 · Wed, 3 Jun 2026", subtitle: "\(stops) stops", continued: false)
        ]
        blocks.append(contentsOf: (0..<stops).map { stop($0, details: details) })
        return blocks
    }

    private func pages(_ blocks: [ItineraryReportBlock]) -> [[ItineraryReportBlock]] {
        TripItineraryReportPaginator.pack(blocks, pageHeight: ReportPageMetrics.contentHeight)
    }

    // MARK: - Nothing overflows

    func testNoPageIsTallerThanThePage() {
        for page in pages(longDay(stops: 60, details: 3)) {
            let height = page.reduce(0) { $0 + $1.height }
            XCTAssertLessThanOrEqual(height, ReportPageMetrics.contentHeight, "Page overflowed at \(height)")
        }
    }

    func testAShortDayStaysOnOnePage() {
        XCTAssertEqual(pages(longDay(stops: 4)).count, 1)
    }

    func testAStopGrowsWithItsDetailLines() {
        let bare = stop(0, details: 0).height
        let three = stop(0, details: 3).height
        XCTAssertEqual(three - bare, ItineraryReportBlock.detailLineHeight * 3, accuracy: 0.01)
    }

    // MARK: - Every stop survives exactly once

    func testEveryStopIsListedOnceAndInOrder() {
        let titles = pages(longDay(stops: 60))
            .flatMap { $0 }
            .compactMap { block -> String? in
                if case .stopRow(let row) = block { return row.title }
                return nil
            }
        XCTAssertEqual(titles, (0..<60).map { "Stop \($0)" })
    }

    // MARK: - A broken day still says which day it is

    func testADaySpillingOverRestatesItsHeaderAsContinued() {
        let packed = pages(longDay(stops: 60))
        XCTAssertGreaterThan(packed.count, 1)

        for page in packed.dropFirst() {
            guard case .dayHeader(_, _, let continued) = page[0] else {
                return XCTFail("A continuation page must open with its day header, got \(page[0])")
            }
            XCTAssertTrue(continued, "The repeated header must be marked as a continuation")
        }
    }

    // MARK: - No orphans

    func testASectionHeadingIsNeverTheLastThingOnAPage() {
        var blocks = longDay(stops: 22)
        blocks.append(.gap(14))
        blocks.append(.sectionHeader(title: "Stays", note: "Where you sleep, and for how long."))
        blocks.append(.columnHeader(.stays))
        blocks.append(contentsOf: (0..<12).map { index in
            ItineraryReportBlock.stayRow(
                TripItineraryReport.StayRow(
                    id: "stay-\(index)",
                    name: "Hotel \(index)",
                    dates: "3 Jun → 6 Jun",
                    nights: "3 nights",
                    detail: "Via Nazionale 207, Rome"
                )
            )
        })

        for page in pages(blocks) {
            guard let last = page.last else { continue }
            XCTAssertFalse(last.keepsWithNext, "Orphaned heading at the foot of a page: \(last.id)")
        }
    }

    func testAPageNeverOpensWithWhitespace() {
        var blocks = longDay(stops: 26)
        blocks.append(.gap(18))
        blocks.append(contentsOf: (0..<20).map { stop(100 + $0) })

        for page in pages(blocks) {
            XCTAssertFalse(page[0].isGap, "A page opened with a gap")
        }
    }

    // MARK: - Section assembly

    func testTheStaysAndTravelSectionsAreOmittedWhenEmpty() {
        let report = TripItineraryReport(
            cover: TripItineraryReport.Cover(
                tripName: "Italy",
                dateRange: "3 – 7 Jun 2026",
                dayCount: 5,
                stopCount: 0,
                kindCounts: [],
                scopeSentence: "",
                timeSentence: "",
                omissionSentence: nil,
                exportedOn: "14 Sep 2026"
            ),
            days: [],
            stays: [],
            travel: [],
            fileName: "Italy itinerary 2026-09-14.pdf"
        )
        let ids = TripItineraryReportPaginator.blocks(for: report).map(\.id)
        XCTAssertFalse(ids.contains("section-Stays"))
        XCTAssertFalse(ids.contains("section-Travel"))
        XCTAssertTrue(ids.contains("section-Day by day"))
    }
}
