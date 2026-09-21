import XCTest
@testable import PersonalDashboard

/// The plan chat looking a branded meal up on the web (#647).
///
/// The surface shipped with one tool and no search, on the reasoning that a
/// suggestion is an idea rather than a published figure. The question that
/// broke that reasoning was "what if I order the Guzman y Gomez butter chicken
/// burrito bowl", which has one published answer and was asked here because
/// here is where the order gets decided.
///
/// What is checkable without a live call is everything except the model's
/// judgement: that the tool is declared, that a paused turn is finished rather
/// than abandoned, that the sources come off the wire, and that a search which
/// fails costs the answer its citations and nothing else. Whether
/// `claude-sonnet-5` searches for a chain bowl and not for scrambled eggs is a
/// property of the model, checked by using the app.
@MainActor
final class MealPlanSearchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-plan-search"))
        PlanSearchProbe.reset()
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        PlanSearchProbe.reset()
        super.tearDown()
    }

    // MARK: - What the request declares

    /// Two tools: one that proposes and one that reads. Neither writes, which
    /// is the promise this surface makes and the reason a search was safe to
    /// add to it at all.
    func testTheRequestDeclaresBothToolsAndNothingThatSaves() async throws {
        PlanSearchProbe.responses = [Self.plainAnswerSSE]

        _ = try await collect(input: "is paneer high in protein?")

        let body = try XCTUnwrap(PlanSearchProbe.bodies.first?.objectValue)
        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools.first?.objectValue?["name"]?.stringValue, MealPlanAdvisor.suggestToolName)
        XCTAssertEqual(
            tools.last?.objectValue?["type"]?.stringValue,
            WebSearchGrounding.toolType,
            "A server tool is declared by type, and the plan chat must declare it"
        )
        for tool in tools {
            let name = tool.objectValue?["name"]?.stringValue ?? ""
            XCTAssertNil(
                ToolDefinitions.toolToActionType[name],
                "\(name) can write to the store and has no business on this surface"
            )
        }
    }

    // MARK: - A paused turn

    /// A turn that searched comes back paused, which means incomplete rather
    /// than finished. Ending there would show the user a sentence that stops
    /// mid-thought and call it an answer.
    func testAPausedSearchIsResumedAndItsSourcesSurvive() async throws {
        PlanSearchProbe.responses = [Self.pausedSearchSSE, Self.groundedAnswerSSE]

        let events = try await collect(input: "guzman y gomez butter chicken burrito bowl, regular?")

        XCTAssertEqual(PlanSearchProbe.bodies.count, 2, "The paused turn was never resumed")
        XCTAssertEqual(
            events.sources.map(\.url),
            ["https://gyg.example/nutrition"],
            "The sources from the paused call were dropped on the resume"
        )
        XCTAssertTrue(events.text.contains("1,010 kcal"), "The resumed half of the answer was lost")
        XCTAssertEqual(events.dones, 1)

        // The resumed request hands the paused turn back, or the API has
        // nothing to continue from.
        let second = try XCTUnwrap(PlanSearchProbe.bodies.last?.objectValue)
        let messages = try XCTUnwrap(second["messages"]?.arrayValue)
        XCTAssertEqual(messages.last?.objectValue?["role"]?.stringValue, "assistant")
        let replayed = try XCTUnwrap(messages.last?.objectValue?["content"]?.arrayValue)
        XCTAssertTrue(
            replayed.contains { $0.objectValue?["type"]?.stringValue == WebSearchGrounding.serverToolUseBlockType },
            "The search the model ran must travel back with its result"
        )
        XCTAssertTrue(
            replayed.contains { $0.objectValue?["type"]?.stringValue == WebSearchGrounding.resultBlockType }
        )
    }

    /// A search that fails arrives on an HTTP 200 with an error object where
    /// the results should be. The answer must survive; only the citations are
    /// lost, because there is nothing to cite.
    func testAFailedSearchCostsTheSourcesAndNotTheAnswer() async throws {
        PlanSearchProbe.responses = [Self.failedSearchSSE]

        let events = try await collect(input: "a brand nobody has heard of, any good?")

        XCTAssertTrue(events.sources.isEmpty)
        XCTAssertEqual(events.dones, 1, "The turn still finished")
        XCTAssertFalse(events.text.isEmpty, "The answer itself survived the failed search")
    }

    /// A turn that never searched says nothing about sources, so no citation
    /// line is drawn under an answer given from knowledge.
    func testAnUnsearchedTurnReportsNoSources() async throws {
        PlanSearchProbe.responses = [Self.plainAnswerSSE]

        let events = try await collect(input: "what should I have for lunch?")

        XCTAssertTrue(events.sources.isEmpty)
        XCTAssertEqual(events.dones, 1)
    }

    /// A cut-off turn still releases nothing, search or no search. The rule
    /// predates this feature and the resume loop must not have quietly dropped
    /// it.
    func testATruncatedTurnStillReleasesNothing() async throws {
        PlanSearchProbe.responses = [Self.truncatedSuggestionSSE]

        let events = try await collect(input: "three dinner ideas")

        XCTAssertEqual(events.suggestions, 0)
        XCTAssertEqual(events.truncations, 1)
        XCTAssertEqual(events.dones, 0, "A cut-off turn is not a completed turn")
    }

    // MARK: - Wiring

    private struct Collected {
        var text = ""
        var suggestions = 0
        var sources: [WebSearchSource] = []
        var truncations = 0
        var dones = 0
        var errors: [String] = []
    }

    private func collect(input: String) async throws -> Collected {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlanSearchProbe.self]
        let advisor = MealPlanAdvisor(anthropic: AnthropicClient(session: URLSession(configuration: config)))

        var out = Collected()
        for try await event in advisor.run(
            input: input,
            context: "PLANNING FOR: Sunday 21 September",
            defaultMealType: .dinner
        ) {
            switch event {
            case .textChunk(let chunk): out.text += chunk
            case .suggestion: out.suggestions += 1
            case .sources(let sources): out.sources = sources
            case .truncated: out.truncations += 1
            case .done: out.dones += 1
            case .error(let message): out.errors.append(message)
            }
        }
        return out
    }

    // MARK: - Canned wire

    private static func sse(_ body: String) -> String {
        "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
            + body
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    }

    private static func textBlock(index: Int, _ text: String) -> String {
        "event: content_block_start\ndata: {\"index\":\(index),"
            + "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
            + "event: content_block_delta\ndata: {\"index\":\(index),"
            + "\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n"
            + "event: content_block_stop\ndata: {\"index\":\(index)}\n\n"
    }

    private static func stop(_ reason: String) -> String {
        "event: message_delta\ndata: {\"delta\":{\"stop_reason\":\"\(reason)\"},"
            + "\"usage\":{\"output_tokens\":120}}\n\n"
    }

    /// The search the server ran, and what it returned.
    private static let searchBlocks =
        "event: content_block_start\ndata: {\"index\":0,\"content_block\":"
            + "{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_1\",\"name\":\"web_search\",\"input\":{}}}\n\n"
            + "event: content_block_stop\ndata: {\"index\":0}\n\n"
            + "event: content_block_start\ndata: {\"index\":1,\"content_block\":"
            + "{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_1\",\"content\":["
            + "{\"type\":\"web_search_result\",\"title\":\"GYG Nutrition\","
            + "\"url\":\"https://gyg.example/nutrition\"}]}}\n\n"
            + "event: content_block_stop\ndata: {\"index\":1}\n\n"

    private static var pausedSearchSSE: String {
        sse(searchBlocks + stop(WebSearchGrounding.pauseStopReason))
    }

    private static var groundedAnswerSSE: String {
        sse(textBlock(index: 0, "Their published panel puts it at 1,010 kcal.") + stop("end_turn"))
    }

    /// A failed server tool: `content` is an error OBJECT, not a list, on the
    /// same HTTP 200.
    private static var failedSearchSSE: String {
        sse(
            "event: content_block_start\ndata: {\"index\":0,\"content_block\":"
                + "{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_1\","
                + "\"content\":{\"type\":\"web_search_tool_result_error\","
                + "\"error_code\":\"max_uses_exceeded\"}}}\n\n"
                + "event: content_block_stop\ndata: {\"index\":0}\n\n"
                + textBlock(index: 1, "I could not find a published panel, so this is an estimate.")
                + stop("end_turn")
        )
    }

    private static var plainAnswerSSE: String {
        sse(textBlock(index: 0, "Paneer is about 18g of protein per 100g.") + stop("end_turn"))
    }

    /// One complete `suggest_meal` block on a turn that hit the ceiling.
    private static var truncatedSuggestionSSE: String {
        sse(
            "event: content_block_start\ndata: {\"index\":0,\"content_block\":"
                + "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"suggest_meal\"}}\n\n"
                + "event: content_block_delta\ndata: {\"index\":0,\"delta\":"
                + "{\"type\":\"input_json_delta\",\"partial_json\":"
                + "\"{\\\"title\\\":\\\"Chicken rice bowl\\\",\\\"meal_type\\\":\\\"dinner\\\"}\"}}\n\n"
                + "event: content_block_stop\ndata: {\"index\":0}\n\n"
                + stop("max_tokens")
        )
    }
}

/// Serves canned SSE bodies to the Anthropic endpoint, one per request, in
/// order. A queue rather than one body because a paused turn is TWO calls, and
/// a stub that repeats itself pauses forever. The last entry repeats.
private final class PlanSearchProbe: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responses: [String] = []
    nonisolated(unsafe) private static var _served = 0
    nonisolated(unsafe) private static var _bodies: [AnthropicJSONValue] = []

    static var responses: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _responses }
        set { lock.lock(); _responses = newValue; _served = 0; lock.unlock() }
    }

    /// The decoded request bodies, in the order they were sent.
    static var bodies: [AnthropicJSONValue] {
        lock.lock(); defer { lock.unlock() }; return _bodies
    }

    static func reset() {
        lock.lock()
        _responses = []
        _served = 0
        _bodies = []
        lock.unlock()
    }

    private static func next() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !_responses.isEmpty else { return "" }
        let payload = _responses[min(_served, _responses.count - 1)]
        _served += 1
        return payload
    }

    private static func record(_ request: URLRequest) {
        // `httpBody` is nil on a request whose body was set as a stream, which
        // is what URLSession does to an upload it has already started, so the
        // stream is read back when the property is empty.
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var out = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                out.append(buffer, count: read)
            }
            return out
        } ?? Data()
        guard let decoded = try? JSONDecoder().decode(AnthropicJSONValue.self, from: data) else { return }
        lock.lock(); _bodies.append(decoded); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.next().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
