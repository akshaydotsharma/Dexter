import CoreGraphics
import Foundation
import SwiftUI

/// Renders a `TripItineraryReport` into a paged PDF (#532).
///
/// Same mechanism as the expense report (#528): SwiftUI page views go through
/// `ImageRenderer` into a single PDF `CGContext`, one `beginPDFPage` per page.
/// The text stays vector text, so the plan is selectable and searchable in any
/// reader — which matters more here than it did for the ledger, because the
/// thing people look for in an itinerary is one line of it.
///
/// `ImageRenderer` is main-actor only, which is why the whole renderer is.
@MainActor
enum TripItineraryReportPDF {

    enum Failure: LocalizedError {
        case contextUnavailable

        var errorDescription: String? {
            switch self {
            case .contextUnavailable: return "Couldn't start the PDF document."
            }
        }
    }

    /// The PDF bytes: a cover page, then the body paginated by
    /// `TripItineraryReportPaginator`.
    static func data(for report: TripItineraryReport) throws -> Data {
        let body = TripItineraryReportPaginator.pages(for: report)
        // The cover is page 1, so the body's page numbers start at 2.
        let pageCount = body.count + 1

        let buffer = NSMutableData()
        guard let consumer = CGDataConsumer(data: buffer) else { throw Failure.contextUnavailable }
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: ReportPageMetrics.width,
            height: ReportPageMetrics.height
        )
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.contextUnavailable
        }

        draw(ItineraryReportCoverPage(cover: report.cover), into: context)

        for (index, blocks) in body.enumerated() {
            draw(
                ItineraryReportContentPage(
                    blocks: blocks,
                    tripName: report.cover.tripName,
                    dateRange: report.cover.dateRange,
                    pageNumber: index + 2,
                    pageCount: pageCount
                ),
                into: context
            )
        }

        context.closePDF()
        return buffer as Data
    }

    /// Writes the report to a temporary file named for the trip, ready to hand
    /// to the share sheet or the save panel.
    static func write(_ report: TripItineraryReport) throws -> URL {
        let data = try data(for: report)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(report.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// One page. The size is pinned rather than proposed-and-hoped: every page
    /// view already frames itself to the media box, and `proposedSize` stops
    /// `ImageRenderer` negotiating a different one.
    private static func draw<Page: View>(_ page: Page, into context: CGContext) {
        let renderer = ImageRenderer(
            content: page
                // The document is read outside Dexter, so it never follows the
                // app's theme, and never the reader's Dynamic Type either — the
                // pagination is computed from fixed heights.
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, .medium)
        )
        renderer.proposedSize = ProposedViewSize(
            width: ReportPageMetrics.width,
            height: ReportPageMetrics.height
        )
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
    }
}
