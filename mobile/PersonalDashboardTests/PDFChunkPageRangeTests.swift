import XCTest
import PDFKit
@testable import PersonalDashboard

/// What a chunk knows about where it came from (#637).
///
/// `PDFChunker.split` used to return bare `Data`, so a chunk that ran out of
/// output budget could only be reported as "some transactions may be missing".
/// Carrying the page range turns that into "pages 7 to 9 were only partly
/// read", and gives the self-healing re-split something to halve.
final class PDFChunkPageRangeTests: XCTestCase {

    /// Build a PDF with `pageCount` pages, each carrying its own line of text,
    /// so a chunk's pages can be read back and identified.
    private func makePDF(pageCount: Int) -> Data {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            return Data()
        }
        for page in 1...pageCount {
            ctx.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributed = NSAttributedString(
                string: "Page \(page)",
                attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 60, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: - split

    /// Every chunk names the pages it covers, in 1-based numbers, with no gap
    /// and no overlap across the whole file.
    func testSplitTagsEveryChunkWithItsPageRange() throws {
        let pdf = makePDF(pageCount: 10)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let chunks = PDFChunker.split(pdf, pagesPerChunk: 3)

        XCTAssertEqual(chunks.map(\.pages), [
            PDFPageRange(first: 1, last: 3),
            PDFPageRange(first: 4, last: 6),
            PDFPageRange(first: 7, last: 9),
            PDFPageRange(first: 10, last: 10)
        ])
        // Each chunk's bytes really do hold the pages it claims.
        for chunk in chunks {
            XCTAssertEqual(PDFDocument(data: chunk.data)?.pageCount, chunk.pages.pageCount)
        }
    }

    /// A statement that fits in one chunk sends the SAME bytes it always did,
    /// so the common path is untouched, and still reports its true page span.
    func testASmallStatementIsOneChunkOfTheOriginalBytes() throws {
        let pdf = makePDF(pageCount: 2)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let chunks = PDFChunker.split(pdf, pagesPerChunk: 3)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].data, pdf, "the small-statement path must not re-encode the PDF")
        XCTAssertEqual(chunks[0].pages, PDFPageRange(first: 1, last: 2))
    }

    /// Bytes PDFKit cannot parse still go to the model (it may read them), and
    /// still produce exactly one chunk rather than an empty import.
    func testUnparseableBytesStillProduceOneChunk() {
        let chunks = PDFChunker.split(Data("not a pdf".utf8))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].data, Data("not a pdf".utf8))
    }

    // MARK: - halves

    /// The re-split cuts a chunk down the middle and keeps ABSOLUTE page
    /// numbers, so a warning raised inside the recursion still names pages of
    /// the file the user picked.
    func testHalvesKeepAbsolutePageNumbers() throws {
        let pdf = makePDF(pageCount: 9)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let chunks = PDFChunker.split(pdf, pagesPerChunk: 3)
        let third = try XCTUnwrap(chunks.last)
        XCTAssertEqual(third.pages, PDFPageRange(first: 7, last: 9))

        let halves = try XCTUnwrap(PDFChunker.halves(of: third))

        XCTAssertEqual(halves.map(\.pages), [
            PDFPageRange(first: 7, last: 7),
            PDFPageRange(first: 8, last: 9)
        ])
        XCTAssertEqual(PDFDocument(data: halves[0].data)?.pageCount, 1)
        XCTAssertEqual(PDFDocument(data: halves[1].data)?.pageCount, 2)
    }

    /// Halving twice reaches single pages, which is where the recursion has to
    /// stop.
    func testHalvingTwiceReachesSinglePages() throws {
        let pdf = makePDF(pageCount: 4)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let whole = PDFChunk(data: pdf, pages: PDFPageRange(first: 1, last: 4))
        let halves = try XCTUnwrap(PDFChunker.halves(of: whole))
        XCTAssertEqual(halves.map(\.pages), [
            PDFPageRange(first: 1, last: 2),
            PDFPageRange(first: 3, last: 4)
        ])

        let quarters = try XCTUnwrap(PDFChunker.halves(of: halves[1]))
        XCTAssertEqual(quarters.map(\.pages), [
            PDFPageRange(first: 3, last: 3),
            PDFPageRange(first: 4, last: 4)
        ])
    }

    /// A single page cannot be halved. This is the stop condition that makes
    /// the fallback warning reachable rather than the recursion looping.
    func testASinglePageCannotBeHalved() throws {
        let pdf = makePDF(pageCount: 1)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let one = PDFChunk(data: pdf, pages: PDFPageRange(first: 5, last: 5))
        XCTAssertNil(PDFChunker.halves(of: one))
    }

    /// Bytes that cannot be re-parsed are the other stop condition.
    func testUnparseableBytesCannotBeHalved() {
        let junk = PDFChunk(data: Data("not a pdf".utf8), pages: PDFPageRange(first: 1, last: 3))
        XCTAssertNil(PDFChunker.halves(of: junk))
    }

    // MARK: - The range's own wording

    /// The label is a sentence fragment, and it is what the user reads.
    func testTheRangeLabelReadsAsAPhrase() {
        XCTAssertEqual(PDFPageRange(first: 7, last: 9).label, "pages 7 to 9")
        XCTAssertEqual(PDFPageRange(first: 4, last: 4).label, "page 4")
        XCTAssertEqual(PDFPageRange(first: 7, last: 9).pageCount, 3)
        // Reversed bounds are normalised rather than producing "pages 9 to 7".
        XCTAssertEqual(PDFPageRange(first: 9, last: 7).label, "pages 7 to 9")
    }
}
