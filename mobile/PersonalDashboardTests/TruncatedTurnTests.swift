import XCTest
import SwiftData
@testable import PersonalDashboard

/// A turn cut off at the output ceiling must never apply a partial result
/// (#554).
///
/// Three loops auto-execute tool calls with no confirmation step: the capture
/// (Shortcut) loop, the chat loop for non-destructive actions, and the
/// email-ingest loop. Anthropic closes each `tool_use` block as it finishes
/// generating it, so a turn stopped at `max_tokens` can carry three complete
/// tool calls and a fourth that was never reached. Every one of those three was
/// previously read and run before anything told us the turn was incomplete.
///
/// That is the failure this file locks down. Each test stubs a response that is
/// well formed in every other respect — the tool inputs parse, the actions are
/// real — and differs from a good turn ONLY in `stop_reason`. Each has a
/// control that sends the identical body with a normal stop reason and asserts
/// the same actions DO apply, so a test that passes because the stub is broken
/// fails the control.
@MainActor
final class TruncatedTurnTests: XCTestCase {

    private var store: SwiftDataStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-truncated-turn"))
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        StubbedAnthropicURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Capture (the Shortcut path, auto-executes everything)

    func testCaptureAppliesNothingFromATurnCutOffAtTheCeiling() async throws {
        StubbedAnthropicURLProtocol.body = Self.threeToolCallJSON(stopReason: "max_tokens")

        let result = try await makeCapture().run(input: "three things", timezone: "UTC")

        XCTAssertTrue(result.truncated, "the run must report that a turn was cut off")
        XCTAssertTrue(result.executed.isEmpty, "a truncated turn must apply nothing")
        XCTAssertTrue(result.failed.isEmpty, "nothing was attempted, so nothing failed")
        XCTAssertEqual(todoCount(), 0, "no task may reach the store")
        XCTAssertEqual(listCount(), 0, "no list may reach the store")
        XCTAssertEqual(noteCount(), 0, "no note may reach the store")
    }

    /// The control. Same three tool calls, ordinary stop reason. If this fails,
    /// the test above proves nothing.
    func testCaptureAppliesTheSameThreeToolCallsWhenTheTurnFinished() async throws {
        StubbedAnthropicURLProtocol.bodies = [
            Self.threeToolCallJSON(stopReason: "tool_use"),
            Self.endTurnJSON
        ]

        let result = try await makeCapture().run(input: "three things", timezone: "UTC")

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.executed.count, 3, "a complete turn applies all three")
        XCTAssertEqual(todoCount(), 1)
        XCTAssertEqual(listCount(), 1)
        XCTAssertEqual(noteCount(), 1)
    }

    /// Nothing applied AND the dialog says why. A capture has no conversation
    /// in which a silent drop would be noticed, so the spoken sentence is the
    /// whole of the feedback.
    func testCaptureDialogSaysTheTurnWasCutOff() {
        let response = CaptureService.response(for: ChatToDraftsResult(
            executed: [], failed: [], assistantText: nil, followUpQuestion: nil, truncated: true
        ))

        XCTAssertEqual(response.status, .error, "a truncated capture is not a clarification request")
        XCTAssertTrue(response.truncated)
        let spoken = response.errors?.first?.message ?? ""
        XCTAssertEqual(spoken, CaptureService.truncatedMessage)
        XCTAssertTrue(spoken.contains("cut off"), "the dialog must name the cause: \(spoken)")
        XCTAssertTrue(spoken.contains("nothing was saved"), "the dialog must state the consequence: \(spoken)")
    }

    /// A capture whose FIRST turn completed and whose second was cut off keeps
    /// what the first turn wrote, reports it, and still says the rest was lost.
    func testCapturePartialRunReportsBothWhatLandedAndWhatWasCutOff() {
        let outcome = DraftActionOutcome(
            type: "todo", action: ActionString.created,
            id: UUID().uuidString, title: "Call the dentist", dueDate: nil, addedNames: nil
        )
        let response = CaptureService.response(for: ChatToDraftsResult(
            executed: [outcome], failed: [], assistantText: nil, followUpQuestion: nil, truncated: true
        ))

        XCTAssertEqual(response.status, .executed, "what an earlier complete turn wrote still stands")
        XCTAssertEqual(response.executed?.count, 1)
        XCTAssertTrue(response.truncated, "and the dialog must still flag the cut-off")
        XCTAssertTrue(CaptureService.partialTruncationNote.contains("cut off"))
    }

    // MARK: - Chat (auto-executes add and update)

    func testChatYieldsNoDraftFromATurnCutOffAtTheCeiling() async throws {
        StubbedAnthropicURLProtocol.body = Self.threeToolCallSSE(stopReason: "max_tokens")

        let (drafts, truncations, dones) = try await collectChatEvents()

        XCTAssertEqual(drafts, 0, "a truncated turn must yield no draft, so nothing auto-executes")
        XCTAssertEqual(truncations, 1, "and it must say it was cut off")
        XCTAssertEqual(dones, 0, "a cut-off turn is not a completed turn")
    }

    /// The control for the chat path.
    func testChatYieldsAllThreeDraftsWhenTheTurnFinished() async throws {
        StubbedAnthropicURLProtocol.body = Self.threeToolCallSSE(stopReason: "tool_use")

        let (drafts, truncations, dones) = try await collectChatEvents()

        XCTAssertEqual(drafts, 3, "a complete turn releases every draft it produced")
        XCTAssertEqual(truncations, 0)
        XCTAssertEqual(dones, 1)
    }

    /// The chat error banner must name the cause and the consequence, for the
    /// same reason the spoken capture dialog does.
    func testChatTruncationMessageSaysNothingWasApplied() {
        XCTAssertTrue(ChatViewModel.truncatedTurnMessage.contains("cut off"))
        XCTAssertTrue(ChatViewModel.truncatedTurnMessage.contains("nothing was applied"))
    }

    // MARK: - Email ingest (auto-executes while nobody is watching)

    func testEmailIngestAppliesNothingFromATurnCutOffAtTheCeiling() async throws {
        let trip = LocalTrip(name: "Italy", startDate: Date(), endDate: Date().addingTimeInterval(864_000))
        store.context.insert(trip)
        try store.context.save()

        StubbedAnthropicURLProtocol.body = Self.itineraryToolCallJSON(
            tripUUID: trip.clientUUID.uuidString,
            stopReason: "max_tokens"
        )

        let result = try await makeEmailIngest().run(message: Self.bookingEmail, timezone: "UTC")

        XCTAssertEqual(result.outcome, EmailIngestOutcome.failed, "a half-read email is not a skip")
        XCTAssertTrue(result.addedItemUUIDs.isEmpty)
        XCTAssertEqual(itineraryItemCount(), 0, "no itinerary row may reach the store")
        XCTAssertTrue(result.summary.contains("cut off"), "the ingest log must say why: \(result.summary)")
    }

    /// The control for the email path.
    func testEmailIngestAppliesTheItemWhenTheTurnFinished() async throws {
        let trip = LocalTrip(name: "Italy", startDate: Date(), endDate: Date().addingTimeInterval(864_000))
        store.context.insert(trip)
        try store.context.save()

        StubbedAnthropicURLProtocol.bodies = [
            Self.itineraryToolCallJSON(tripUUID: trip.clientUUID.uuidString, stopReason: "tool_use"),
            Self.endTurnJSON
        ]

        let result = try await makeEmailIngest().run(message: Self.bookingEmail, timezone: "UTC")

        XCTAssertEqual(result.outcome, EmailIngestOutcome.added)
        XCTAssertEqual(itineraryItemCount(), 1)
    }

    // MARK: - Wiring

    private func stubbedClient() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedAnthropicURLProtocol.self]
        return AnthropicClient(session: URLSession(configuration: config))
    }

    private func makeCapture() -> ChatToDrafts {
        ChatToDrafts(
            anthropic: stubbedClient(),
            context: AssistantContextBuilder(store: store),
            executor: ExecuteDraftAction(store: store)
        )
    }

    private func makeEmailIngest() -> EmailToItinerary {
        EmailToItinerary(
            anthropic: stubbedClient(),
            context: AssistantContextBuilder(store: store),
            executor: ExecuteDraftAction(store: store),
            store: store
        )
    }

    private func collectChatEvents() async throws -> (drafts: Int, truncations: Int, dones: Int) {
        let sut = ChatStream(anthropic: stubbedClient(), context: AssistantContextBuilder(store: store))
        var drafts = 0, truncations = 0, dones = 0
        for try await event in sut.run(input: "three things", timezone: "UTC") {
            switch event {
            case .draft: drafts += 1
            case .truncated: truncations += 1
            case .done: dones += 1
            default: break
            }
        }
        return (drafts, truncations, dones)
    }

    private func todoCount() -> Int {
        (try? store.context.fetchCount(FetchDescriptor<LocalTodo>())) ?? -1
    }
    private func noteCount() -> Int {
        (try? store.context.fetchCount(FetchDescriptor<LocalNote>())) ?? -1
    }
    private func listCount() -> Int {
        (try? store.context.fetchCount(FetchDescriptor<LocalList>())) ?? -1
    }
    private func itineraryItemCount() -> Int {
        (try? store.context.fetchCount(FetchDescriptor<LocalItineraryItem>())) ?? -1
    }

    // MARK: - Canned responses

    private static let bookingEmail = EmailMessage(
        messageId: "<truncation-test@dexter>",
        subject: "Your hotel booking",
        from: "bookings@example.com",
        date: "Fri, 3 Oct 2026 09:00:00 +0000",
        body: "Hotel Artemide, Rome. Check in 3 October 2026. Confirmation ABC123.",
        attachments: []
    )

    /// Three complete, well-formed tool calls. The ONLY variable is
    /// `stop_reason`, which is what makes the control meaningful.
    private static func threeToolCallJSON(stopReason: String) -> String {
        """
        {"content":[
          {"type":"tool_use","id":"t1","name":"draft_task",
           "input":{"title":"Book the car service","description":"","due_at":"","tag":"Personal"}},
          {"type":"tool_use","id":"t2","name":"draft_list",
           "input":{"title":"Shopping","items":["milk","eggs","bread"]}},
          {"type":"tool_use","id":"t3","name":"draft_note",
           "input":{"title":"Boiler","body":"Warranty expires in March."}}
        ],"stop_reason":"\(stopReason)","usage":{"output_tokens":1781}}
        """
    }

    /// The turn after the tool results land: prose, no tools, loop exits.
    private static let endTurnJSON =
        #"{"content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn","usage":{"output_tokens":40}}"#

    private static func itineraryToolCallJSON(tripUUID: String, stopReason: String) -> String {
        """
        {"content":[
          {"type":"tool_use","id":"t1","name":"add_itinerary_item",
           "input":{"trip_id":"\(tripUUID)","items":[
             {"kind":"stay","title":"Hotel Artemide","day_date":"2026-10-03","notes":"ABC123"}
           ]}}
        ],"stop_reason":"\(stopReason)","usage":{"output_tokens":900}}
        """
    }

    /// The SSE wire for the same three tool calls. Every block is closed, so a
    /// consumer that releases drafts on `content_block_stop` would emit three.
    private static func threeToolCallSSE(stopReason: String) -> String {
        var out = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
        let blocks: [(String, String)] = [
            ("draft_task", #"{"title":"Book the car service","description":"","due_at":"","tag":"Personal"}"#),
            ("draft_list", #"{"title":"Shopping","items":["milk","eggs","bread"]}"#),
            ("draft_note", #"{"title":"Boiler","body":"Warranty expires in March."}"#)
        ]
        for (index, block) in blocks.enumerated() {
            out += "event: content_block_start\ndata: {\"index\":\(index),"
                + "\"content_block\":{\"type\":\"tool_use\",\"name\":\"\(block.0)\"}}\n\n"
            let escaped = block.1.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out += "event: content_block_delta\ndata: {\"index\":\(index),"
                + "\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\(escaped)\"}}\n\n"
            out += "event: content_block_stop\ndata: {\"index\":\(index)}\n\n"
        }
        out += "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"\(stopReason)\"},"
            + "\"usage\":{\"output_tokens\":1781}}\n\n"
        out += "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        return out
    }
}

/// Serves canned bodies to the Anthropic endpoint, one per request, in order.
///
/// A queue rather than a single body because the capture and email loops are
/// MULTI-TURN: a `tool_use` stop tells the loop to come back with the tool
/// results, so a stub that repeats one body runs the loop to its iteration cap
/// and executes the same three actions five times over. The last entry repeats,
/// so a test that only cares about the first response can pass one.
private final class StubbedAnthropicURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static let endTurn = "{\"content\":[],\"stop_reason\":\"end_turn\"}"
    nonisolated(unsafe) private static var _bodies: [String] = [endTurn]
    nonisolated(unsafe) private static var _served = 0

    static var bodies: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _bodies }
        set { lock.lock(); _bodies = newValue; _served = 0; lock.unlock() }
    }

    /// Convenience for the single-response cases.
    static var body: String {
        get { bodies.first ?? endTurn }
        set { bodies = [newValue] }
    }

    static func reset() {
        bodies = [endTurn]
    }

    private static func next() -> String {
        lock.lock(); defer { lock.unlock() }
        let payload = _bodies[min(_served, _bodies.count - 1)]
        _served += 1
        return payload
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = Self.next()
        let isSSE = payload.hasPrefix("event:")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": isSSE ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
