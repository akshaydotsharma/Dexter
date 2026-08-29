import XCTest
@testable import PersonalDashboard

/// An import that outlives the screen that started it (#498).
///
/// The defect was that job state lived as `@State` on `FinanceView` while the
/// work ran on an unstructured `Task`. The section router is a plain `switch`,
/// so leaving Finance destroyed the view and discarded the state, but not the
/// import: rows kept landing while the spinner, the summary and the error alert
/// all vanished. A finished import was indistinguishable from one that never
/// ran.
///
/// These assert the contract that replaces it. `ImportJobCenter` is app-level,
/// so a running job is still there when the user comes back, and a finished one
/// waits until it has actually been read before it disappears.
@MainActor
final class ImportJobLifecycleTests: XCTestCase {

    /// Each test gets its own center rather than the singleton, so ordering
    /// between tests can never matter.
    private func makeCenter() -> ImportJobCenter { ImportJobCenter() }

    // MARK: - The core requirement

    /// The whole point of the ticket: a run that finishes while the user is on
    /// another screen is still there to be read when they return, and only goes
    /// once they have read it.
    func testFinishedJobStaysUntilItIsAcknowledged() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance, overrideLabel: "Importing Citi.pdf…")

        center.finish(id, outcome: .summary("Imported 42"))

        // Finished, but NOT gone: this is what the old `defer` removal got wrong.
        XCTAssertEqual(center.jobs(in: .finance).count, 1)
        XCTAssertEqual(center.jobs(in: .finance).first?.outcome, .summary("Imported 42"))
        XCTAssertTrue(center.jobs(in: .finance).first?.isFinished == true)

        center.acknowledge(id)

        XCTAssertTrue(center.jobs(in: .finance).isEmpty)
    }

    /// A failure has to survive on the same terms. Losing this one was the worst
    /// of the three, because a silently-failed import looked exactly like an
    /// import the user never started.
    func testFailedJobAlsoWaitsToBeRead() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance)

        center.finish(id, outcome: .failure("We couldn't read this statement."))

        XCTAssertEqual(center.jobs(in: .finance).first?.outcome, .failure("We couldn't read this statement."))

        center.acknowledge(id)
        XCTAssertTrue(center.jobs(in: .finance).isEmpty)
    }

    // MARK: - Progress

    func testProgressMakesALongRunDistinguishableFromAStuckOne() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance)

        // Nothing to count before the extractor knows the chunk count.
        XCTAssertNil(center.jobs(in: .finance).first?.progressLabel)

        center.reportProgress(id, completed: 3, total: 5)

        XCTAssertEqual(center.jobs(in: .finance).first?.progressLabel, "3 of 5")
    }

    /// A single-chunk statement reports (1, 1). One of one is not progress, so
    /// the row must not sprout a pointless counter.
    func testSingleChunkStatementShowsNoCounter() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance)

        center.reportProgress(id, completed: 1, total: 1)

        XCTAssertNil(center.jobs(in: .finance).first?.progressLabel)
    }

    /// The progress callback is awaited from the extractor while the insert pass
    /// may already have finished the job. A late report must not resurrect a
    /// row the user has just read.
    func testProgressAfterFinishDoesNotReviveTheRow() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .summary("Imported 42"))

        center.reportProgress(id, completed: 9, total: 10)

        XCTAssertNil(center.jobs(in: .finance).first?.progressLabel)
        XCTAssertEqual(center.jobs(in: .finance).first?.outcome, .summary("Imported 42"))
    }

    // MARK: - Scope

    /// A trip import's rows are `hiddenFromFinance` by default (#277), so its
    /// banner must not appear in Finance pointing at rows Finance is not
    /// counting.
    func testJobsAreScopedToTheSurfaceThatOwnsThem() {
        let center = makeCenter()
        let tripID = UUID()
        center.begin(kind: .statement, scope: .trip(tripID))
        center.begin(kind: .receipt, scope: .finance)

        XCTAssertEqual(center.jobs(in: .finance).count, 1)
        XCTAssertEqual(center.jobs(in: .finance).first?.kind, .receipt)
        XCTAssertEqual(center.jobs(in: .trip(tripID)).count, 1)
        XCTAssertEqual(center.jobs(in: .trip(tripID)).first?.kind, .statement)
        XCTAssertTrue(center.jobs(in: .trip(UUID())).isEmpty)
    }

    /// A receipt read ends by opening the expense editor, which only exists on
    /// the screen that started it. That path discards rather than leaving a
    /// summary row to tap.
    func testDiscardRemovesAJobWithNoOutcomeToRead() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .receipt, scope: .finance)

        center.discard(id)

        XCTAssertTrue(center.jobs(in: .finance).isEmpty)
    }

    // MARK: - Cancelling

    /// Cancel is a flag the extractor polls, NOT `Task.cancel()`. A cancelled
    /// Task would make the insert pass's FX lookups throw, so every non-SGD row
    /// already extracted would be counted as failed instead of imported.
    func testCancelSignalsTheTokenTheExtractorPolls() {
        let center = makeCenter()
        let (id, token) = center.begin(kind: .statement, scope: .finance)

        XCTAssertFalse(token.isCancelled)
        center.cancel(id)
        XCTAssertTrue(token.isCancelled)
    }

    /// The label loses its work-in-progress ellipsis once the run is over, so a
    /// finished row does not keep claiming to be busy.
    func testFinishedRowStopsReadingAsInProgress() {
        let center = makeCenter()
        let (id, _) = center.begin(kind: .statement, scope: .finance, overrideLabel: "Importing Citi.pdf…")

        XCTAssertEqual(center.jobs(in: .finance).first?.displayLabel, "Importing Citi.pdf…")

        center.finish(id, outcome: .summary("Imported 42"))

        XCTAssertEqual(center.jobs(in: .finance).first?.displayLabel, "Importing Citi.pdf")
    }

    // MARK: - What a stopped import tells the user

    /// Stopping is not truncation. Truncation means the model ran out of output
    /// budget; stopping means the user asked us to. The remedy differs, so the
    /// summary has to say which happened, and it must say that re-importing is
    /// safe (dedup makes it idempotent).
    func testStoppedImportExplainsThatImportingAgainIsSafe() {
        let result = StatementImportResult(
            imported: 80,
            refunds: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: false,
            importedUUIDs: [],
            stoppedEarly: true
        )

        let summary = result.summaryLine

        XCTAssertTrue(summary.contains("Import stopped"), summary)
        XCTAssertTrue(summary.contains("Imported 80"), summary)
        XCTAssertTrue(summary.contains("again"), summary)
        XCTAssertFalse(summary.contains("—"), "user-facing copy must carry no em dash")
    }

    /// A normal run is unaffected: no stop banner, just the counts.
    func testCompletedImportSummaryIsUnchanged() {
        let result = StatementImportResult(
            imported: 42,
            refunds: 3,
            skippedDuplicates: 8,
            ignoredNonSpend: 0,
            failed: 0,
            possiblyTruncated: false,
            importedUUIDs: []
        )

        let summary = result.summaryLine

        XCTAssertEqual(summary, "Imported 42 (including 3 credits) · Skipped 8 duplicates")
        XCTAssertFalse(summary.contains("Import stopped"))
    }
}
