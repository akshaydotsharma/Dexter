import Foundation
import PDFKit

/// A 1-based, inclusive page range inside the ORIGINAL statement PDF (#637).
///
/// Carried alongside every chunk so a truncation can be reported as the pages
/// it affected ("pages 7 to 9 were only partly read") rather than as an
/// anonymous "some transactions may be missing". Absolute page numbers, never
/// page numbers inside a chunk: a re-split half is still described by where it
/// sits in the file the user picked.
struct PDFPageRange: Sendable, Equatable, Hashable {
    let first: Int
    let last: Int

    init(first: Int, last: Int) {
        self.first = min(first, last)
        self.last = max(first, last)
    }

    /// How many pages the range covers. 1 means the range can no longer be
    /// halved, which is where the re-split recursion stops.
    var pageCount: Int { last - first + 1 }

    /// Lower-case fragment for a sentence: "page 7" or "pages 7 to 9".
    var label: String {
        first == last ? "page \(first)" : "pages \(first) to \(last)"
    }
}

/// One page-range chunk of a statement, as standalone PDF bytes plus the pages
/// those bytes came from.
struct PDFChunk: Sendable, Equatable {
    let data: Data
    let pages: PDFPageRange
}

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
    /// the native `document` extraction block, tagged with the page range it
    /// covers (#637).
    ///
    /// Returns the whole document as ONE chunk when the PDF can't be parsed,
    /// has no pages, or already fits within a single chunk — so a small
    /// statement sends the exact same request bytes as before (zero behaviour
    /// change on the common path). Never returns an empty array.
    static func split(_ pdfData: Data, pagesPerChunk: Int = defaultPagesPerChunk) -> [PDFChunk] {
        guard pagesPerChunk > 0,
              let doc = PDFDocument(data: pdfData) else {
            // Unparseable here does not mean unreadable by the model, so send
            // the bytes on. One page is the only honest range we can claim.
            return [PDFChunk(data: pdfData, pages: PDFPageRange(first: 1, last: 1))]
        }
        let pageCount = doc.pageCount
        guard pageCount > pagesPerChunk else {
            // Small statement (or single chunk's worth): send as-is, untouched.
            return [PDFChunk(data: pdfData, pages: PDFPageRange(first: 1, last: max(pageCount, 1)))]
        }

        var chunks: [PDFChunk] = []
        var start = 0
        while start < pageCount {
            let end = min(start + pagesPerChunk, pageCount)
            if let data = document(from: doc, pages: start..<end) {
                chunks.append(PDFChunk(
                    data: data,
                    pages: PDFPageRange(first: start + 1, last: end)
                ))
            }
            start = end
        }

        // Defensive: if page copying somehow produced nothing, fall back to the
        // original bytes as a single chunk rather than importing zero rows.
        guard !chunks.isEmpty else {
            return [PDFChunk(data: pdfData, pages: PDFPageRange(first: 1, last: pageCount))]
        }
        return chunks
    }

    /// Cut one chunk into two halves of its own page range (#637).
    ///
    /// Used when a chunk came back `stop_reason == "max_tokens"`: reading its
    /// two halves separately gives each half the whole output budget, which is
    /// what makes the truncation recoverable instead of a silent row loss.
    ///
    /// Returns nil when the chunk is a single page (nothing left to halve, so
    /// the recursion must stop and the warning stands) or when the chunk's
    /// bytes can't be re-parsed. The halves carry ABSOLUTE page numbers, taken
    /// from `chunk.pages.first`, so a warning raised three levels deep still
    /// names pages of the file the user picked.
    static func halves(of chunk: PDFChunk) -> [PDFChunk]? {
        guard chunk.pages.pageCount > 1,
              let doc = PDFDocument(data: chunk.data),
              doc.pageCount > 1 else { return nil }

        // Trust the parsed document over the declared range: they agree on
        // every real chunk, and if they ever disagree the page indices we can
        // actually copy are the ones that exist.
        let localCount = doc.pageCount
        let mid = localCount / 2
        let spans = [0..<mid, mid..<localCount]

        var halves: [PDFChunk] = []
        for span in spans {
            guard !span.isEmpty, let data = document(from: doc, pages: span) else { return nil }
            halves.append(PDFChunk(
                data: data,
                pages: PDFPageRange(
                    first: chunk.pages.first + span.lowerBound,
                    last: chunk.pages.first + span.upperBound - 1
                )
            ))
        }
        return halves.count == 2 ? halves : nil
    }

    /// Copy a half-open page span out of `doc` into a standalone PDF's bytes.
    /// A `PDFPage` belongs to exactly one document, so each page is COPIED
    /// before insertion rather than moved out of the source (which would
    /// corrupt every later chunk).
    private static func document(from doc: PDFDocument, pages: Range<Int>) -> Data? {
        let out = PDFDocument()
        var insertIndex = 0
        for pageIndex in pages {
            guard let page = doc.page(at: pageIndex),
                  let copy = page.copy() as? PDFPage else { continue }
            out.insert(copy, at: insertIndex)
            insertIndex += 1
        }
        guard insertIndex > 0 else { return nil }
        return out.dataRepresentation()
    }
}
