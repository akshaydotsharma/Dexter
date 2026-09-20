import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
    ///
    /// Three finished cases, because the banner label follows the outcome
    /// (#637) and "read the whole file" and "read part of the file" are not
    /// the same result. `incomplete` covers every way a run can finish short:
    /// the user stopped it, a chunk died, or a page range stayed truncated
    /// after the re-split. Which of those it was is in the summary text
    /// itself; the banner only needs the three-way split.
    enum Outcome: Equatable {
        /// `StatementImportResult.summaryLine`, or the receipt equivalent.
        case summary(String)
        /// The run finished, carrying a summary, but did not read everything.
        case incomplete(String)
        case failure(String)

        /// Pick the flavour from whether the run read the whole file. Lets a
        /// call site write `.summary(text, complete: result.isComplete)`
        /// rather than branching at each of the two import screens.
        static func summary(_ text: String, complete: Bool) -> Outcome {
            complete ? .summary(text) : .incomplete(text)
        }

        /// The text to show, whichever flavour this is.
        var message: String {
            switch self {
            case .summary(let text), .incomplete(let text), .failure(let text):
                return text
            }
        }
    }

    let id: UUID
    let kind: Kind
    let scope: Scope

    /// What is being read, e.g. "Citi_May2026.pdf" (#189). nil falls back to
    /// the kind's generic copy.
    ///
    /// The FILE NAME, not a finished sentence (#637). The two import screens
    /// used to hand in a built label ("Importing Citi_May2026.pdf…"), which is
    /// why a finished job still read "Importing" beside a green tick: the
    /// label was fixed at the start and nothing could revise it. Holding the
    /// subject instead lets `displayLabel` below build every phase from the
    /// job's own state, in one place.
    let subject: String?

    /// True when this run is finishing a previous one rather than starting
    /// fresh, which is the only thing the running label needs to say
    /// differently ("Resuming" rather than "Importing", #635).
    let isResuming: Bool

    /// Chunks extracted so far, and how many there are in total (#498). A
    /// statement is split into 3-page chunks and each is a separate, sequential
    /// Anthropic call, so a 30-page statement is ten calls over several
    /// minutes. Without this the banner is identical at chunk 1 and chunk 10,
    /// which is what made a slow import indistinguishable from a hung one.
    /// `totalParts <= 1` means there is nothing worth counting.
    var completedParts: Int = 0
    var totalParts: Int = 0

    var outcome: Outcome?

    /// Everything a later attempt needs to finish an incomplete run (#635).
    /// Set when the extraction ended early with chunks still unread, whether
    /// the user stopped it or a chunk failed. nil on a complete run, so the
    /// Resume affordance only appears when there is something left to read.
    var resume: ResumePlan?

    /// The file and the point to pick up from. Holds the PDF bytes because
    /// the picker's security-scoped URL is long gone by the time the user taps
    /// Resume, and because `ImportJobCenter` is memory-only anyway (#498): a
    /// relaunch clears the plan along with the job.
    struct ResumePlan: Equatable {
        let pdfData: Data
        let fileName: String?
        let point: StatementResumePoint
    }

    var isFinished: Bool { outcome != nil }

    /// True when the row should offer Resume rather than a plain dismissal.
    var canResume: Bool { isFinished && resume != nil }

    /// The label actually rendered, for the phase the job is in (#637).
    ///
    /// Before this ticket the label was built once by the caller and only had
    /// its trailing ellipsis stripped on finish, so a completed run rendered
    /// "Importing 9_Aug_2026_-_8_Sep_2026.pdf" next to a green tick. Now a
    /// finished job reads Imported / Import incomplete / Import failed, off
    /// its own `outcome`.
    var displayLabel: String {
        isFinished ? finishedLabel : runningLabel
    }

    /// "Importing Citi_May2026.pdf…", "Resuming Citi_May2026.pdf…", or the
    /// kind's generic copy when there is no file name. The ellipsis is the
    /// work-in-progress marker and belongs only here.
    private var runningLabel: String {
        guard let subject, !subject.isEmpty else { return kind.label }
        return isResuming ? "Resuming \(subject)…" : "Importing \(subject)…"
    }

    /// The outcome as a phrase, with the file name when there is one.
    ///
    /// The happy case reads as a plain past tense ("Imported Citi_May.pdf").
    /// The two unhappy ones lead with the verdict and follow with the file
    /// after a colon, because the verdict is the part that must survive the
    /// row's middle truncation.
    private var finishedLabel: String {
        let verdict: String
        switch outcome {
        case .summary:    verdict = "Imported"
        case .incomplete: verdict = "Import incomplete"
        case .failure:    verdict = "Import failed"
        case .none:       return runningLabel
        }
        guard let subject, !subject.isEmpty else { return verdict }
        if case .summary = outcome { return "\(verdict) \(subject)" }
        return "\(verdict): \(subject)"
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
    /// `subject` is the FILE NAME, not a built label (#637): the job owns
    /// every phase of its own wording, so a finished run can stop saying
    /// "Importing".
    func begin(
        kind: ImportJob.Kind,
        scope: ImportJob.Scope,
        subject: String? = nil,
        isResuming: Bool = false
    ) -> (id: UUID, token: ImportCancellationToken) {
        let id = UUID()
        let token = ImportCancellationToken()
        tokens[id] = token
        jobs.append(ImportJob(
            id: id,
            kind: kind,
            scope: scope,
            subject: subject,
            isResuming: isResuming,
            outcome: nil
        ))
        refreshSystemAssertions()
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
    ///
    /// `resume` is the plan for finishing an incomplete run (#635). Passed for
    /// a summary whose extraction ended early with chunks unread, and also for
    /// a FAILURE on a resumed run, so one dead retry does not throw away a
    /// resume point the user can still use.
    func finish(_ id: UUID, outcome: ImportJob.Outcome, resume: ImportJob.ResumePlan? = nil) {
        tokens[id] = nil
        defer { refreshSystemAssertions() }
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].outcome = outcome
        jobs[index].resume = resume
    }

    /// Remove a finished job once the user has seen its outcome.
    func acknowledge(_ id: UUID) {
        tokens[id] = nil
        jobs.removeAll { $0.id == id }
        refreshSystemAssertions()
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
        refreshSystemAssertions()
    }

    // MARK: - Keeping the run alive (#635)

    /// True while any registered job is still working. The two system
    /// assertions below are held exactly for as long as this is true.
    var hasUnfinishedJobs: Bool { jobs.contains { !$0.isFinished } }

    /// Hold the screen awake and a background-task assertion while any import
    /// is unfinished, and release both the moment none is (#635).
    ///
    /// Centralised here rather than in each view because `begin` / `finish` /
    /// `acknowledge` / `discard` are the only four places a job's state can
    /// change, so this is the one point where the answer can never drift. It
    /// also means a receipt read gets the same protection a statement does,
    /// for free.
    ///
    /// The field failure this fixes: the phone auto-locked mid-import, iOS
    /// suspended the app a few seconds later, and the in-flight request to
    /// Anthropic died. Nothing here makes an import survive a LOCKED phone for
    /// its whole run (that needs a background `URLSession`, a re-architecture);
    /// it stops auto-lock from starting the sequence, and buys a brief
    /// backgrounding enough time to land.
    ///
    /// Both calls are UIKit, and this file is in the `DexterMac` sources list,
    /// so both sit behind `#if os(iOS)`. On macOS the method is a no-op: a Mac
    /// does not suspend a foreground app and has no idle-timer equivalent worth
    /// touching.
    private func refreshSystemAssertions() {
        #if os(iOS)
        let working = hasUnfinishedJobs
        UIApplication.shared.isIdleTimerDisabled = working
        if working {
            beginBackgroundAssertion()
        } else {
            endBackgroundAssertion()
        }
        #endif
    }

    #if os(iOS)
    /// `.invalid` means "we hold nothing". Every path in and out of this value
    /// goes through the two methods below, so the assertion can be taken at
    /// most once and is always released, including on `discard`.
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundAssertion() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Dexter import") { [weak self] in
            // iOS is about to reclaim the time it granted. Release the
            // assertion ourselves; failing to is what gets an app killed.
            // The expiration handler is called on the main thread.
            MainActor.assumeIsolated { self?.endBackgroundAssertion() }
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTaskID != .invalid else { return }
        let held = backgroundTaskID
        // Cleared BEFORE the call, so the expiration handler firing during
        // `endBackgroundTask` cannot end the same identifier twice.
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(held)
    }
    #endif
}
