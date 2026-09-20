import Foundation
import CryptoKit
import SwiftData

/// Everything a resumable statement import needs to survive the app closing
/// (#639), encoded as JSON onto `LocalStatementImport.resumeStateJSON`.
///
/// A struct rather than ten SwiftData columns: one additive column is the
/// smallest possible migration on a model that already syncs and exports, and a
/// later field costs no further migration at all. `version` is here so a future
/// shape change can be detected and dropped rather than mis-decoded.
///
/// The PDF bytes are NOT in here. They live on disk under
/// `Documents/statement-resumes/`, exactly as receipt images do (#247), and
/// this record names the relative path. A 2.4 MB statement inside the store
/// would be copied by every sync pass and every backup.
struct StatementResumeRecord: Codable, Equatable, Sendable {
    /// Bumped when the shape changes. A record from an unknown version is
    /// reaped rather than read.
    var version: Int = 1

    /// Relative path of the stored PDF, e.g. "statement-resumes/<uuid>.pdf".
    /// Relative for the same reason `LocalExpense.receiptImagePath` is: the
    /// absolute container path changes on every reinstall.
    var pdfPath: String

    /// SHA256 of the bytes that were written, lower-case hex.
    ///
    /// The ONLY hash in this feature, and it is a sanity check, never a lookup
    /// key. A statement picked from the file picker is always read in full,
    /// every page, every time: the user may have deleted rows and want the
    /// whole file parsed again, and a fresh import is how they ask for that.
    /// This hash answers one question only, at restore time: are these the
    /// bytes this resume point was computed against?
    var sha256: String

    /// Byte count of the stored PDF, so a truncated file is caught before the
    /// hash is even computed.
    var byteCount: Int

    /// The picked file's name, e.g. "Citi_May2026.pdf". Empty when the picker
    /// gave none.
    var fileName: String

    /// `LocalTrip.clientUUID` when the run belongs to a trip, nil for Finance.
    /// A restored job has to come back in the scope it belongs to: a trip
    /// import's rows are `hiddenFromFinance` (#277), so a Finance banner would
    /// point at rows Finance is not counting.
    var tripUUID: UUID?

    /// The #635 resume point, field for field.
    var chunksCompleted: Int
    var chunksTotal: Int

    /// The statement header the earlier run read off page 1, carried forward so
    /// resumed rows keep their card attribution (#189). Page 1 is never read
    /// again on a resume.
    var issuer: String?
    var last4: String?
    var statementMonth: Int?
    var statementYear: Int?

    /// The outcome text the restored row shows when it is tapped, so a
    /// relaunched job says exactly what the job it replaces said.
    var outcomeText: String

    /// True when that text was a failure alert rather than an incomplete
    /// summary, so the restored job reopens in the right alert.
    var outcomeIsFailure: Bool

    /// When this state was written, for the age bound.
    var savedAt: Date

    /// The resume point, rebuilt.
    var resumePoint: StatementResumePoint {
        StatementResumePoint(
            chunksCompleted: chunksCompleted,
            chunksTotal: chunksTotal,
            meta: ExtractedStatementMeta(
                issuer: issuer,
                last4: last4,
                statementMonth: statementMonth,
                statementYear: statementYear
            )
        )
    }
}

/// Durable half of the Resume affordance (#639).
///
/// #635 gave an interrupted statement import a resume plan that reads only the
/// unread chunks. That plan lived in memory on `ImportJobCenter`, so a
/// force-quit, a crash or a relaunch discarded it and the only way to finish
/// the file was to pay for the whole thing again. This store keeps the plan and
/// the bytes it was computed against, and hands them back as a job on the next
/// launch.
///
/// Scope of the durability is deliberately narrow. `ImportJob` and its
/// `ResumePlan` stay memory-only for every other kind of job: a receipt read
/// has nothing to resume, and making the whole job centre durable would put
/// transient UI state in the store. Only a STATEMENT run that ended with
/// unread chunks is written here.
///
/// What it never does: look a file up by hash. An import started from the file
/// picker reads every page, every time. The hash on the record is a binding
/// check for the bytes a RESTORED job resumes, nothing more.
@MainActor
final class StatementResumeStore {
    static let shared = StatementResumeStore()

    /// How long an abandoned resume may keep its PDF. Two weeks is past any
    /// plausible "I will top the credits up later" and short enough that an
    /// abandoned 2.4 MB file is not a permanent resident.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    /// Subdirectory under Documents, mirroring `ReceiptStorage`'s layout.
    static let directoryName = "statement-resumes"

    /// Deferred so touching `ImportJobCenter.shared` cannot force
    /// `SwiftDataStore.shared` to bootstrap ahead of the app's own container.
    private let storeProvider: () -> SwiftDataStore

    /// Test seam: the Documents root to write under. nil uses the real one.
    private let rootOverride: URL?

    /// Test seam for the age bound.
    private let clock: () -> Date

    private let fileManager = FileManager.default

    init(
        storeProvider: @escaping () -> SwiftDataStore = { .shared },
        root: URL? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.storeProvider = storeProvider
        self.rootOverride = root
        self.clock = clock
    }

    private var store: SwiftDataStore { storeProvider() }

    // MARK: - Writing

    /// Persist a resume plan and the bytes it was computed against, and return
    /// the `LocalStatementImport` row that now carries it.
    ///
    /// Returns nil when there is nothing to resume or the write failed, in
    /// which case the caller keeps exactly today's behaviour: an in-memory plan
    /// that dies with the process.
    ///
    /// At most one pending resume per scope. A statement is 180 KB to 2.4 MB
    /// and a history of abandoned ones is not worth keeping, so a new pending
    /// run in a scope replaces the one before it, file included.
    @discardableResult
    func save(
        plan: ImportJob.ResumePlan,
        scope: ImportJob.Scope,
        outcome: ImportJob.Outcome
    ) -> UUID? {
        guard plan.point.hasUnreadChunks, !plan.pdfData.isEmpty else { return nil }

        let tripUUID: UUID?
        switch scope {
        case .finance:          tripUUID = nil
        case .trip(let uuid):   tripUUID = uuid
        }

        clearAll(in: scope)

        guard let relativePath = writePDF(plan.pdfData) else { return nil }

        let isFailure: Bool
        if case .failure = outcome { isFailure = true } else { isFailure = false }

        let record = StatementResumeRecord(
            pdfPath: relativePath,
            sha256: Self.hash(plan.pdfData),
            byteCount: plan.pdfData.count,
            fileName: plan.fileName ?? "",
            tripUUID: tripUUID,
            chunksCompleted: plan.point.chunksCompleted,
            chunksTotal: plan.point.chunksTotal,
            issuer: plan.point.meta.issuer,
            last4: plan.point.meta.last4,
            statementMonth: plan.point.meta.statementMonth,
            statementYear: plan.point.meta.statementYear,
            outcomeText: outcome.message,
            outcomeIsFailure: isFailure,
            savedAt: clock()
        )
        guard let json = Self.encode(record) else {
            try? deleteFile(relativePath)
            return nil
        }

        // A counts-free row, so it reads as a placeholder everywhere that
        // matters: the history list and the archive both leave it out.
        let row = LocalStatementImport(
            fileName: record.fileName,
            statementLabel: "",
            imported: 0,
            skippedDuplicates: 0,
            ignoredNonSpend: 0,
            failed: 0,
            refunds: 0,
            possiblyTruncated: false,
            createdAt: clock()
        )
        row.resumeStateJSON = json
        store.context.insert(row)
        try? store.context.save()
        return row.clientUUID
    }

    /// Forget one pending resume: the row and the PDF both go. Called when the
    /// user acknowledges or dismisses the job.
    func clear(recordUUID: UUID) {
        guard let row = row(with: recordUUID) else { return }
        delete(row)
        try? store.context.save()
    }

    /// Forget every pending resume in a scope.
    func clearAll(in scope: ImportJob.Scope) {
        let tripUUID: UUID?
        switch scope {
        case .finance:          tripUUID = nil
        case .trip(let uuid):   tripUUID = uuid
        }
        var changed = false
        for (row, record) in pendingRows() where record.tripUUID == tripUUID {
            delete(row)
            changed = true
        }
        if changed { try? store.context.save() }
    }

    // MARK: - Reading back

    /// Every pending resume that is still good, rebuilt as a finished
    /// `ImportJob` ready to be shown with its Resume affordance.
    ///
    /// Anything that is not good is reaped on the way through: past the age
    /// bound, missing its PDF, the wrong size, or the wrong hash. A record whose
    /// bytes do not hash to what was stored is REFUSED rather than resumed: a
    /// half-written or swapped file would otherwise be read from the middle of a
    /// statement it is not.
    func restoreJobs() -> [ImportJob] {
        reapExpired()
        reapOrphanFiles()

        var jobs: [ImportJob] = []
        var changed = false
        for (row, record) in pendingRows() {
            guard let data = verifiedPDF(for: record) else {
                delete(row)
                changed = true
                continue
            }
            let scope: ImportJob.Scope = record.tripUUID.map { .trip($0) } ?? .finance
            let subject = record.fileName.isEmpty ? nil : record.fileName
            var job = ImportJob(
                id: UUID(),
                kind: .statement,
                scope: scope,
                subject: subject,
                isResuming: false,
                outcome: record.outcomeIsFailure
                    ? .failure(record.outcomeText)
                    : .incomplete(record.outcomeText)
            )
            job.resume = ImportJob.ResumePlan(
                pdfData: data,
                fileName: subject,
                point: record.resumePoint,
                recordUUID: row.clientUUID
            )
            jobs.append(job)
        }
        if changed { try? store.context.save() }
        return jobs
    }

    /// Drop every pending resume past the age bound, file included, so an
    /// import abandoned months ago cannot sit on megabytes forever.
    func reapExpired() {
        let cutoff = clock().addingTimeInterval(-Self.maxAge)
        var changed = false
        for (row, record) in pendingRows() where record.savedAt < cutoff {
            delete(row)
            changed = true
        }
        if changed { try? store.context.save() }
    }

    /// Delete any PDF in the directory that no pending record names. Covers the
    /// row deleted by a peer sync, a restore from backup, or a write that
    /// landed just before a crash.
    func reapOrphanFiles() {
        guard let dir = try? ensureDirectory() else { return }
        let referenced = Set(pendingRows().map(\.1.pdfPath))
        let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where !name.hasPrefix(".") {
            let relative = "\(Self.directoryName)/\(name)"
            guard !referenced.contains(relative) else { continue }
            try? fileManager.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Internals

    /// Rows that carry resume state, paired with the decoded payload. A row
    /// whose JSON will not decode, or that carries an unknown version, is
    /// dropped here rather than surfaced.
    private func pendingRows() -> [(LocalStatementImport, StatementResumeRecord)] {
        let descriptor = FetchDescriptor<LocalStatementImport>(
            predicate: #Predicate { $0.resumeStateJSON != "" }
        )
        let rows = (try? store.context.fetch(descriptor)) ?? []
        return rows.compactMap { row in
            guard let record = Self.decode(row.resumeStateJSON), record.version == 1 else {
                // Undecodable state is not recoverable state. Strip it so the
                // row stops claiming a resume it cannot honour.
                row.resumeStateJSON = ""
                return nil
            }
            return (row, record)
        }
    }

    private func row(with uuid: UUID) -> LocalStatementImport? {
        let descriptor = FetchDescriptor<LocalStatementImport>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        return (try? store.context.fetch(descriptor))?.first
    }

    /// Remove a pending row's file, then the row itself if it is a placeholder.
    /// Does NOT save; callers batch that.
    private func delete(_ row: LocalStatementImport) {
        if let record = Self.decode(row.resumeStateJSON) {
            try? deleteFile(record.pdfPath)
        }
        row.resumeStateJSON = ""
        // The counts-free row exists only for the resume. A row that recorded a
        // real import (there is none today, but a future caller could attach
        // state to one) keeps its place in the history.
        if row.imported == 0, row.skippedDuplicates == 0, row.ignoredNonSpend == 0,
           row.failed == 0, row.refunds == 0, row.deposits == 0 {
            store.context.delete(row)
        }
    }

    /// The bytes, only when they are demonstrably the bytes this record was
    /// written for.
    private func verifiedPDF(for record: StatementResumeRecord) -> Data? {
        guard let url = try? absoluteURL(for: record.pdfPath),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              data.count == record.byteCount,
              Self.hash(data) == record.sha256
        else { return nil }
        return data
    }

    private func writePDF(_ data: Data) -> String? {
        guard let dir = try? ensureDirectory() else { return nil }
        let name = "\(UUID().uuidString.lowercased()).pdf"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: [.atomic])
        } catch {
            NSLog("StatementResumeStore: could not store the statement: %@", error.localizedDescription)
            return nil
        }
        return "\(Self.directoryName)/\(name)"
    }

    private func deleteFile(_ relativePath: String) throws {
        guard !relativePath.isEmpty else { return }
        let url = try absoluteURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func documentsDirectory() throws -> URL {
        if let rootOverride {
            try fileManager.createDirectory(at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        return try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func ensureDirectory() throws -> URL {
        let dir = try documentsDirectory()
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func absoluteURL(for relativePath: String) throws -> URL {
        try documentsDirectory().appendingPathComponent(relativePath)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ record: StatementResumeRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ json: String) -> StatementResumeRecord? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatementResumeRecord.self, from: data)
    }
}
