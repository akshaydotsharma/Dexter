import XCTest
@testable import PersonalDashboard

/// The Shortcut's background capture queue (#685).
///
/// Every test runs the queue against a temp file and a stub executor, so none
/// touches the real SwiftData store or the network. A "new process" is a new
/// `CaptureQueue` over the same file plus a new runner, which has a new session.
@MainActor
final class CaptureQueueTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureQueueTests-\(UUID().uuidString)")
            .appendingPathComponent("CaptureQueue.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Doubles

    private final class Recorder {
        var inputs: [String] = []
        var notified: [CaptureJob] = []
    }

    private final class FakeBackground: CaptureBackgroundTime {
        var expiration: (@MainActor () -> Void)?
        var begins = 0
        var ends = 0
        func begin(expiration: @escaping @MainActor () -> Void) {
            begins += 1
            self.expiration = expiration
        }
        func end() { ends += 1 }
        var remaining: TimeInterval? { 29.5 }
    }

    private static func executed(_ title: String) -> CaptureResponse {
        CaptureResponse(
            status: .executed,
            executed: [ExecutedDraft(type: "note", action: "created", id: UUID().uuidString, title: title, dueDate: nil, addedNames: nil)],
            failed: nil, assistantText: nil, followUpQuestion: nil, errors: nil
        )
    }

    private func makeRunner(
        cap: Double = 5,
        recorder: Recorder,
        background: FakeBackground? = nil,
        executor: @escaping CaptureQueueRunner.Executor
    ) -> CaptureQueueRunner {
        CaptureQueueRunner(
            queue: CaptureQueue(fileURL: fileURL),
            capSeconds: cap,
            executor: executor,
            notifier: { job in recorder.notified.append(job); return "delivered" },
            background: background ?? FakeBackground()
        )
    }

    // MARK: - Order and persistence

    func testJobsRunOneAtATimeInTheOrderTheyWereQueued() async throws {
        let recorder = Recorder()
        var inFlight = 0
        var maxInFlight = 0
        let runner = makeRunner(recorder: recorder) { job, _ in
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            recorder.inputs.append(job.input)
            try? await Task.sleep(nanoseconds: 20_000_000)
            inFlight -= 1
            return Self.executed(job.input)
        }
        for input in ["first", "second", "third"] {
            try await runner.queue.enqueue(input: input, timezone: "Asia/Singapore")
        }
        runner.kick(reason: "test")
        await runner.waitUntilIdle()

        XCTAssertEqual(recorder.inputs, ["first", "second", "third"])
        XCTAssertEqual(maxInFlight, 1, "the runner must never run two jobs at once")
        let jobs = await runner.queue.all()
        XCTAssertEqual(jobs.map(\.state), [.done, .done, .done])
        XCTAssertEqual(recorder.notified.map(\.input), ["first", "second", "third"])
        XCTAssertEqual(recorder.notified.first?.outcomeBody, "Added note \"first\".",
                       "the notification reuses the dialog text the intent used to speak")
        XCTAssertTrue(jobs.allSatisfy(\.notified))
    }

    func testAQueuedJobSurvivesANewQueueInstance() async throws {
        let first = CaptureQueue(fileURL: fileURL)
        let job = try await first.enqueue(input: "had chicken rice for lunch", timezone: "Asia/Singapore")

        let second = CaptureQueue(fileURL: fileURL)
        let loaded = await second.all()
        XCTAssertEqual(loaded, [job], "every field round-trips through the file")
        XCTAssertEqual(loaded.first?.state, .queued)
    }

    func testAJobQueuedDuringAPassStillRuns() async throws {
        let recorder = Recorder()
        var runner: CaptureQueueRunner!
        runner = makeRunner(recorder: recorder) { job, _ in
            recorder.inputs.append(job.input)
            if job.input == "first" {
                // Enqueued mid-pass, then kicked, as the intent does.
                try? await runner.queue.enqueue(input: "late", timezone: "UTC")
                runner.kick(reason: "shortcut")
            }
            return Self.executed(job.input)
        }
        try await runner.queue.enqueue(input: "first", timezone: "UTC")
        runner.kick(reason: "test")
        await runner.waitUntilIdle()
        XCTAssertEqual(recorder.inputs, ["first", "late"])
    }

    // MARK: - The 60 s cap

    func testAJobPastTheCapFailsAndTheNextJobRuns() async throws {
        let recorder = Recorder()
        let runner = makeRunner(cap: 0.2, recorder: recorder) { job, _ in
            recorder.inputs.append(job.input)
            if job.input == "slow" {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return Self.executed(job.input)
        }
        try await runner.queue.enqueue(input: "slow", timezone: "UTC")
        try await runner.queue.enqueue(input: "fast", timezone: "UTC")

        let started = Date()
        runner.kick(reason: "test")
        await runner.waitUntilIdle()

        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the cap cancelled the slow job instead of waiting it out")
        XCTAssertEqual(recorder.inputs, ["slow", "fast"])
        let jobs = await runner.queue.all()
        XCTAssertEqual(jobs.map(\.state), [.failed, .done])
        XCTAssertEqual(jobs[0].attempts, 1, "a capped job is terminal, never retried")
        XCTAssertEqual(recorder.notified.first?.outcomeBody, "Couldn't capture — Capture timed out after 0.2s.")
    }

    func testACappedJobThatStartedWritingSaysToCheck() async throws {
        let recorder = Recorder()
        let runner = makeRunner(cap: 0.2, recorder: recorder) { job, hooks in
            try? await hooks.beforeWrite?("log_meal")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return Self.executed(job.input)
        }
        try await runner.queue.enqueue(input: "lunch", timezone: "UTC")
        runner.kick(reason: "test")
        await runner.waitUntilIdle()

        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.writeTools, ["log_meal"])
        XCTAssertTrue(job.outcomeBody?.contains("check Meals") == true, job.outcomeBody ?? "nil")
    }

    // MARK: - Resume after iOS stopped the app

    func testAJobLeftRunningWithNoWritesIsRetried() async throws {
        // The dead process: claimed the job, never reached a write.
        let dead = CaptureQueue(fileURL: fileURL)
        try await dead.enqueue(input: "buy milk", timezone: "UTC")
        _ = await dead.claimNext(session: UUID())

        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder) { job, _ in
            recorder.inputs.append(job.input)
            return Self.executed(job.input)
        }
        runner.kick(reason: "launch")
        await runner.waitUntilIdle()

        XCTAssertEqual(recorder.inputs, ["buy milk"])
        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.attempts, 2)
    }

    func testAJobLeftAfterAWriteStartedIsNeverRerun() async throws {
        let dead = CaptureQueue(fileURL: fileURL)
        let queued = try await dead.enqueue(input: "had chicken rice", timezone: "UTC")
        _ = await dead.claimNext(session: UUID())
        try await dead.markWriting(id: queued.id, tool: "log_meal")

        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder) { job, _ in
            recorder.inputs.append(job.input)
            return Self.executed(job.input)
        }
        runner.kick(reason: "launch")
        await runner.waitUntilIdle()

        XCTAssertEqual(recorder.inputs, [], "re-running would write the meal twice")
        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(recorder.notified.count, 1)
        XCTAssertTrue(job.outcomeBody?.contains("check Meals") == true, job.outcomeBody ?? "nil")
    }

    func testAJobIOSKeepsStoppingFailsAfterItsAttempts() async throws {
        let dead = CaptureQueue(fileURL: fileURL)
        try await dead.enqueue(input: "note: ideas", timezone: "UTC")
        for _ in 0..<CaptureQueueRunner.maxAttempts {
            _ = await dead.claimNext(session: UUID())
            // Each dead process leaves it running; the next one requeues it.
            await dead.recoverInterrupted(currentSession: UUID(), maxAttempts: 99)
        }
        _ = await dead.claimNext(session: UUID())

        let recorder = Recorder()
        let runner = makeRunner(recorder: recorder) { job, _ in
            recorder.inputs.append(job.input)
            return Self.executed(job.input)
        }
        runner.kick(reason: "launch")
        await runner.waitUntilIdle()
        XCTAssertEqual(recorder.inputs, [])
        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .failed)
    }

    // MARK: - Background time expiring in this process

    func testExpiryBeforeAWriteLeavesTheJobQueued() async throws {
        let recorder = Recorder()
        let background = FakeBackground()
        let runner = makeRunner(recorder: recorder, background: background) { job, _ in
            recorder.inputs.append(job.input)
            background.expiration?()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return Self.executed(job.input)
        }
        try await runner.queue.enqueue(input: "call John", timezone: "UTC")
        runner.kick(reason: "shortcut")
        await runner.waitUntilIdle()

        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .queued, "resumable on the next launch or foreground")
        XCTAssertTrue(recorder.notified.isEmpty)
        XCTAssertGreaterThanOrEqual(background.ends, 1, "the background task is always given back")
    }

    func testExpiryAfterAWriteFailsPartialInsteadOfRequeueing() async throws {
        let recorder = Recorder()
        let background = FakeBackground()
        let runner = makeRunner(recorder: recorder, background: background) { job, hooks in
            try? await hooks.beforeWrite?("draft_task")
            background.expiration?()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return Self.executed(job.input)
        }
        try await runner.queue.enqueue(input: "call John", timezone: "UTC")
        runner.kick(reason: "shortcut")
        await runner.waitUntilIdle()

        let all = await runner.queue.all()
        let job = try XCTUnwrap(all.first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.outcomeBody?.contains("check Tasks") == true, job.outcomeBody ?? "nil")
    }

    // MARK: - Text

    func testNotificationTextMatchesTheOldDialog() {
        let question = CaptureResponse(status: .needsClarification, executed: nil, failed: nil,
                                       assistantText: nil, followUpQuestion: "Which list?", errors: nil)
        XCTAssertEqual(CaptureToDashboardIntent.notificationText(for: question).body, "Which list?")

        let truncated = CaptureResponse(status: .error, executed: nil, failed: nil, assistantText: nil,
                                        followUpQuestion: nil,
                                        errors: [CaptureErrorEntry(tool: nil, message: CaptureService.truncatedMessage)],
                                        truncated: true)
        XCTAssertEqual(CaptureToDashboardIntent.notificationText(for: truncated).body,
                       "Couldn't capture — " + CaptureService.truncatedMessage)
    }
}
