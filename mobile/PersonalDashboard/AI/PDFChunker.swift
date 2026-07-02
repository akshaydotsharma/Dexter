import Foundation
import PDFKit

/// Splits a statement PDF into page-range chunks so each extraction call stays
/// well under the model's output-token ceiling (#202).
///
/// A long statement sent as ONE request truncates: the model runs out of
/// output budget partway through the transaction list and the tail rows are
/// silently dropped (a real 9-page Amex imported 111 of ~187 lines). Chunking
/// the input by page range and extracting each chunk sequentially makes import
/// length-independent — each chunk carries few enough lines that it never hits
/// the ceiling, and the merged results flow through the existing dedup so any
/// page-boundary overlap collapses cleanly.
enum PDFChunker {
    /// Default pages per chunk. A typical credit-card statement carries roughly
    /// 25-30 transaction lines per page, so 3 pages ≈ 80 lines ≈ 5-6k output
    /// tokens — comfortably under the 16k ceiling with headroom for the JSON
    /// envelope and header object.
    static let defaultPagesPerChunk = 3

    /// Split `pdfData` into chunks of at most `pagesPerChunk` pages each, every
    /// chunk returned as a standalone single-document PDF's `Data` ready to feed
    /// the native `document` extraction block.
    ///
    /// Returns `[pdfData]` unchanged when the PDF can't be parsed, has no pages,
    /// or already fits within a single chunk — so a small statement sends the
    /// exact same request bytes as before (zero behaviour change on the common
    /// path). Never returns an empty array.
    static func split(_ pdfData: Data, pagesPerChunk: Int = defaultPagesPerChunk) -> [Data] {
        guard pagesPerChunk > 0,
              let doc = PDFDocument(data: pdfData) else {
            return [pdfData]
        }
        let pageCount = doc.pageCount
        guard pageCount > pagesPerChunk else {
            // Small statement (or single chunk's worth): send as-is, untouched.
            return [pdfData]
        }

        var chunks: [Data] = []
        var start = 0
        while start < pageCount {
            let end = min(start + pagesPerChunk, pageCount)
            let chunkDoc = PDFDocument()
            var insertIndex = 0
            for pageIndex in start..<end {
                // A PDFPage belongs to exactly one document, so copy it before
                // inserting into the chunk document rather than moving it out of
                // the source (which would corrupt later chunks).
                guard let page = doc.page(at: pageIndex),
                      let copy = page.copy() as? PDFPage else { continue }
                chunkDoc.insert(copy, at: insertIndex)
                insertIndex += 1
            }
            if insertIndex > 0, let data = chunkDoc.dataRepresentation() {
                chunks.append(data)
            }
            start = end
        }

        // Defensive: if page copying somehow produced nothing, fall back to the
        // original bytes as a single chunk rather than importing zero rows.
        return chunks.isEmpty ? [pdfData] : chunks
    }
}
