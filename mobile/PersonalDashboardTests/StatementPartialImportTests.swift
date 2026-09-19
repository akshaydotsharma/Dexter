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

    private func chunks(_ count: Int) -> [Data] {
        (0..<count).map { Data("chunk-\($0)".utf8) }
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
    ) -> (Data) async throws -> StatementChunkResult {
        return { data in
            let index = Int(String(decoding: data, as: UTF8.self).dropFirst("chunk-".count)) ?? -1
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
        XCTAssertEqual(extraction.stopReason, .interrupted)
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
            extractChunk: { data in
                let index = Int(String(decoding: data, as: UTF8.self).dropFirst("chunk-".count)) ?? -1
                seen.record(index)
                // Ask to stop once two chunks are in, so the third boundary taps out.
                if index == 1 { token.cancel() }
                return (lines: [self.line(forChunk: index)], meta: self.emptyMeta, possiblyTruncated: false)
            }
        )

        XCTAssertEqual(extraction.stopReason, .stoppedByUser)
        XCTAssertNotEqual(extraction.stopReason, .interrupted)
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

        XCTAssertEqual(extraction.stopReason, .interrupted)
        XCTAssertEqual(extraction.resumePoint?.chunksCompleted, 6)
        XCTAssertEqual(extraction.resumePoint?.chunksTotal, 8)
        XCTAssertEqual(extraction.resumePoint?.hasUnreadChunks, true)
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
            incompleteReason: .interrupted
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
}
