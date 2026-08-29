import Foundation
import Observation

/// A capture or statement import that is running, or has finished and is
/// waiting to be acknowledged (#498).
///
/// Before #498 this state lived as `@State` on `FinanceView`. The section
/// router is a plain `switch` (`ContentView.swift`), so leaving Finance
/// destroyed the view and discarded it, while the import itself kept running
/// on an unstructured `Task`. The rows still landed and every trace of the run
/// vanished: no spinner on return, no summary alert, and a failure that looked
/// exactly like nothing having happened.
struct ImportJob: Identifiable, Equatable {
    enum Kind: Equatable {
        case receipt
        case statement

        /// Label shown while the job runs, when the caller supplies no
        /// file-name override.
        var label: String {
            switch self {
            case .receipt:   return "Reading receipt…"
            case .statement: return "Importing statement…"
            }
        }

        /// SF Symbol for the leading badge, matching each channel's menu icon
        /// so the row reads as "the thing I just picked".
        var sfSymbol: String {
            switch self {
            case .receipt:   return "doc.text.viewfinder"
            case .statement: return "doc.text.magnifyingglass"
            }
        }
    }

    /// Which surface renders the job. A trip statement import belongs to that
    /// trip's screen: its rows are `hiddenFromFinance` by default (#277), so
    /// showing the banner in Finance would point at rows Finance is not
    /// counting.
    enum Scope: Equatable {
        case finance
        /// `LocalTrip.clientUUID`.
        case trip(UUID)
    }

    /// How the run ended. `nil` while it is still going.
    enum Outcome: Equatable {
        /// `StatementImportResult.summaryLine`, or the receipt equivalent.
        case summary(String)
        case failure(String)
    }

    let id: UUID
    let kind: Kind
    let scope: Scope

    /// Per-instance label that overrides `kind.label`, e.g. "Importing
    /// Citi_May2026.pdf…" (#189). nil falls back to the kind's generic copy.
    let overrideLabel: String?

    /// Chunks extracted so far, and how many there are in total (#498). A
    /// statement is split into 3-page chunks and each is a separate, sequential
    /// Anthropic call, so a 30-page statement is ten calls over several
    /// minutes. Without this the banner is identical at chunk 1 and chunk 10,
    /// which is what made a slow import indistinguishable from a hung one.
    /// `totalParts <= 1` means there is nothing worth counting.
    var completedParts: Int = 0
    var totalParts: Int = 0

    var outcome: Outcome?

    var isFinished: Bool { outcome != nil }

    /// The label actually rendered: the override when present, otherwise the
    /// kind's generic copy. A finished job drops the trailing ellipsis, which
    /// is the work-in-progress marker.
    var displayLabel: String {
        let base = overrideLabel ?? kind.label
        guard isFinished else { return base }
        return base.hasSuffix("…") ? String(base.dropLast()) : base
    }

    /// "3 of 5" while a multi-chunk statement is being read, nil otherwise.
    var progressLabel: String? {
        guard !isFinished, totalParts > 1 else { return nil }
        return "\(completedParts) of \(totalParts)"
    }
}

/// A cancel signal the importer can poll without cancelling its `Task` (#498).
///
/// Deliberately NOT `Task.cancel()`. The insert pass converts every foreign
/// currency through `FXService`, which is a network call: a cancelled Task
/// would make each of those throw, so every non-SGD row already extracted
/// would be counted as failed instead of imported. Polling a flag lets the
/// extractor stop between chunks while the rows it already read still insert
/// normally. Re-importing later is idempotent (`ExpenseDedupe`), so a stopped
/// import self-heals.
final class ImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// App-level owner of in-flight and just-finished import jobs (#498).
///
/// A singleton for the same reason `SyncCoordinator` and
/// `EmailIngestCoordinator` are: the work outlives any one view. Views read
/// `jobs(in:)` and render; they no longer own the state, so navigating away
/// and back shows the run exactly as it stands.
///
/// Finished jobs stay in the list until the user taps one, which shows the
/// outcome and removes it. They are memory-only, so a relaunch clears anything
/// unacknowledged. That is intentional: the rows themselves are already in
/// SwiftData, and the Parsed Files & Imports history (#234) is the durable
/// record of a statement run.
@MainActor
@Observable
final class ImportJobCenter {
    static let shared = ImportJobCenter()

    private(set) var jobs: [ImportJob] = []

    /// Cancel tokens for the running jobs, keyed by job id. Kept out of
    /// `ImportJob` so the job stays a value type the view can diff.
    @ObservationIgnored private var tokens: [UUID: ImportCancellationToken] = [:]

    init() {}

    /// Jobs a given surface should render, oldest first.
    func jobs(in scope: ImportJob.Scope) -> [ImportJob] {
        jobs.filter { $0.scope == scope }
    }

    /// Register a job and return its id plus the token the importer polls.
    /// The caller keeps the id to report progress and the outcome.
    @discardableResult
    func begin(
        kind: ImportJob.Kind,
        scope: ImportJob.Scope,
        overrideLabel: String? = nil
    ) -> (id: UUID, token: ImportCancellationToken) {
        let id = UUID()
        let token = ImportCancellationToken()
        tokens[id] = token
        jobs.append(ImportJob(id: id, kind: kind, scope: scope, overrideLabel: overrideLabel, outcome: nil))
        return (id, token)
    }

    /// Report extraction progress. No-ops for a job that has already finished
    /// or been acknowledged, so a late callback can't resurrect a row.
    func reportProgress(_ id: UUID, completed: Int, total: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].isFinished else { return }
        jobs[index].completedParts = completed
        jobs[index].totalParts = total
    }

    /// Mark a job finished. The row stays visible, now tappable, until
    /// `acknowledge` removes it.
    func finish(_ id: UUID, outcome: ImportJob.Outcome) {
        tokens[id] = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].outcome = outcome
    }

    /// Remove a finished job once the user has seen its outcome.
    func acknowledge(_ id: UUID) {
        tokens[id] = nil
        jobs.removeAll { $0.id == id }
    }

    /// Ask a running job to stop after the chunk it is on. What it already
    /// read still imports; see `ImportCancellationToken`.
    func cancel(_ id: UUID) {
        tokens[id]?.cancel()
    }

    /// Drop a job outright, with no outcome to acknowledge. Used for a receipt
    /// capture that ends by opening an editor, where the result IS the
    /// feedback and a summary row would be noise.
    func discard(_ id: UUID) {
        tokens[id] = nil
        jobs.removeAll { $0.id == id }
    }
}
