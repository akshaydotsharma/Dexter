import XCTest
@testable import PersonalDashboard

/// What an interrupted statement import keeps, and what it tells the user
/// (#635).
///
/// The defect: `extractStatement` split a statement into 3-page chunks and
/// called `extractStatementChunk` with no `catch`, so ONE failed chunk threw
/// straight out of the whole function and every chunk already read was
/// discarded. In the field the phone locked mid-import, iOS suspended the app,
/// the in-flight request died, and a run that had already paid for seven
/// extractions imported zero rows.
///
/// These drive the chunk loop through `AnthropicClient.runStatementChunks`,
/// which takes the per-chunk extractor as a closure precisely so the loop can
/// be exercised without a live Anthropic call.
@MainActor
final class StatementPartialImportTests: XCTestCase {

    // MARK: - Fixtures

    /// `count` chunks of three pages each, so chunk 0 is pages 1 to 3, chunk 1
    /// is pages 4 to 6, and so on. The page ranges are what a truncation is
    /// reported by since #637, so the fixtures have to carry them.
    private func chunks(_ count: Int) -> [PDFChunk] {
        (0..<count).map {
            PDFChunk(
                data: Data("chunk-\($0)".utf8),
                pages: PDFPageRange(first: $0 * 3 + 1, last: $0 * 3 + 3)
            )
        }
    }

    /// One line per chunk, named after the chunk, so an assertion on the merged
    /// output says exactly WHICH chunks survived rather than only how many.
    private func line(forChunk index: Int) -> ExtractedStatementLine {
        ExtractedStatementLine(
            merchant: "Merchant \(index)",
            date: "2026-05-0\(index + 1)",
            amount: Double(index + 1),
            currency: "SGD",
            type: .purchase,
            category: "food_and_dining"
        )
    }

    private let emptyMeta = ExtractedStatementMeta(issuer: nil, last4: nil, statementMonth: nil, statementYear: nil)
    private let citiMeta = ExtractedStatementMeta(issuer: "Citi", last4: "1234", statementMonth: 5, statementYear: 2026)

    private struct ChunkFailure: Error {}

    /// An extractor that yields one line per chunk and throws on `failingAt`.
    /// `seen` records which chunk indices were actually requested, which is how
    /// the resume tests prove chunks were SKIPPED rather than silently re-read.
    private func extractor(
        failingAt: Int? = nil,
        meta: @escaping (Int) -> ExtractedStatementMeta,
        seen: Seen
    ) -> (PDFChunk) async throws -> StatementChunkResult {
        return { chunk in
            let index = Int(String(decoding: chunk.data, as: UTF8.self).dropFirst("chunk-".count)) ?? -1
            seen.record(index)
            if index == failingAt { throw ChunkFailure() }
            return (lines: [self.line(forChunk: index)], meta: meta(index), possiblyTruncated: false)
        }
    }

    /// Reference box so the non-escaping extractor closure can report back.
    private final class Seen: @unchecked Sendable {
        private(set) var indices: [Int] = []
        func record(_ index: Int) { indices.append(index) }
    }

    // MARK: - The core requirement

    /// The whole point of the ticket. Three chunks read, the fourth dies: the
    /// three are returned, flagged `.interrupted`, instead of the run throwing
    /// and discarding them.
    func testAFailedChunkKeepsEverythingReadBeforeIt() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            extractChunk: extractor(failingAt: 3, meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(extraction.lines.count, 3, "the three chunks read before the failure must survive")
        XCTAssertEqual(extraction.lines.map(\.merchant), ["Merchant 0", "Merchant 1", "Merchant 2"])
        XCTAssertEqual(extraction.stopReason?.failure?.kind, .unreadable)
        XCTAssertEqual(extraction.chunksCompleted, 3)
        XCTAssertEqual(extraction.chunksTotal, 5)
        // It stopped at the failure rather than grinding through the rest.
        XCTAssertEqual(seen.indices, [0, 1, 2, 3])
    }

    /// The one case that must still throw. Nothing was read, so there is
    /// nothing to salvage, and a silent "imported 0" would hide a real,
    /// actionable error (a bad key, an unreadable PDF).
    func testAFailureOnTheFirstChunkStillThrows() async {
        let seen = Seen()
        do {
            _ = try await AnthropicClient.runStatementChunks(
                chunks: chunks(5),
                wholePDF: Data(),
                extractChunk: extractor(failingAt: 0, meta: { _ in self.emptyMeta }, seen: seen)
            )
            XCTFail("a first-chunk failure must surface the real error, not an empty import")
        } catch {
            XCTAssertTrue(error is ChunkFailure)
        }
    }

    /// A one-chunk statement has no earlier chunk to keep, so it keeps throwing
    /// exactly as it did before #635.
    func testASingleChunkStatementStillThrows() async {
        let seen = Seen()
        do {
            _ = try await AnthropicClient.runStatementChunks(
                chunks: chunks(1),
                wholePDF: Data(),
                extractChunk: extractor(failingAt: 0, meta: { _ in self.emptyMeta }, seen: seen)
            )
            XCTFail("a single-chunk statement has nothing to salvage and must throw")
        } catch {
            XCTAssertTrue(error is ChunkFailure)
        }
    }

    /// A clean run is unchanged: every chunk read, no stop reason, nothing to
    /// resume.
    func testACompleteRunReportsNoStopReasonAndNoResumePoint() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(4),
            wholePDF: Data(),
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(extraction.lines.count, 4)
        XCTAssertNil(extraction.stopReason)
        XCTAssertNil(extraction.resumePoint)
        XCTAssertEqual(extraction.chunksCompleted, 4)
    }

    // MARK: - Stopping is not interruption

    /// The user tapping Stop and a chunk dying are different causes with
    /// different remedies, so they must not share a signal.
    func testAUserStopIsReportedSeparatelyFromAnInterruption() async throws {
        let seen = Seen()
        let token = ImportCancellationToken()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            cancellation: token,
            extractChunk: { chunk in
                let index = Int(String(decoding: chunk.data, as: UTF8.self).dropFirst("chunk-".count)) ?? -1
                seen.record(index)
                // Ask to stop once two chunks are in, so the third boundary taps out.
                if index == 1 { token.cancel() }
                return (lines: [self.line(forChunk: index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.stopReason, .stoppedByUser)
        XCTAssertNil(extraction.stopReason?.failure, "a user stop is not a failure")
        XCTAssertEqual(extraction.lines.count, 2)
        XCTAssertEqual(extraction.chunksCompleted, 2)
    }

    // MARK: - Resume

    /// `PDFChunker.split` is deterministic, so the count of chunks already read
    /// is enough to skip them. Resume must pay for the tail only.
    func testResumeReadsOnlyTheChunksTheLastRunMissed() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 5, meta: citiMeta),
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(seen.indices, [3, 4], "the three chunks already paid for must not be re-read")
        XCTAssertEqual(extraction.lines.map(\.merchant), ["Merchant 3", "Merchant 4"])
        XCTAssertEqual(extraction.chunksCompleted, 5)
        XCTAssertNil(extraction.stopReason)
        XCTAssertNil(extraction.resumePoint, "nothing is left to read, so nothing more to offer")
    }

    /// A statement prints its header on page 1, which a resumed run never reads
    /// again. Without carrying it forward every resumed row would lose its card
    /// attribution and payment method (#189).
    func testResumeCarriesTheStatementHeaderForward() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 5, meta: citiMeta),
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(extraction.meta, citiMeta)
    }

    /// Progress on a resumed run counts against the WHOLE statement, so the
    /// banner reads "4 of 5" rather than restarting at "1 of 2".
    func testResumeReportsProgressAgainstTheWholeStatement() async throws {
        let seen = Seen()
        let reports = Reports()
        _ = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 5, meta: citiMeta),
            onProgress: { done, total in reports.record(done, total) },
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(reports.values.map { $0.0 }, [4, 5])
        XCTAssertEqual(reports.values.map { $0.1 }, [5, 5])
    }

    /// A resumed run that dies again reports a NEW resume point further along,
    /// so each attempt keeps ground rather than starting over.
    func testAResumedRunThatDiesAgainAdvancesTheResumePoint() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(8),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 8, meta: citiMeta),
            extractChunk: extractor(failingAt: 6, meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(extraction.stopReason?.failure?.kind, .unreadable)
        XCTAssertEqual(extraction.resumePoint?.chunksCompleted, 6)
        XCTAssertEqual(extraction.resumePoint?.chunksTotal, 8)
        XCTAssertEqual(extraction.resumePoint?.hasUnreadChunks, true)
    }

    // MARK: - A restored run, and the scope rule (#639)

    /// A run restored after a relaunch resumes on exactly the terms an
    /// in-session Resume does: only the unread chunks are read, and the ones
    /// already paid for are not touched.
    ///
    /// Driven through the plan a `StatementResumeStore` record rebuilds, so the
    /// assertion is about the round trip, not about a hand-built point.
    func testARestoredPlanReadsOnlyTheUnreadChunks() async throws {
        let record = StatementResumeRecord(
            pdfPath: "statement-resumes/abc.pdf",
            sha256: "unused-here",
            byteCount: 4,
            fileName: "Amex_Sep2026.pdf",
            tripUUID: nil,
            chunksCompleted: 3,
            chunksTotal: 5,
            issuer: "Citi",
            last4: "1234",
            statementMonth: 5,
            statementYear: 2026,
            outcomeText: "Imported 158",
            outcomeIsFailure: false,
            savedAt: Date()
        )

        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            resumingFrom: record.resumePoint,
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(seen.indices, [3, 4], "a restored plan must skip what the last run already read")
        XCTAssertEqual(extraction.meta, citiMeta, "and carry that run's header forward")
        XCTAssertEqual(extraction.chunksCompleted, 5)
    }

    /// A restored run that is interrupted AGAIN advances its resume point, so
    /// the third attempt starts where the second stopped rather than where the
    /// first did.
    func testARestoredRunThatIsInterruptedAgainAdvancesTheResumePoint() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(8),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 8, meta: citiMeta),
            extractChunk: extractor(failingAt: 5, meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(extraction.resumePoint?.chunksCompleted, 5)
        XCTAssertEqual(extraction.chunksStartedAt, 3)
    }

    /// The scope rule, and the reason it is a rule: a statement picked from the
    /// file picker is read in FULL, every page, every time, even when a
    /// persisted record for those exact bytes is sitting in the store.
    ///
    /// The user may have deleted rows and want the whole file parsed again, and
    /// a fresh import is how they ask for that. So the picker path passes no
    /// resume point, and nothing anywhere looks a file up by hash.
    func testAPickedFileIsReadInFullEvenWithAPersistedRecordForThoseBytes() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            // What `handleStatementData` passes: nothing. There is no lookup to
            // make this anything else.
            resumingFrom: nil,
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        XCTAssertEqual(seen.indices, [0, 1, 2, 3, 4], "a fresh import means fresh: every page, every time")
        XCTAssertEqual(extraction.chunksStartedAt, 0)
        XCTAssertNil(extraction.resumePoint)
    }

    // MARK: - What a resumed run says it read (#639)

    /// A resume that costs one call must not read as a run that silently did
    /// less than the one before it, so the summary names the pages THIS run
    /// read.
    func testAResumedRunSaysWhichPagesItRead() async throws {
        let seen = Seen()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 5, meta: citiMeta),
            extractChunk: extractor(meta: { _ in self.emptyMeta }, seen: seen)
        )

        // Chunks 3 and 4 are pages 10 to 12 and 13 to 15.
        XCTAssertEqual(extraction.pagesReadThisRun.map(\.label), ["pages 10 to 12", "pages 13 to 15"])

        let result = StatementImportResult(
            imported: 4, refunds: 0, skippedDuplicates: 0, ignoredNonSpend: 0, failed: 0,
            possiblyTruncated: false, importedUUIDs: [],
            resumedFromChunk: extraction.chunksStartedAt,
            pagesReadThisRun: extraction.pagesReadThisRun
        )
        XCTAssertTrue(result.summaryLine.contains("Imported 4"))
        XCTAssertTrue(
            result.summaryLine.contains("Resumed, so this run read pages 10 to 15 of the statement."),
            "got: \(result.summaryLine)"
        )
    }

    /// A fresh import read the file from its first page, so it needs no
    /// qualifier and must not grow one.
    func testAFreshImportSummaryIsUnqualified() {
        let result = StatementImportResult(
            imported: 42, refunds: 0, skippedDuplicates: 0, ignoredNonSpend: 0, failed: 0,
            possiblyTruncated: false, importedUUIDs: []
        )
        XCTAssertEqual(result.summaryLine, "Imported 42")
        XCTAssertNil(result.resumedRunSentence)
    }

    /// A resumed run that found nothing read only the missing pages, so the
    /// "nothing to import" wording must not claim it read the statement.
    func testAResumedRunThatFoundNothingSaysWhichPagesItLookedAt() {
        let result = StatementImportResult(
            imported: 0, refunds: 0, skippedDuplicates: 0, ignoredNonSpend: 0, failed: 0,
            possiblyTruncated: false, importedUUIDs: [],
            resumedFromChunk: 3,
            pagesReadThisRun: [PDFPageRange(first: 10, last: 12)]
        )
        XCTAssertTrue(result.summaryLine.contains("Resumed, so this run read pages 10 to 12"))
        XCTAssertTrue(result.summaryLine.contains("No transactions were found on those pages."))
    }

    /// The resumed sentence rides every end state, so an interrupted resume
    /// still reports what it managed to read.
    func testTheResumedSentenceSurvivesAnInterruptedEndState() {
        let result = StatementImportResult(
            imported: 4, refunds: 0, skippedDuplicates: 0, ignoredNonSpend: 0, failed: 0,
            possiblyTruncated: false, importedUUIDs: [],
            incompleteReason: .failed(.outOfCredit("Your credit balance is too low")),
            resumedFromChunk: 3,
            pagesReadThisRun: [PDFPageRange(first: 10, last: 12)]
        )
        let summary = result.summaryLine
        XCTAssertTrue(summary.contains("Import stopped: out of API credit"))
        XCTAssertTrue(summary.contains("Resumed, so this run read pages 10 to 12 of the statement."))
        XCTAssertFalse(summary.contains("\u{2014}"), "no em dash in a user-facing string")
    }

    /// Nothing new read on a resumed run is still a thrown error: the user
    /// needs to see why the retry died, not a summary that imported nothing.
    func testAResumedRunThatReadsNothingThrows() async {
        let seen = Seen()
        do {
            _ = try await AnthropicClient.runStatementChunks(
                chunks: chunks(8),
                wholePDF: Data(),
                resumingFrom: StatementResumePoint(chunksCompleted: 3, chunksTotal: 8, meta: citiMeta),
                extractChunk: extractor(failingAt: 3, meta: { _ in self.emptyMeta }, seen: seen)
            )
            XCTFail("a resumed run that read nothing must surface the real error")
        } catch {
            XCTAssertTrue(error is ChunkFailure)
        }
    }

    /// Reference box for the `@MainActor @Sendable` progress callback.
    private final class Reports: @unchecked Sendable {
        private(set) var values: [(Int, Int)] = []
        func record(_ done: Int, _ total: Int) { values.append((done, total)) }
    }

    // MARK: - What the user is told

    /// Three causes, three remedies, three messages. An interrupted run must
    /// not read as a complete one, and must say how many rows landed.
    func testInterruptedImportSaysSoAndSaysHowManyLanded() {
        let result = StatementImportResult(
            imported: 57,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: false,
            importedUUIDs: [],
            incompleteReason: .failed(.transport("The network connection was lost."))
        )

        let summary = result.summaryLine

        XCTAssertTrue(summary.contains("Import interrupted"), summary)
        XCTAssertTrue(summary.contains("Imported 57"), summary)
        XCTAssertTrue(summary.contains("Resume"), summary)
        XCTAssertFalse(summary.contains("Import stopped"), "a dropped connection is not a user stop")
        XCTAssertFalse(summary.contains("Incomplete import"), "an interruption is not a truncation")
        XCTAssertFalse(summary.contains("—"), "user-facing copy must carry no em dash")
    }

    /// The truncation warning is a third, separate message: the model ran out
    /// of output budget on a chunk it DID read, which no amount of resuming
    /// fixes.
    func testTruncationKeepsItsOwnDistinctMessage() {
        let result = StatementImportResult(
            imported: 12,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: true,
            importedUUIDs: []
        )

        let summary = result.summaryLine

        XCTAssertTrue(summary.contains("Incomplete import"), summary)
        XCTAssertTrue(summary.contains("Imported 12"), summary)
        XCTAssertFalse(summary.contains("Import interrupted"))
        XCTAssertFalse(summary.contains("Import stopped"))
    }

    // MARK: - Self-healing re-split (#637)

    /// Stand-in for `PDFChunker.halves(of:)` that needs no real PDF. Splits a
    /// range down the middle and names each half by the pages it covers, so an
    /// extractor can be keyed on the range it was handed rather than on bytes.
    private static func halve(_ chunk: PDFChunk) -> [PDFChunk]? {
        guard chunk.pages.pageCount > 1 else { return nil }
        let mid = chunk.pages.first + chunk.pages.pageCount / 2
        return [
            Self.ranged(chunk.pages.first, mid - 1),
            Self.ranged(mid, chunk.pages.last)
        ]
    }

    /// A chunk whose bytes spell out its own page range ("p7-9"), which makes
    /// the re-split fixtures readable.
    private static func ranged(_ first: Int, _ last: Int) -> PDFChunk {
        PDFChunk(
            data: Data("p\(first)-\(last)".utf8),
            pages: PDFPageRange(first: first, last: last)
        )
    }

    /// One line per page in a range, so "did every row come through" is a
    /// question about page coverage rather than about counts alone.
    private func lines(forPages range: PDFPageRange) -> [ExtractedStatementLine] {
        (range.first...range.last).map { page in
            ExtractedStatementLine(
                merchant: "Page \(page) merchant",
                date: "2026-08-01",
                amount: Double(page),
                currency: "SGD",
                type: .purchase,
                category: "food_and_dining"
            )
        }
    }

    /// Records every range the extractor was asked for, in order.
    private final class RangeLog: @unchecked Sendable {
        private(set) var labels: [String] = []
        func record(_ range: PDFPageRange) { labels.append(range.label) }
    }

    /// An extractor that reports `max_tokens` for exactly the ranges named in
    /// `truncating` (by their label, e.g. "pages 7 to 9") and reads every other
    /// range cleanly. Naming ranges rather than pages is what lets a test say
    /// "the 3-page chunk overflows but either half fits", which is the whole
    /// premise of the re-split.
    ///
    /// A truncated read still returns a PARTIAL array, exactly as the real one
    /// does: the JSON recovery trims the cut-off array back to its last
    /// complete element.
    private func healingExtractor(
        truncating: Set<String>,
        log: RangeLog
    ) -> (PDFChunk) async throws -> StatementChunkResult {
        return { chunk in
            log.record(chunk.pages)
            let full = self.lines(forPages: chunk.pages)
            if truncating.contains(chunk.pages.label) {
                // The partial prefix the model DID emit before it ran out.
                return (lines: Array(full.prefix(1)), meta: self.emptyMeta, possiblyTruncated: true)
            }
            return (lines: full, meta: self.emptyMeta, possiblyTruncated: false)
        }
    }

    /// The core of the ticket. A chunk that hits the output ceiling is re-read
    /// as halves of its own page range, and the FULL row set comes back exactly
    /// once: the truncated attempt's partial rows are discarded, not merged, so
    /// nothing double-counts.
    func testATruncatedChunkIsReReadAsHalvesAndKeepsEveryRowOnce() async throws {
        let log = RangeLog()
        // The whole 3-page chunk truncates; either half on its own is fine.
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            extractChunk: healingExtractor(truncating: ["pages 1 to 3"], log: log)
        )

        XCTAssertEqual(log.labels, ["pages 1 to 3", "page 1", "pages 2 to 3"],
                       "the truncated range must be re-read as its two halves")
        XCTAssertEqual(
            extraction.lines.map(\.merchant),
            ["Page 1 merchant", "Page 2 merchant", "Page 3 merchant"],
            "every row must come through, and each exactly once"
        )
        XCTAssertFalse(extraction.possiblyTruncated, "the re-split rescued it, so there is no warning")
        XCTAssertTrue(extraction.truncatedPageRanges.isEmpty)
        XCTAssertNil(extraction.stopReason, "a healed truncation is not an early stop")
    }

    /// The re-split is per-chunk. A truncation on chunk 2 must not make the
    /// loop re-read chunks that were fine, and the merged output stays in
    /// statement order.
    func testOnlyTheTruncatedChunkIsReReadWithinAMultiChunkRun() async throws {
        let log = RangeLog()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6), Self.ranged(7, 9)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            extractChunk: healingExtractor(truncating: ["pages 4 to 6"], log: log)
        )

        XCTAssertEqual(log.labels,
                       ["pages 1 to 3", "pages 4 to 6", "page 4", "pages 5 to 6", "pages 7 to 9"])
        XCTAssertEqual(extraction.lines.count, 9)
        XCTAssertEqual(extraction.lines.first?.merchant, "Page 1 merchant")
        XCTAssertEqual(extraction.lines.last?.merchant, "Page 9 merchant")
        XCTAssertFalse(extraction.possiblyTruncated)
    }

    /// A range that is already ONE page cannot be halved, so the recursion
    /// stops there and today's warning stands for that range only. The partial
    /// rows it did read are kept, exactly as before #637.
    func testASinglePageThatStillTruncatesFallsBackToTheWarningForThatRangeOnly() async throws {
        let log = RangeLog()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            // Page 4 alone is unreadable in one pass, so 4-6 and 4-4 truncate.
            extractChunk: healingExtractor(truncating: ["pages 4 to 6", "page 4"], log: log)
        )

        XCTAssertEqual(log.labels,
                       ["pages 1 to 3", "pages 4 to 6", "page 4", "pages 5 to 6"])
        XCTAssertTrue(extraction.possiblyTruncated)
        XCTAssertEqual(extraction.truncatedPageRanges, [PDFPageRange(first: 4, last: 4)],
                       "only the page that could not be rescued is reported")
        // Chunk 1 in full, page 4's partial prefix, pages 5 to 6 in full.
        XCTAssertEqual(
            extraction.lines.map(\.merchant),
            ["Page 1 merchant", "Page 2 merchant", "Page 3 merchant",
             "Page 4 merchant", "Page 5 merchant", "Page 6 merchant"]
        )
        XCTAssertNil(extraction.stopReason, "a truncation is not an early stop; it is its own end state")
    }

    /// The depth cap is what bounds the extra API calls a pathological file can
    /// cost. At depth 0 nothing is re-split at all, and the whole chunk's range
    /// is what gets named.
    func testTheRecursionDepthCapHolds() async throws {
        let noSplit = RangeLog()
        let capped = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(7, 9)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            maxResplitDepth: 0,
            extractChunk: healingExtractor(truncating: ["pages 7 to 9"], log: noSplit)
        )

        XCTAssertEqual(noSplit.labels, ["pages 7 to 9"], "depth 0 must not re-split at all")
        XCTAssertEqual(capped.truncatedPageRanges, [PDFPageRange(first: 7, last: 9)])

        // One level of halving, then the cap stops it: three calls, no more.
        let oneLevel = RangeLog()
        let shallow = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(7, 9)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            maxResplitDepth: 1,
            extractChunk: healingExtractor(
                truncating: ["pages 7 to 9", "page 7", "pages 8 to 9"],
                log: oneLevel
            )
        )

        XCTAssertEqual(oneLevel.labels, ["pages 7 to 9", "page 7", "pages 8 to 9"],
                       "the cap must stop the second level of halving")
        XCTAssertEqual(
            shallow.truncatedPageRanges,
            [PDFPageRange(first: 7, last: 7), PDFPageRange(first: 8, last: 9)]
        )
    }

    /// `PDFChunker.halves` returning nil (unsplittable bytes) is the third stop
    /// condition, and it must behave exactly like a single page: keep the
    /// partial rows, name the range, do not loop.
    func testAnUnsplittableChunkFallsBackRatherThanLooping() async throws {
        let log = RangeLog()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3)],
            wholePDF: Data(),
            splitChunk: { _ in nil },
            extractChunk: healingExtractor(truncating: ["pages 1 to 3"], log: log)
        )

        XCTAssertEqual(log.labels, ["pages 1 to 3"])
        XCTAssertEqual(extraction.truncatedPageRanges, [PDFPageRange(first: 1, last: 3)])
        XCTAssertTrue(extraction.possiblyTruncated)
    }

    /// A half that dies is an interruption, not a truncation. The two are
    /// separate end states with separate remedies, and Resume re-reads the
    /// whole chunk rather than leaving half its pages unaccounted for.
    func testAFailedHalfIsReportedAsAnInterruption() async throws {
        let log = RangeLog()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6), Self.ranged(7, 9)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            extractChunk: { chunk in
                log.record(chunk.pages)
                if chunk.pages == PDFPageRange(first: 5, last: 6) { throw ChunkFailure() }
                if chunk.pages == PDFPageRange(first: 4, last: 6) {
                    return (lines: [], meta: self.emptyMeta, possiblyTruncated: true)
                }
                return (lines: self.lines(forPages: chunk.pages), meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.stopReason?.failure?.kind, .unreadable)
        XCTAssertFalse(extraction.possiblyTruncated, "a dead request is not the output ceiling")
        XCTAssertEqual(extraction.lines.count, 3, "only the chunk read before the failure survives")
        XCTAssertEqual(extraction.resumePoint?.chunksCompleted, 1,
                       "Resume re-reads the whole failed chunk, halves and all")
    }

    /// The statement header is printed on page 1 and the truncated attempt
    /// parses it (it is emitted ahead of the lines array), so a re-split must
    /// not lose it when the halves come back headerless.
    func testAReSplitKeepsTheHeaderTheTruncatedAttemptRead() async throws {
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            extractChunk: { chunk in
                if chunk.pages.pageCount > 1 {
                    return (lines: [], meta: self.citiMeta, possiblyTruncated: true)
                }
                return (lines: self.lines(forPages: chunk.pages), meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.meta, citiMeta)
    }

    // MARK: - What a surviving truncation tells the user (#637)

    /// The warning names the pages. "Some transactions may be missing" gave the
    /// user nowhere to look; the page range is the whole point of item 4.
    func testTheTruncationWarningNamesThePageRange() {
        var result = StatementImportResult(
            imported: 120,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: true,
            importedUUIDs: []
        )
        result.truncatedPageRanges = [PDFPageRange(first: 7, last: 9)]

        let summary = result.summaryLine

        XCTAssertTrue(summary.contains("Pages 7 to 9 were only partly read"), summary)
        XCTAssertTrue(summary.contains("Imported 120"), summary)
        XCTAssertFalse(summary.contains("—"), "user-facing copy must carry no em dash")
    }

    /// One page reads as one page, not "pages 4 to 4".
    func testASinglePageTruncationReadsAsOnePage() {
        var result = StatementImportResult(
            imported: 9,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: true,
            importedUUIDs: []
        )
        result.truncatedPageRanges = [PDFPageRange(first: 4, last: 4)]

        XCTAssertTrue(result.summaryLine.contains("Page 4 was only partly read"), result.summaryLine)
    }

    /// Several surviving ranges are listed, so the user can check each.
    func testSeveralTruncatedRangesAreAllNamed() {
        var result = StatementImportResult(
            imported: 40,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: true,
            importedUUIDs: []
        )
        result.truncatedPageRanges = [
            PDFPageRange(first: 4, last: 4),
            PDFPageRange(first: 8, last: 9)
        ]

        let summary = result.summaryLine
        XCTAssertTrue(summary.contains("Page 4 and pages 8 to 9 were only partly read"), summary)
    }

    /// The photo multi-expense path has no pages, so the warning degrades to
    /// the unnamed wording rather than claiming a page range it never had.
    func testATruncationWithNoKnownRangeStillWarns() {
        let result = StatementImportResult(
            imported: 3,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: true,
            importedUUIDs: []
        )

        let summary = result.summaryLine
        XCTAssertTrue(summary.contains("Incomplete import"), summary)
        XCTAssertTrue(summary.contains("too long to read in one pass"), summary)
        XCTAssertFalse(summary.contains("—"), "user-facing copy must carry no em dash")
    }

    /// No em dash anywhere in `summaryLine`, including the zero-rows branch the
    /// ticket called out alongside the truncation one (item 5).
    func testNoSummaryBranchCarriesAnEmDash() {
        func result(
            imported: Int,
            truncated: Bool = false,
            reason: StatementExtraction.StopReason? = nil
        ) -> StatementImportResult {
            StatementImportResult(
                imported: imported,
                refunds: 1,
                skippedDuplicates: 1,
                ignoredNonSpend: 1,
                failed: 1,
                possiblyTruncated: truncated,
                importedUUIDs: [],
                deposits: 1,
                depositsTotalSGD: 14_840,
                incompleteReason: reason
            )
        }

        let branches = [
            result(imported: 0).summaryLine,
            result(imported: 10).summaryLine,
            result(imported: 10, reason: .stoppedByUser).summaryLine,
            result(imported: 10, reason: .failed(.transport("The network connection was lost."))).summaryLine,
            result(imported: 10, truncated: true).summaryLine
        ]
        for branch in branches {
            XCTAssertFalse(branch.contains("—"), "em dash in: \(branch)")
        }
    }

    /// The four end states stay four. Each carries its own headline, and no two
    /// collapse into one another.
    func testTheFourEndStatesKeepFourDistinctMessages() {
        func result(
            truncated: Bool = false,
            reason: StatementExtraction.StopReason? = nil
        ) -> StatementImportResult {
            StatementImportResult(
                imported: 20,
                refunds: 0,
                skippedDuplicates: 0,
                ignoredNonSpend: 0,
                failed: 0,
                possiblyTruncated: truncated,
                importedUUIDs: [],
                incompleteReason: reason
            )
        }

        let complete = result().summaryLine
        let stopped = result(reason: .stoppedByUser).summaryLine
        let interrupted = result(reason: .failed(.transport("The network connection was lost."))).summaryLine
        let truncated = result(truncated: true).summaryLine

        XCTAssertEqual(complete, "Imported 20")
        XCTAssertTrue(stopped.hasPrefix("Import stopped"), stopped)
        XCTAssertTrue(interrupted.hasPrefix("Import interrupted"), interrupted)
        XCTAssertTrue(truncated.hasPrefix("⚠️ Incomplete import"), truncated)
        XCTAssertEqual(Set([complete, stopped, interrupted, truncated]).count, 4)

        XCTAssertTrue(result().isComplete)
        XCTAssertFalse(result(reason: .stoppedByUser).isComplete)
        XCTAssertFalse(result(reason: .failed(.transport("lost"))).isComplete)
        XCTAssertFalse(result(truncated: true).isComplete)
    }

    // MARK: - The banner label follows the outcome (#637)

    private func job(
        subject: String? = "9_Aug_2026.pdf",
        isResuming: Bool = false,
        outcome: ImportJob.Outcome? = nil
    ) -> ImportJob {
        ImportJob(
            id: UUID(),
            kind: .statement,
            scope: .finance,
            subject: subject,
            isResuming: isResuming,
            outcome: outcome
        )
    }

    /// The defect this ticket opened on: a finished run rendered "Importing
    /// 9_Aug_2026.pdf" next to a green tick, because the label was fixed at the
    /// start and nothing could revise it.
    func testAFinishedJobStopsSayingImporting() {
        let finished = job(outcome: .summary("Imported 180"))

        XCTAssertEqual(finished.displayLabel, "Imported 9_Aug_2026.pdf")
        XCTAssertFalse(finished.displayLabel.hasPrefix("Importing"))
    }

    /// One label per end state, each distinct.
    func testTheLabelReadsCorrectlyForEachEndState() {
        XCTAssertEqual(job().displayLabel, "Importing 9_Aug_2026.pdf…")
        XCTAssertEqual(job(isResuming: true).displayLabel, "Resuming 9_Aug_2026.pdf…")
        XCTAssertEqual(job(outcome: .summary("ok")).displayLabel, "Imported 9_Aug_2026.pdf")
        XCTAssertEqual(job(outcome: .incomplete("short")).displayLabel,
                       "Import incomplete: 9_Aug_2026.pdf")
        XCTAssertEqual(job(outcome: .failure("boom")).displayLabel,
                       "Import failed: 9_Aug_2026.pdf")
    }

    /// A resumed run that finishes reads as finished, not as still resuming.
    func testAFinishedResumeAlsoFollowsTheOutcome() {
        let done = job(isResuming: true, outcome: .summary("Imported 60"))
        XCTAssertEqual(done.displayLabel, "Imported 9_Aug_2026.pdf")

        let short = job(isResuming: true, outcome: .incomplete("Import interrupted"))
        XCTAssertEqual(short.displayLabel, "Import incomplete: 9_Aug_2026.pdf")
    }

    /// No file name (a receipt capture, or a picker that gave none) still gets
    /// a sensible verdict rather than a dangling "Imported ".
    func testAJobWithNoFileNameStillReadsAsAVerdict() {
        XCTAssertEqual(job(subject: nil).displayLabel, "Importing statement…")
        XCTAssertEqual(job(subject: nil, outcome: .summary("ok")).displayLabel, "Imported")
        XCTAssertEqual(job(subject: nil, outcome: .incomplete("x")).displayLabel, "Import incomplete")
        XCTAssertEqual(job(subject: nil, outcome: .failure("x")).displayLabel, "Import failed")
    }

    /// `Outcome.summary(_:complete:)` is what the two import screens call, so
    /// the choice of flavour is made in one place rather than at each screen.
    func testTheOutcomeFactoryPicksTheFlavourFromCompleteness() {
        XCTAssertEqual(ImportJob.Outcome.summary("t", complete: true), .summary("t"))
        XCTAssertEqual(ImportJob.Outcome.summary("t", complete: false), .incomplete("t"))
        XCTAssertEqual(ImportJob.Outcome.incomplete("t").message, "t")
    }

}

/// Reach the classification off a stop reason without rebuilding its payload
/// (#638). `kind` is the payload-free projection, so a test can name WHICH
/// failure it expects without repeating an error's `localizedDescription`.
extension StatementExtraction.StopReason {
    var failure: StatementFailure? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

// MARK: - #638: a failure says WHICH failure it was

/// Every import failure used to be reported as a dropped connection (#638).
///
/// The defect: `runStatementChunks` caught every error and set one
/// `.interrupted` stop reason whose copy said the connection dropped. In the
/// field the Anthropic prepaid balance ran out mid-statement, the API replied
/// `HTTP 400 {"error":{"type":"invalid_request_error","message":"Your credit
/// balance is too low..."}}`, and the app told the user their connection had
/// dropped while holding the exact answer in hand and discarding it.
///
/// These drive the same injected-closure seam as the #635 / #637 tests, so
/// every classification and the whole backoff run without a live API call.
@MainActor
final class StatementFailureClassificationTests: XCTestCase {

    // MARK: - Fixtures

    /// The body the live probe actually returned, verbatim.
    private static let creditBody = #"""
    {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}
    """#

    /// A 400 that is NOT billing: the same status, a different meaning, and no
    /// retry will ever fix it.
    private static let malformedBody = #"""
    {"type":"error","error":{"type":"invalid_request_error","message":"messages.0.content.0.source.data: invalid base64 data"}}
    """#

    private static let rateLimitBody = #"""
    {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit."}}
    """#

    private static let overloadedBody = #"""
    {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    """#

    private static let serverErrorBody = #"""
    {"type":"error","error":{"type":"api_error","message":"Internal server error"}}
    """#

    private static func http(_ status: Int, _ body: String, retryAfter: TimeInterval? = nil) -> StatementExtractionError {
        .http(status, body, retryAfter: retryAfter)
    }

    private func chunks(_ count: Int) -> [PDFChunk] {
        (0..<count).map {
            PDFChunk(
                data: Data("chunk-\($0)".utf8),
                pages: PDFPageRange(first: $0 * 3 + 1, last: $0 * 3 + 3)
            )
        }
    }

    private let emptyMeta = ExtractedStatementMeta(issuer: nil, last4: nil, statementMonth: nil, statementYear: nil)

    private func line(_ index: Int) -> ExtractedStatementLine {
        ExtractedStatementLine(
            merchant: "Merchant \(index)",
            date: "2026-05-01",
            amount: Double(index + 1),
            currency: "SGD",
            type: .purchase,
            category: "food_and_dining"
        )
    }

    /// Records every backoff wait the loop asked for, in order. Asserting on
    /// the SEQUENCE is what proves the backoff is exponential rather than a
    /// fixed sleep.
    private final class Waits: @unchecked Sendable {
        private(set) var seconds: [TimeInterval] = []
        func record(_ value: TimeInterval) { seconds.append(value) }
    }

    /// Counts attempts per chunk index, so a retry test can say "this chunk
    /// was called three times" rather than only "it eventually worked".
    private final class Attempts: @unchecked Sendable {
        private(set) var counts: [Int: Int] = [:]
        func record(_ index: Int) -> Int {
            let next = (counts[index] ?? 0) + 1
            counts[index] = next
            return next
        }
    }

    private func index(of chunk: PDFChunk) -> Int {
        Int(String(decoding: chunk.data, as: UTF8.self).dropFirst("chunk-".count)) ?? -1
    }

    private func result(reason: StatementExtraction.StopReason) -> StatementImportResult {
        StatementImportResult(
            imported: 57,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: false,
            importedUUIDs: [],
            incompleteReason: reason
        )
    }

    // MARK: - Classification

    /// The heart of the ticket. The exact body the live probe returned must
    /// classify as the billing wall, off the API's own `type` plus message.
    func testTheCreditWallIsRecognisedFromTheRealResponseBody() {
        let failure = StatementFailure.classify(Self.http(400, Self.creditBody))

        XCTAssertEqual(failure.kind, .outOfCredit)
        XCTAssertTrue(failure.canResume, "topping up makes the very same request work")
        if case .outOfCredit(let message) = failure {
            XCTAssertTrue(message.contains("credit balance"), "the API's own words must be carried, not discarded")
        } else {
            XCTFail("expected .outOfCredit, got \(failure)")
        }
    }

    /// The other half of the same status. A malformed request is also a 400,
    /// and no user action fixes it, so it must NOT be read as a billing wall
    /// and must not offer a Resume that is guaranteed to fail.
    func testANonBillingBadRequestIsNotTheCreditWallAndCannotResume() {
        let failure = StatementFailure.classify(Self.http(400, Self.malformedBody))

        XCTAssertEqual(failure.kind, .api)
        XCTAssertFalse(failure.canResume, "no retry fixes a malformed request")
        XCTAssertTrue(failure.summaryBody.contains("invalid base64 data"),
                      "the API's own message must reach the user: \(failure.summaryBody)")
    }

    /// Detection keys on the error TYPE plus the message, not on the status,
    /// so the same billing message under a 429 is still the billing wall.
    func testTheCreditWallIsDetectedFromTypeAndMessageNotFromTheStatusAlone() {
        let asPermissionError = #"""
        {"type":"error","error":{"type":"permission_error","message":"Your credit balance is too low to access the Anthropic API."}}
        """#
        XCTAssertEqual(StatementFailure.classify(Self.http(403, asPermissionError)).kind, .outOfCredit)

        // A message that merely mentions credits, under a type that is not a
        // billing type, is not the billing wall.
        let notBilling = #"""
        {"type":"error","error":{"type":"api_error","message":"credit balance service unavailable"}}
        """#
        XCTAssertEqual(StatementFailure.classify(Self.http(500, notBilling)).kind, .api)
    }

    func testRateLimitAndOverloadAndServerErrorsEachClassify() {
        XCTAssertEqual(StatementFailure.classify(Self.http(429, Self.rateLimitBody)).kind, .rateLimited)
        XCTAssertEqual(StatementFailure.classify(Self.http(529, Self.overloadedBody)).kind, .overloaded)

        let server = StatementFailure.classify(Self.http(500, Self.serverErrorBody))
        XCTAssertEqual(server.kind, .api)
        XCTAssertTrue(server.canResume, "a 500 clears on its own, so Resume is worth offering")
    }

    /// A real network drop is the ONE case allowed to say the connection
    /// dropped.
    func testARealTransportFailureStillReportsAsOne() {
        let dropped = URLError(.networkConnectionLost)
        let failure = StatementFailure.classify(StatementExtractionError.transport(dropped))

        XCTAssertEqual(failure.kind, .transport)
        XCTAssertTrue(failure.canResume)
        XCTAssertTrue(failure.summaryBody.contains("connection dropped"), failure.summaryBody)
    }

    func testAMissingKeyAndAnUnreadableReplyStayDistinct() {
        XCTAssertEqual(StatementFailure.classify(StatementExtractionError.notConfigured).kind, .notConfigured)
        XCTAssertEqual(StatementFailure.classify(StatementExtractionError.noJSON).kind, .unreadable)
    }

    /// A body that is not JSON at all (a proxy's HTML error page, say) must
    /// still produce a usable message rather than crashing the classifier.
    func testANonJSONErrorBodyStillClassifiesAsAnAPIError() {
        let failure = StatementFailure.classify(Self.http(502, "<html>Bad Gateway</html>"))

        XCTAssertEqual(failure.kind, .api)
        XCTAssertTrue(failure.canResume)
        XCTAssertTrue(failure.failureAlertMessage.contains("502"), failure.failureAlertMessage)
    }

    // MARK: - A message per classification

    /// Requirement 2: each classification gets its own message, and no two
    /// collapse into one another.
    func testEachClassificationProducesItsOwnDistinctMessage() {
        let failures: [StatementFailure] = [
            .outOfCredit("Your credit balance is too low to access the Anthropic API."),
            .rateLimited(retryAfter: nil),
            .overloaded(retryAfter: nil),
            .api(status: 400, message: "invalid base64 data"),
            .api(status: 500, message: "Internal server error"),
            .notConfigured,
            .transport("The network connection was lost."),
            .unreadable("Claude's reply held no transaction list.")
        ]

        let summaries = failures.map { result(reason: .failed($0)).summaryLine }
        XCTAssertEqual(Set(summaries).count, failures.count, "two classifications share a message")

        let alerts = failures.map(\.failureAlertMessage)
        XCTAssertEqual(Set(alerts).count, failures.count, "two classifications share a failure alert")

        // Every summary still reports what DID land.
        for summary in summaries {
            XCTAssertTrue(summary.contains("Imported 57"), summary)
        }
    }

    /// The credit case names the remedy plainly, and does not say the
    /// connection dropped.
    func testTheCreditMessageNamesTheRemedyAndKeepsResume() {
        let failure = StatementFailure.classify(Self.http(400, Self.creditBody))
        let summary = result(reason: .failed(failure)).summaryLine

        XCTAssertTrue(summary.contains("credit balance is empty"), summary)
        XCTAssertTrue(summary.contains("Plans & Billing"), summary)
        XCTAssertTrue(summary.contains("Resume"), summary)
        XCTAssertFalse(summary.contains("connection dropped"), "the whole defect, in one string: \(summary)")
    }

    /// Requirement 2, second half: never invent copy for an error we do not
    /// recognise, and never dump the raw JSON envelope either.
    func testAnUnclassifiedAPIErrorSurfacesTheAPIsOwnMessageAndNotTheBlob() {
        let failure = StatementFailure.classify(Self.http(413, #"{"type":"error","error":{"type":"request_too_large","message":"Request exceeds the maximum allowed size."}}"#))

        XCTAssertTrue(failure.failureAlertMessage.contains("Request exceeds the maximum allowed size."),
                      failure.failureAlertMessage)
        XCTAssertFalse(failure.failureAlertMessage.contains("{"), "the JSON envelope must not reach the user")
        XCTAssertFalse(failure.failureAlertMessage.contains("request_too_large"),
                       "the machine-readable type is not user copy")
    }

    /// Requirement 5: the whole-run failure path renders the same
    /// classification the partial-run summary does. Before #638 it rendered
    /// `errorDescription`, i.e. "Anthropic API HTTP 400. {json blob}".
    func testTheWholeRunFailurePathSurfacesTheClassifiedMessage() async {
        do {
            _ = try await AnthropicClient.runStatementChunks(
                chunks: chunks(1),
                wholePDF: Data(),
                extractChunk: { _ in throw Self.http(400, Self.creditBody) }
            )
            XCTFail("a single-chunk statement has nothing to salvage and must throw")
        } catch {
            let message = StatementFailure.classify(error).failureAlertMessage
            XCTAssertTrue(message.contains("credit balance is empty"), message)
            XCTAssertFalse(message.contains("HTTP 400. {"), "the raw blob is the defect")
            XCTAssertFalse(message.contains("{\"type\""), message)
        }
    }

    /// No em dash in ANY branch, including every classification (project
    /// no-em-dash rule).
    func testNoClassifiedBranchCarriesAnEmDash() {
        let failures: [StatementFailure] = [
            .outOfCredit("Your credit balance is too low."),
            .rateLimited(retryAfter: 12),
            .overloaded(retryAfter: nil),
            .api(status: 400, message: "invalid base64 data"),
            .api(status: 503, message: "Service unavailable"),
            .notConfigured,
            .transport("The network connection was lost."),
            .unreadable("Claude's reply held no transaction list.")
        ]
        for failure in failures {
            for text in [failure.summaryTitle, failure.summaryBody, failure.failureAlertMessage,
                         result(reason: .failed(failure)).summaryLine] {
                XCTAssertFalse(text.contains("—"), "em dash in: \(text)")
            }
        }
    }

    // MARK: - Resume is offered only where a retry can succeed

    /// Out of credit KEEPS Resume on a partial run: the chunks already read
    /// stay, and topping up makes the rest work.
    func testOutOfCreditKeepsResumeOnAPartialRun() async throws {
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                if index == 3 { throw Self.http(400, Self.creditBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.stopReason?.failure?.kind, .outOfCredit)
        XCTAssertEqual(extraction.lines.count, 3, "the chunks already paid for must survive")
        XCTAssertEqual(extraction.resumePoint?.chunksCompleted, 3)
        XCTAssertEqual(extraction.resumePoint?.chunksTotal, 5)
    }

    /// A non-billing 400 does NOT offer Resume: the same request will be
    /// rejected the same way every time.
    func testANonBillingBadRequestWithholdsResumeButKeepsTheRowsRead() async throws {
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(5),
            wholePDF: Data(),
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                if index == 3 { throw Self.http(400, Self.malformedBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.stopReason?.failure?.kind, .api)
        XCTAssertEqual(extraction.lines.count, 3, "withholding Resume must not discard what was read")
        XCTAssertNil(extraction.resumePoint, "a button guaranteed to fail is worse than no button")
        XCTAssertFalse(extraction.stopReason?.allowsResume ?? true)
    }

    /// Resume is withheld case by case, never blanket-hidden on failure.
    func testResumeIsNotBlanketHiddenOnEveryFailure() {
        let resumable: [StatementFailure] = [
            .outOfCredit("x"), .rateLimited(retryAfter: nil), .overloaded(retryAfter: nil),
            .notConfigured, .transport("x"), .unreadable("x"), .api(status: 500, message: "x")
        ]
        for failure in resumable {
            XCTAssertTrue(failure.canResume, "\(failure.kind) should keep Resume")
        }
        for status in [400, 401, 403, 404, 413] {
            XCTAssertFalse(StatementFailure.api(status: status, message: "x").canResume,
                           "HTTP \(status) should not offer Resume")
        }
    }

    // MARK: - Backoff retry on 429 and 529

    /// Requirement 4. The SAME chunk is retried, the waits double, and the run
    /// finishes clean with no stop reason at all.
    func testARateLimitedChunkIsRetriedWithBackoffAndThenSucceeds() async throws {
        let waits = Waits()
        let attempts = Attempts()

        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(3),
            wholePDF: Data(),
            retryBaseDelay: 2,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                let attempt = attempts.record(index)
                if index == 1, attempt <= 2 { throw Self.http(429, Self.rateLimitBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertNil(extraction.stopReason, "a retry that worked is not a failed run")
        XCTAssertEqual(extraction.lines.count, 3, "every chunk, each read exactly once")
        XCTAssertEqual(attempts.counts[1], 3, "the same chunk was retried, not skipped")
        XCTAssertEqual(waits.seconds, [2, 4], "exponential, not a fixed sleep")
        XCTAssertEqual(extraction.chunksCompleted, 3)
    }

    /// 529 is retried on the same terms as 429.
    func testAn529OverloadIsRetriedToo() async throws {
        let waits = Waits()
        let attempts = Attempts()

        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(2),
            wholePDF: Data(),
            retryBaseDelay: 1,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                let attempt = attempts.record(index)
                if index == 0, attempt == 1 { throw Self.http(529, Self.overloadedBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertNil(extraction.stopReason)
        XCTAssertEqual(waits.seconds, [1])
        XCTAssertEqual(extraction.lines.count, 2)
    }

    /// `retry-after` wins over the computed backoff when the API sends one.
    func testRetryAfterHeaderWinsOverTheComputedBackoff() async throws {
        let waits = Waits()
        let attempts = Attempts()

        _ = try await AnthropicClient.runStatementChunks(
            chunks: chunks(2),
            wholePDF: Data(),
            retryBaseDelay: 2,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                let attempt = attempts.record(index)
                if index == 0, attempt == 1 {
                    throw Self.http(429, Self.rateLimitBody, retryAfter: 7)
                }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(waits.seconds, [7], "the API said 7 seconds, so wait 7, not the 2 we would have picked")
    }

    /// A `retry-after` longer than the cap is clamped: an import must not
    /// block for minutes on one chunk.
    func testAnAbsurdRetryAfterIsClamped() async throws {
        let waits = Waits()
        let attempts = Attempts()

        _ = try await AnthropicClient.runStatementChunks(
            chunks: chunks(2),
            wholePDF: Data(),
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                let attempt = attempts.record(index)
                if index == 0, attempt == 1 {
                    throw Self.http(429, Self.rateLimitBody, retryAfter: 600)
                }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(waits.seconds, [AnthropicClient.maxRetryDelay])
    }

    /// Requirement 4, the exhausted path. Capped attempts, then the run
    /// reports RATE LIMITED, not a phantom dropped connection.
    func testExhaustingTheRetryCapReportsRateLimitedNotADroppedConnection() async throws {
        let waits = Waits()
        let attempts = Attempts()

        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(4),
            wholePDF: Data(),
            maxChunkAttempts: 3,
            retryBaseDelay: 2,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                _ = attempts.record(index)
                if index == 2 { throw Self.http(429, Self.rateLimitBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(attempts.counts[2], 3, "attempts are capped")
        XCTAssertEqual(waits.seconds, [2, 4], "one wait fewer than attempts")
        XCTAssertEqual(extraction.stopReason?.failure?.kind, .rateLimited)

        let summary = result(reason: extraction.stopReason!).summaryLine
        XCTAssertTrue(summary.contains("rate limit"), summary)
        XCTAssertFalse(summary.contains("connection dropped"), summary)
    }

    /// A non-retryable failure is never retried: a malformed request must not
    /// be sent four times.
    func testANonRetryableFailureIsNotRetried() async throws {
        let waits = Waits()
        let attempts = Attempts()

        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: chunks(4),
            wholePDF: Data(),
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                _ = attempts.record(index)
                if index == 2 { throw Self.http(400, Self.malformedBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(attempts.counts[2], 1, "a rejected request is not worth sending again")
        XCTAssertTrue(waits.seconds.isEmpty)
        XCTAssertEqual(extraction.stopReason?.failure?.kind, .api)
    }

    /// Out of credit is not retried in-run either: the balance will not refill
    /// in eight seconds. It ends the run and hands the user Resume instead.
    func testOutOfCreditIsNotRetriedInRun() async throws {
        let waits = Waits()
        let attempts = Attempts()

        _ = try await AnthropicClient.runStatementChunks(
            chunks: chunks(4),
            wholePDF: Data(),
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let index = self.index(of: chunk)
                _ = attempts.record(index)
                if index == 2 { throw Self.http(400, Self.creditBody) }
                return (lines: [self.line(index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(attempts.counts[2], 1)
        XCTAssertTrue(waits.seconds.isEmpty)
    }

    // MARK: - The backoff and the #637 re-split do not interfere

    private static func ranged(_ first: Int, _ last: Int) -> PDFChunk {
        PDFChunk(data: Data("p\(first)-\(last)".utf8), pages: PDFPageRange(first: first, last: last))
    }

    private static func halve(_ chunk: PDFChunk) -> [PDFChunk]? {
        guard chunk.pages.pageCount > 1 else { return nil }
        let mid = chunk.pages.first + chunk.pages.pageCount / 2
        return [Self.ranged(chunk.pages.first, mid - 1), Self.ranged(mid, chunk.pages.last)]
    }

    private func pageLines(_ range: PDFPageRange) -> [ExtractedStatementLine] {
        (range.first...range.last).map { page in
            ExtractedStatementLine(
                merchant: "Page \(page) merchant",
                date: "2026-08-01",
                amount: Double(page),
                currency: "SGD",
                type: .purchase,
                category: "food_and_dining"
            )
        }
    }

    /// The two mechanisms act on different signals and must not collide. A
    /// retry answers a THROWN 429 by sending the identical request again; the
    /// re-split answers a call that RETURNED successfully with the output
    /// ceiling hit, by narrowing the page range. Here one chunk does both, in
    /// that order, and the result is the full row set exactly once with no
    /// truncation warning left standing.
    func testABackoffRetryAndTheReSplitBothRunOnOneChunkWithoutInterfering() async throws {
        let waits = Waits()
        let calls = Attempts()
        // Key the attempt counter by the first page of the range asked for.
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            retryBaseDelay: 2,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let attempt = calls.record(chunk.pages.first * 100 + chunk.pages.last)
                // Pages 4 to 6: rate limited once, then read but truncated,
                // then each half reads clean.
                if chunk.pages == PDFPageRange(first: 4, last: 6) {
                    if attempt == 1 { throw Self.http(429, Self.rateLimitBody) }
                    return (lines: Array(self.pageLines(chunk.pages).prefix(1)),
                            meta: self.emptyMeta, possiblyTruncated: true)
                }
                return (lines: self.pageLines(chunk.pages), meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertNil(extraction.stopReason, "a retry that worked plus a re-split that worked is a clean run")
        XCTAssertTrue(extraction.truncatedPageRanges.isEmpty, "the re-split rescued the range")
        XCTAssertFalse(extraction.possiblyTruncated)
        XCTAssertEqual(waits.seconds, [2], "the truncation must not be mistaken for a retryable failure")
        XCTAssertEqual(extraction.lines.map(\.merchant),
                       (1...6).map { "Page \($0) merchant" },
                       "every page exactly once, no duplicate from the truncated attempt")
        XCTAssertEqual(calls.counts[406], 2, "the 429 retry re-sent pages 4 to 6, the re-split did not")
    }

    /// A truncated chunk on its own triggers no backoff at all: truncation is
    /// a successful call, and the retry loop must never see it.
    func testATruncationAloneNeverTriggersABackoff() async throws {
        let waits = Waits()
        _ = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                if chunk.pages == PDFPageRange(first: 4, last: 6) {
                    return (lines: [], meta: self.emptyMeta, possiblyTruncated: true)
                }
                return (lines: self.pageLines(chunk.pages), meta: self.emptyMeta, possiblyTruncated: false)
            }
        )
        XCTAssertTrue(waits.seconds.isEmpty)
    }

    /// A retryable failure inside a RE-SPLIT half gets the backoff too, so the
    /// halves are not second-class requests.
    func testAHalfAlsoGetsTheBackoff() async throws {
        let waits = Waits()
        let calls = Attempts()
        let extraction = try await AnthropicClient.runStatementChunks(
            chunks: [Self.ranged(1, 3), Self.ranged(4, 6)],
            wholePDF: Data(),
            splitChunk: Self.halve,
            retryBaseDelay: 3,
            sleep: { waits.record($0) },
            extractChunk: { chunk in
                let attempt = calls.record(chunk.pages.first * 100 + chunk.pages.last)
                if chunk.pages == PDFPageRange(first: 4, last: 6) {
                    return (lines: [], meta: self.emptyMeta, possiblyTruncated: true)
                }
                if chunk.pages == PDFPageRange(first: 5, last: 6), attempt == 1 {
                    throw Self.http(429, Self.rateLimitBody)
                }
                return (lines: self.pageLines(chunk.pages), meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertNil(extraction.stopReason)
        XCTAssertEqual(waits.seconds, [3])
        XCTAssertEqual(calls.counts[506], 2)
    }

    // MARK: - retry-after parsing

    func testRetryAfterHeaderParsing() {
        XCTAssertEqual(AnthropicClient.retryAfterSeconds("12"), 12)
        XCTAssertEqual(AnthropicClient.retryAfterSeconds(" 30 "), 30)
        XCTAssertNil(AnthropicClient.retryAfterSeconds(nil))
        XCTAssertNil(AnthropicClient.retryAfterSeconds(""))
        XCTAssertNil(AnthropicClient.retryAfterSeconds("soon"))
        XCTAssertNil(AnthropicClient.retryAfterSeconds("-5"), "a past deadline is no hint at all")

        let future = Date().addingTimeInterval(45)
        let header = AnthropicClient.httpDateFormatter.string(from: future)
        let parsed = AnthropicClient.retryAfterSeconds(header)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed ?? 0, 45, accuracy: 2)
    }
}
