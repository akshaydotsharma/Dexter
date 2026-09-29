import Foundation

/// One Shortcut capture waiting for, or done with, the model (#685).
///
/// ## Why the states are what they are
///
/// The one rule a resumed job must keep is "never write an item twice". The
/// pipeline auto-executes every tool call, so re-running a job that already
/// wrote a meal logs the meal again. A job's state therefore records WHETHER
/// A WRITE HAS STARTED, and it is saved to disk BEFORE each write
/// (`ChatToDrafts.Hooks.beforeWrite`), never after:
///
///   queued -> running -> writing -> done | failed
///
/// - `running`: the model loop is in progress and nothing has been written.
///   A job found here by a LATER process was stopped by iOS before any write,
///   so running it again is safe. It goes back to `queued`.
/// - `writing`: at least one `ExecuteDraftAction.run` has begun. A job found
///   here by a later process may have written some, all, or (if it died
///   between the save and the write) none of its items, and nothing on disk
///   says which. It is NOT re-run. It fails with a notification that says
///   part of it may have been saved and names the section to check.
///
/// Why not dedupe instead, and retry everything? There is no stable key to
/// dedupe on. A second model run over the same phrase picks new wording, a
/// new title, new numbers, and a fresh `clientUUID` for each row, so a
/// retried "had a chicken rice for lunch" is indistinguishable from eating it
/// twice. Asking the user to check is the only honest answer.
///
/// `session` tells a job this process is running apart from one a dead
/// process left behind. Each runner has its own random session id; a job in
/// `running` or `writing` under another session is stale.
struct CaptureJob: Codable, Sendable, Identifiable, Equatable {
    enum State: String, Codable, Sendable {
        case queued, running, writing, done, failed
        var isTerminal: Bool { self == .done || self == .failed }
    }

    let id: UUID
    let input: String
    let timezone: String
    let createdAt: Date
    var state: State = .queued
    /// Times a runner has STARTED this job. Bounded by `maxAttempts`, so a
    /// job iOS keeps killing does not spend tokens forever.
    var attempts: Int = 0
    var session: UUID? = nil
    /// Tools whose write began, in order. What the partial-failure
    /// notification names ("check Meals").
    var writeTools: [String] = []
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    /// Notification text, set when the job reaches a terminal state.
    var outcomeTitle: String? = nil
    var outcomeBody: String? = nil
    /// Where a tap on the notification lands (`AppSection.rawValue` + row id).
    var openSection: String? = nil
    var openID: String? = nil
    /// The notification for the terminal state has been handed to iOS.
    /// Saved separately from the state so a process killed between the two
    /// re-posts the notification on next launch. The notification id is the
    /// job id, so a re-post replaces rather than duplicates.
    var notified: Bool = false
}

/// The durable queue behind the Shortcut (#685): a small JSON file in
/// Application Support, written atomically, owned by one actor.
///
/// Not a SwiftData `@Model` on purpose. A new model table enters the sync
/// schema, the backup archive and every branch's `schemaModels`, and a build
/// that lacks it DROPS the table on launch (project memory:
/// branch_schema_drops_model_table, archive_coverage_gap). A capture queue is
/// device-local, short-lived and a few kilobytes: it needs none of that.
actor CaptureQueue {
    static let shared = CaptureQueue(fileURL: CaptureQueue.defaultFileURL)

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CaptureQueue.json")
    }

    /// Finished jobs kept for the log, newest last. Enough to read what
    /// happened to today's captures; small enough that the file stays tiny.
    static let keepFinished = 20

    let fileURL: URL
    private var jobs: [CaptureJob] = []
    private var loaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Has a job ever been queued on this device? Gates the notification
    /// permission prompt, so a fresh install is not asked on launch for a
    /// feature it has never used.
    nonisolated var hasFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Reads

    func all() -> [CaptureJob] {
        loadIfNeeded()
        return jobs
    }

    // MARK: - Writes

    /// Append a job and SAVE it before returning. Throws when the save fails,
    /// so the intent never says "Got it" about a phrase that is only in memory.
    @discardableResult
    func enqueue(input: String, timezone: String, now: Date = Date()) throws -> CaptureJob {
        loadIfNeeded()
        let job = CaptureJob(id: UUID(), input: input, timezone: timezone, createdAt: now)
        jobs.append(job)
        do {
            try save()
        } catch {
            jobs.removeAll { $0.id == job.id }
            throw error
        }
        CaptureQueueLog.line("enqueued job=\(job.shortID) pending=\(jobs.filter { !$0.state.isTerminal }.count)")
        return job
    }

    /// Settle every job a previous process left in flight. Safe to call on
    /// every pass: a job under `currentSession` is this process's own and is
    /// left alone.
    ///
    /// - `running` elsewhere: nothing was written, so back to `queued`, unless
    ///   it has used up `maxAttempts`, then `failed`.
    /// - `writing` elsewhere: `failed`, never re-run (see `CaptureJob`).
    func recoverInterrupted(currentSession: UUID, maxAttempts: Int) {
        loadIfNeeded()
        var changed = false
        for index in jobs.indices {
            let job = jobs[index]
            guard job.session != currentSession else { continue }
            switch job.state {
            case .running:
                if job.attempts >= maxAttempts {
                    jobs[index].finish(.failed, text: CaptureJobText.exhausted(attempts: job.attempts))
                    CaptureQueueLog.line("recover job=\(job.shortID) running -> failed (attempts=\(job.attempts))")
                } else {
                    jobs[index].state = .queued
                    jobs[index].session = nil
                    CaptureQueueLog.line("recover job=\(job.shortID) running -> queued (no write started, safe to retry)")
                }
                changed = true
            case .writing:
                jobs[index].finish(.failed, text: CaptureJobText.partial(tools: job.writeTools, reason: .interrupted))
                CaptureQueueLog.line("recover job=\(job.shortID) writing -> failed-partial, NOT re-run (tools=\(job.writeTools))")
                changed = true
            case .queued, .done, .failed:
                break
            }
        }
        if changed { saveLogged() }
    }

    /// The oldest queued job, moved to `running` under `session` and saved.
    func claimNext(session: UUID, now: Date = Date()) -> CaptureJob? {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else { return nil }
        jobs[index].state = .running
        jobs[index].session = session
        jobs[index].attempts += 1
        jobs[index].startedAt = now
        saveLogged()
        return jobs[index]
    }

    /// Record that a write is about to start. THROWS when the record cannot be
    /// saved, and the caller then does not write: an unrecorded write is the
    /// one thing that could later be repeated.
    func markWriting(id: UUID, tool: String) throws {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let before = jobs[index]
        jobs[index].state = .writing
        jobs[index].writeTools.append(tool)
        do {
            try save()
        } catch {
            jobs[index] = before
            throw error
        }
    }

    /// Back to `queued` after an iOS interruption with no write started.
    func requeue(id: UUID) {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .queued
        jobs[index].session = nil
        saveLogged()
    }

    func finish(id: UUID, state: CaptureJob.State, text: CaptureJobText.Content, now: Date = Date()) {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].finish(state, text: text, now: now)
        saveLogged()
    }

    /// Terminal jobs whose notification has not been posted yet.
    func unnotified() -> [CaptureJob] {
        loadIfNeeded()
        return jobs.filter { $0.state.isTerminal && !$0.notified }
    }

    /// Mark a job's notification posted, and drop old finished jobs.
    func markNotified(id: UUID) {
        loadIfNeeded()
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].notified = true
        let finished = jobs.filter { $0.state.isTerminal && $0.notified }
        if finished.count > Self.keepFinished {
            let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
            jobs.removeAll { drop.contains($0.id) }
        }
        saveLogged()
    }

    // MARK: - File

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            jobs = try Self.decoder.decode([CaptureJob].self, from: data)
        } catch {
            // A file this build cannot read is set aside, not overwritten, so
            // the phrases in it can still be read by hand.
            let aside = fileURL.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            CaptureQueueLog.line("queue file unreadable, moved to \(aside.lastPathComponent): \(error)")
            jobs = []
        }
    }

    private func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(jobs)
        // Atomic: a process killed mid-write leaves the old file whole.
        // Readable after first unlock, because a Shortcut can run on a locked
        // phone and the runner must still be able to read the queue.
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }

    private func saveLogged() {
        do { try save() } catch { CaptureQueueLog.line("queue save FAILED: \(error)") }
    }

    private static let encoder: JSONEncoder = {
        // Default date strategy (a Double), not `.iso8601`: ISO drops the
        // sub-second part, so a job would not read back equal to itself.
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}

extension CaptureJob {
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    mutating func finish(_ terminal: State, text: CaptureJobText.Content, now: Date = Date()) {
        state = terminal
        finishedAt = now
        outcomeTitle = text.title
        outcomeBody = text.body
        openSection = text.openSection
        openID = text.openID
        notified = false
    }
}

/// The notification wording the queue itself owns (#685). A finished run's
/// text comes from `CaptureToDashboardIntent.notificationText(for:)`, the same
/// words the dialog used to speak; these are the cases that did not exist
/// while the capture ran inside the intent.
enum CaptureJobText {
    struct Content: Equatable, Sendable {
        var title: String
        var body: String
        var openSection: String? = nil
        var openID: String? = nil
    }

    enum StopReason { case capped, interrupted }

    /// Stopped at our own cap. Same "Couldn't capture — " wording the timeout
    /// dialog used, so the message reads the same as it always has.
    static func capped(seconds: Double, tools: [String]) -> Content {
        if !tools.isEmpty { return partial(tools: tools, reason: .capped, seconds: seconds) }
        return Content(title: "Capture failed", body: "Couldn't capture — Capture timed out after \(format(seconds))s.")
    }

    /// "60", or "0.2" for a test's short cap.
    private static func format(_ seconds: Double) -> String {
        String(format: "%g", seconds)
    }

    /// Stopped after a write began, so some of it may be saved.
    static func partial(tools: [String], reason: StopReason, seconds: Double = Double(CaptureService.timeoutSeconds)) -> Content {
        let sections = orderedSections(for: tools)
        let place = sections.isEmpty ? "Dexter" : sections.joined(separator: " and ")
        let cause = reason == .capped
            ? "it timed out after \(format(seconds))s"
            : "iOS stopped Dexter"
        return Content(
            title: "Capture may be incomplete",
            body: "Couldn't finish — \(cause) after it started saving. Part of this may have been saved, so check \(place) before saying it again.",
            openSection: sectionRaw(for: tools.first)
        )
    }

    /// iOS kept stopping the job before it could write anything.
    static func exhausted(attempts: Int) -> Content {
        Content(
            title: "Capture failed",
            body: "Couldn't capture — iOS stopped Dexter \(attempts) times before it finished. Nothing was saved, so say it again."
        )
    }

    /// Section names a tool writes to, in first-written order, no repeats.
    static func orderedSections(for tools: [String]) -> [String] {
        var seen: [String] = []
        for tool in tools {
            guard let name = sectionName(forTool: tool), !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen
    }

    static func sectionName(forTool tool: String) -> String? {
        switch sectionRaw(for: tool) {
        case AppSection.meals.rawValue?: return "Meals"
        case AppSection.tasks.rawValue?: return "Tasks"
        case AppSection.notes.rawValue?: return "Notes"
        case AppSection.lists.rawValue?: return "Lists"
        case AppSection.itineraries.rawValue?: return "Trips"
        case AppSection.finance.rawValue?: return "Finance"
        default: return nil
        }
    }

    /// Tool name to section, by the noun in the name. Every write tool in
    /// `ToolDefinitions` carries one; order matters only for `itinerary_item`
    /// ("item" must not read as a list) and `folder` (a Notes folder).
    static func sectionRaw(for tool: String?) -> String? {
        guard let tool else { return nil }
        if tool.contains("meal") { return AppSection.meals.rawValue }
        if tool.contains("trip") || tool.contains("itinerary") { return AppSection.itineraries.rawValue }
        if tool.contains("expense") { return AppSection.finance.rawValue }
        if tool.contains("task") { return AppSection.tasks.rawValue }
        if tool.contains("note") || tool.contains("folder") { return AppSection.notes.rawValue }
        if tool.contains("list") { return AppSection.lists.rawValue }
        return nil
    }
}

/// One prefix for every queue line, so a console attach can be filtered:
/// `xcrun devicectl device process launch --console ... | grep CaptureQueue`.
/// `SyncLog.line` writes to NSLog (Console.app) AND stderr (the attach).
enum CaptureQueueLog {
    static let prefix = "[CaptureQueue]"
    static func line(_ message: String) {
        SyncLog.line("\(prefix) \(message)")
    }
}
