import XCTest
import SwiftData
@testable import PersonalDashboard

/// An incomplete statement import that survives the app closing (#639).
///
/// #635 made Resume read only the chunks the last attempt missed, which is the
/// expensive half and is unchanged here. What it did not do is survive leaving
/// the app: the plan lived in memory on `ImportJobCenter`, so a force-quit, a
/// crash or a relaunch discarded it and the only way to finish the file was to
/// pay for the whole thing again. The real case was a 4-page Amex whose pages 1
/// to 3 extracted fine and whose page 4 died on an out-of-credit 400 (#638).
///
/// The scope rule these tests also pin down: skipping already-read pages is for
/// the RESUME path only. A statement picked from the file picker is read in
/// full, every page, every time, because the user may have deleted rows and a
/// fresh import is how they ask for the whole file to be parsed again.
@MainActor
final class StatementResumePersistenceTests: XCTestCase {

    // MARK: - Fixtures

    private var store: SwiftDataStore!
    private var root: URL!
    private var now: Date!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("statement-resume-tests-\(UUID().uuidString)", isDirectory: true)
        now = Date(timeIntervalSince1970: 1_780_000_000)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        store = nil
        root = nil
        now = nil
        super.tearDown()
    }

    /// A store whose Documents root is a throwaway directory and whose clock the
    /// test drives, so the age bound is testable without waiting two weeks.
    private func makeResumeStore() -> StatementResumeStore {
        StatementResumeStore(
            storeProvider: { [store] in store! },
            root: root,
            clock: { [weak self] in self?.now ?? Date() }
        )
    }

    private func makeCenter(_ resumeStore: StatementResumeStore) -> ImportJobCenter {
        ImportJobCenter(resumeStore: resumeStore)
    }

    private let citiMeta = ExtractedStatementMeta(
        issuer: "Citi", last4: "1234", statementMonth: 5, statementYear: 2026
    )

    private func plan(
        _ bytes: String = "the-whole-statement",
        fileName: String? = "Amex_Sep2026.pdf",
        completed: Int = 3,
        total: Int = 4
    ) -> ImportJob.ResumePlan {
        ImportJob.ResumePlan(
            pdfData: Data(bytes.utf8),
            fileName: fileName,
            point: StatementResumePoint(
                chunksCompleted: completed,
                chunksTotal: total,
                meta: citiMeta
            )
        )
    }

    /// Files sitting in the resume directory, by name.
    private func storedFiles() -> [String] {
        let dir = root.appendingPathComponent(StatementResumeStore.directoryName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    private func placeholderRows() -> [LocalStatementImport] {
        (try? store.context.fetch(FetchDescriptor<LocalStatementImport>())) ?? []
    }

    // MARK: - The core requirement

    /// A run that ended with chunks unread is still there, with its Resume
    /// affordance, after the process has gone away and come back.
    func testAnIncompleteRunSurvivesARelaunch() {
        let resumeStore = makeResumeStore()
        let before = makeCenter(resumeStore)

        let (id, _) = before.begin(kind: .statement, scope: .finance, subject: "Amex_Sep2026.pdf")
        before.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        XCTAssertEqual(storedFiles().count, 1, "the statement's bytes must be on disk, not in the store")

        // The relaunch: a brand new centre with no memory of the run at all.
        let after = makeCenter(resumeStore)
        XCTAssertTrue(after.jobs(in: .finance).isEmpty)

        after.restorePersistedStatementJobs()

        XCTAssertEqual(after.jobs(in: .finance).count, 1)
        let restored = after.jobs(in: .finance).first
        XCTAssertEqual(restored?.outcome, .incomplete("Imported 158"))
        XCTAssertTrue(restored?.canResume == true, "the whole point: Resume is still on the row")
        XCTAssertEqual(restored?.subject, "Amex_Sep2026.pdf")
        XCTAssertEqual(restored?.resume?.point.chunksCompleted, 3)
        XCTAssertEqual(restored?.resume?.point.chunksTotal, 4)
        XCTAssertEqual(restored?.resume?.pdfData, Data("the-whole-statement".utf8))
    }

    /// The header read off page 1 comes back with it, or every resumed row
    /// loses its card attribution (#189) the moment a relaunch is involved.
    func testTheRestoredPlanCarriesTheStatementHeader() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertEqual(after.jobs(in: .finance).first?.resume?.point.meta, citiMeta)
    }

    /// A trip import's rows are `hiddenFromFinance` (#277), so a restored trip
    /// job that landed in Finance would point at rows Finance is not counting.
    func testARestoredJobComesBackInTheScopeItBelongsTo() {
        let tripUUID = UUID()
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .trip(tripUUID))
        center.finish(id, outcome: .incomplete("Imported 12"), resume: plan())

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
        XCTAssertEqual(after.jobs(in: .trip(tripUUID)).count, 1)
    }

    /// Restore runs from a per-WINDOW `.task` on macOS, so it has to be a latch.
    func testRestoringTwiceDoesNotDuplicateTheJob() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        after.restorePersistedStatementJobs()

        XCTAssertEqual(after.jobs(in: .finance).count, 1)
    }

    // MARK: - Cleaning up

    /// A run that read the whole file has nothing to resume, so it must leave
    /// no row and no 2.4 MB file behind.
    func testACompletedRunLeavesNothingBehind() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)

        center.finish(id, outcome: .summary("Imported 187"))

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
    }

    /// Reading the outcome IS the acknowledgement, so the stored PDF goes with
    /// the row. An import the user dismissed must not keep megabytes alive.
    func testAcknowledgingDeletesTheStoredPDF() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())
        XCTAssertEqual(storedFiles().count, 1)

        center.acknowledge(id)

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
    }

    /// Same for the discard path, which is how a row leaves with no outcome to
    /// read at all.
    func testDiscardingDeletesTheStoredPDF() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        center.discard(id)

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)
    }

    /// A restored job that the user dismisses on the next launch clears the
    /// record it was restored FROM, not some other one.
    func testAcknowledgingARestoredJobAlsoDeletesItsFile() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        let restoredID = after.jobs(in: .finance).first!.id

        after.acknowledge(restoredID)

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)
    }

    /// One incomplete file at a time per scope. An unbounded history of
    /// abandoned statements is exactly what the size note in the ticket rules
    /// out.
    func testASecondIncompleteRunInAScopeReplacesTheFirst() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)

        let (first, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(first, outcome: .incomplete("Imported 158"), resume: plan("statement-one"))
        let (second, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(second, outcome: .incomplete("Imported 20"), resume: plan("statement-two"))

        XCTAssertEqual(storedFiles().count, 1)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        XCTAssertEqual(after.jobs(in: .finance).count, 1)
        XCTAssertEqual(after.jobs(in: .finance).first?.resume?.pdfData, Data("statement-two".utf8))
    }

    /// The age bound. An import abandoned two weeks ago cannot sit on its file
    /// forever.
    func testTheAgeBoundReapsAnAbandonedImport() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())
        XCTAssertEqual(storedFiles().count, 1)

        now = now.addingTimeInterval(StatementResumeStore.maxAge + 60)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
        XCTAssertTrue(storedFiles().isEmpty, "the PDF goes with the record it belonged to")
        XCTAssertTrue(placeholderRows().isEmpty)
    }

    /// Just inside the bound is still good, so the reaper cannot quietly eat a
    /// live resume.
    func testAnImportInsideTheAgeBoundIsKept() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        now = now.addingTimeInterval(StatementResumeStore.maxAge - 60)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertEqual(after.jobs(in: .finance).count, 1)
    }

    /// A file with no record naming it is dead weight, whatever left it there.
    func testAnOrphanFileIsReaped() throws {
        let resumeStore = makeResumeStore()
        let dir = root.appendingPathComponent(StatementResumeStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("abandoned".utf8).write(to: dir.appendingPathComponent("orphan.pdf"))

        _ = resumeStore.restoreJobs()

        XCTAssertTrue(storedFiles().isEmpty)
    }

    // MARK: - Bound to the bytes it came from

    /// The one use of a hash in this feature, and it is a sanity check. A
    /// half-written or swapped file is REFUSED, because resuming it would read
    /// from the middle of a statement it is not.
    func testAHashMismatchRefusesToResume() throws {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        // Same length, different bytes: the size check alone would pass it.
        let dir = root.appendingPathComponent(StatementResumeStore.directoryName, isDirectory: true)
        let file = dir.appendingPathComponent(storedFiles()[0])
        try Data("a-different-stmnt!!".utf8).write(to: file)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty, "better no offer than a resume of the wrong file")
        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)
    }

    /// A truncated file is caught too, and by the cheaper check.
    func testAHalfWrittenFileRefusesToResume() throws {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let dir = root.appendingPathComponent(StatementResumeStore.directoryName, isDirectory: true)
        try Data("the-whole".utf8).write(to: dir.appendingPathComponent(storedFiles()[0]))

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
    }

    /// The file deleted out from under the record (an OS purge, a restore from
    /// backup) leaves nothing to offer, and no dangling row either.
    func testAMissingFileRefusesToResume() throws {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let dir = root.appendingPathComponent(StatementResumeStore.directoryName, isDirectory: true)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(storedFiles()[0]))

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)
    }

    // MARK: - Honouring the #638 classification

    /// A rejection no retry can fix never becomes a stored resume, so it cannot
    /// come back after a relaunch offering a button guaranteed to fail.
    ///
    /// The two import screens make that call (`failure.canResume`), so the
    /// contract here is the one they rely on: no plan, nothing written.
    func testANonRetryableFailureRestoresWithoutAResumeAffordance() {
        let failure = StatementFailure.api(status: 400, message: "messages: invalid request")
        XCTAssertFalse(failure.canResume, "precondition from #638")

        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)

        // Exactly what FinanceView / TripDetailView do with this failure.
        center.finish(
            id,
            outcome: .failure(failure.failureAlertMessage),
            resume: failure.canResume ? plan() : nil
        )

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()
        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
    }

    /// Out of credit is the case from the field: topping up makes the very same
    /// request work, so it keeps Resume, and now keeps it across a relaunch.
    func testAnOutOfCreditFailureRestoresWithItsResumeAffordance() {
        let failure = StatementFailure.outOfCredit("Your credit balance is too low")
        XCTAssertTrue(failure.canResume, "precondition from #638")

        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(
            id,
            outcome: .failure(failure.failureAlertMessage),
            resume: failure.canResume ? plan() : nil
        )

        let after = makeCenter(resumeStore)
        after.restorePersistedStatementJobs()

        let restored = after.jobs(in: .finance).first
        XCTAssertTrue(restored?.canResume == true)
        // The failure comes back as a failure, so it reopens in the alert it
        // came from rather than as an "Import incomplete" summary.
        XCTAssertEqual(restored?.outcome, .failure(failure.failureAlertMessage))
    }

    // MARK: - The placeholder row stays out of everything it is not

    /// The resume row is bookkeeping, not a parsed file. It must not read as an
    /// empty import in the history, and it must not travel to another device or
    /// into a backup: it names a PDF in THIS container.
    func testTheResumeRowIsNotAnImportRecord() throws {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .statement, scope: .finance)
        center.finish(id, outcome: .incomplete("Imported 158"), resume: plan())

        let rows = placeholderRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isResumePlaceholder)

        let payload = try DataExportService(modelContext: store.context).buildPayload()
        XCTAssertTrue(
            (payload.statementImports ?? []).isEmpty,
            "a resume placeholder must never reach the archive or a sync peer"
        )
    }

    /// A real import record is untouched by any of this.
    func testARealImportRecordStillExports() throws {
        let real = LocalStatementImport(
            fileName: "Citi_May2026.pdf",
            statementLabel: "May 2026 Citi - 1234",
            imported: 42,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            refunds: 0,
            possiblyTruncated: false
        )
        store.context.insert(real)
        try store.context.save()

        XCTAssertFalse(real.isResumePlaceholder)
        let payload = try DataExportService(modelContext: store.context).buildPayload()
        XCTAssertEqual((payload.statementImports ?? []).count, 1)
    }

    // MARK: - The migration shape

    /// #555: an additive field without a default ON THE DECLARATION fails the
    /// container bootstrap for every existing install. A row built through the
    /// initialiser that predates the field must come out with the empty string,
    /// and must not claim a resume.
    func testTheAdditiveFieldDefaultsWithoutBeingPassed() throws {
        let row = LocalStatementImport(
            fileName: "Citi_May2026.pdf",
            statementLabel: "",
            imported: 3,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            refunds: 0,
            possiblyTruncated: false
        )
        store.context.insert(row)
        try store.context.save()

        XCTAssertEqual(row.resumeStateJSON, "")
        XCTAssertFalse(row.isResumePlaceholder)

        let after = makeCenter(makeResumeStore())
        after.restorePersistedStatementJobs()
        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
    }

    /// Resume state that will not decode is not recoverable state. The row must
    /// stop claiming a resume rather than surface one it cannot honour.
    func testUndecodableResumeStateIsDroppedRatherThanRestored() throws {
        let row = LocalStatementImport(
            fileName: "Citi_May2026.pdf",
            statementLabel: "",
            imported: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            refunds: 0,
            possiblyTruncated: false
        )
        row.resumeStateJSON = "{not json"
        store.context.insert(row)
        try store.context.save()

        let after = makeCenter(makeResumeStore())
        after.restorePersistedStatementJobs()

        XCTAssertTrue(after.jobs(in: .finance).isEmpty)
        XCTAssertEqual(row.resumeStateJSON, "")
    }

    // MARK: - Receipts stay memory-only

    /// `ImportJob` and its plan are memory-only on purpose for everything that
    /// is not a statement. A receipt read has nothing to resume, and making the
    /// whole job centre durable would put transient UI state in the store.
    func testAReceiptJobIsNeverWrittenToDisk() {
        let resumeStore = makeResumeStore()
        let center = makeCenter(resumeStore)
        let (id, _) = center.begin(kind: .receipt, scope: .finance)

        center.finish(id, outcome: .incomplete("Read 1 of 2"), resume: plan())

        XCTAssertTrue(storedFiles().isEmpty)
        XCTAssertTrue(placeholderRows().isEmpty)
        // The in-memory plan is untouched, so this run behaves exactly as before.
        XCTAssertTrue(center.jobs(in: .finance).first?.canResume == true)
        XCTAssertNil(center.jobs(in: .finance).first?.resume?.recordUUID)
    }
}
