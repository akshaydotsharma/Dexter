import CoreGraphics
import Foundation
import SwiftUI

/// Renders a `TripExpenseReport` into a paged PDF (#528).
///
/// SwiftUI page views go through `ImageRenderer` into a single PDF
/// `CGContext`, one `beginPDFPage` per page. The text stays vector text, so the
/// export is selectable and searchable in any reader, and the file is a few
/// tens of kilobytes rather than a stack of screenshots.
///
/// `ImageRenderer` is main-actor only, which is why the whole renderer is.
@MainActor
enum TripExpenseReportPDF {

    enum Failure: LocalizedError {
        case contextUnavailable

        var errorDescription: String? {
            switch self {
            case .contextUnavailable: return "Couldn't start the PDF document."
            }
        }
    }

    /// The PDF bytes: a cover page, then the body paginated by
    /// `TripExpenseReportPaginator`.
    static func data(for report: TripExpenseReport) throws -> Data {
        let body = TripExpenseReportPaginator.pages(for: report)
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

        draw(TripReportCoverPage(cover: report.cover), into: context)

        for (index, blocks) in body.enumerated() {
            draw(
                TripReportContentPage(
                    blocks: blocks,
                    tripName: report.cover.tripName,
                    currencyCode: report.reportCurrencyCode,
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
    static func write(_ report: TripExpenseReport) throws -> URL {
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
