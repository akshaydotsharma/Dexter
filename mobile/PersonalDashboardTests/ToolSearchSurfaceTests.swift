import XCTest
import SwiftData
@testable import PersonalDashboard

/// The shape of the tool arrays chat and capture send since #681, and the
/// replay that keeps a loaded tool callable across the capture loop.
///
/// Everything here is decidable offline. Whether the model LOADS the right
/// tool is live-only: `LiveToolSurfaceCostTests`.
final class ToolSearchSurfaceTests: XCTestCase {

    private var surfaces: [(name: String, tools: [AnthropicTool], base: [AnthropicTool], loaded: Set<String>)] {
        [
            ("capture", ToolDefinitions.captureRequestTools, ToolDefinitions.allTools,
             ToolDefinitions.captureLoadedToolNames),
            ("chat", ToolDefinitions.chatRequestTools, ToolDefinitions.chatTools,
             ToolDefinitions.chatLoadedToolNames)
        ]
    }

    // MARK: - No capability lost

    /// Every tool the surface offered before #681 is still in its request,
    /// exactly once. Deferring changes what enters the prompt, never what can
    /// be called.
    func testEveryToolIsStillSentExactlyOnce() {
        for surface in surfaces {
            let names = surface.tools.map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "\(surface.name): a tool is sent twice")
            XCTAssertEqual(
                Set(names),
                Set(surface.base.map(\.name)).union([ToolDefinitions.toolSearch.name]),
                "\(surface.name): the request lost or gained a tool"
            )
        }
    }

    func testTheSearchToolLeadsAndIsNeverDeferred() {
        for surface in surfaces {
            let first = surface.tools.first
            XCTAssertEqual(first?.name, "tool_search_tool_regex", surface.name)
            XCTAssertEqual(first?.serverToolType, "tool_search_tool_regex_20251119", surface.name)
            XCTAssertEqual(first?.deferLoading, false, "\(surface.name): a deferred search tool is a 400")
        }
    }

    func testOnlyTheLoadedCoreAndServerToolsAreLoaded() {
        for surface in surfaces {
            for tool in surface.tools {
                let shouldLoad = tool.serverToolType != nil || surface.loaded.contains(tool.name)
                XCTAssertEqual(
                    tool.deferLoading, !shouldLoad,
                    "\(surface.name): \(tool.name) is \(tool.deferLoading ? "deferred" : "loaded")"
                )
            }
            XCTAssertTrue(
                surface.loaded.isSubset(of: Set(surface.base.map(\.name))),
                "\(surface.name): a loaded name matches no tool, so it would silently defer nothing"
            )
        }
        XCTAssertFalse(ToolDefinitions.captureLoadedToolNames.contains("log_meal"),
                       "capture defers log_meal too; the capture moved out of the intent instead (#685)")
        XCTAssertFalse(ToolDefinitions.chatLoadedToolNames.contains("log_meal"))
        // #685: the intent no longer waits on the model, so Apple's 30 s intent
        // limit does not bound this any more. It is the cap on one QUEUED job,
        // run after the intent has replied, and the user set it at 60 s.
        XCTAssertEqual(
            CaptureService.timeoutSeconds, 60,
            "the per-job cap for a queued Shortcut capture is 60 s (#685)"
        )
        XCTAssertTrue(
            ToolDefinitions.chatRequestTools.contains {
                $0.name == WebSearchGrounding.toolName && !$0.deferLoading
            },
            "chat's web search must stay loaded"
        )
    }

    /// `allTools` itself is untouched, because narrow callers filter it:
    /// `EmailToItinerary` sends `add_itinerary_item` ALONE, and a request
    /// whose only tool is deferred is a 400.
    func testTheSharedPoolIsNeverDeferred() {
        XCTAssertFalse(ToolDefinitions.allTools.contains { $0.deferLoading })
        XCTAssertFalse(ToolDefinitions.chatTools.contains { $0.deferLoading })
    }

    /// The model loads a deferred tool by searching its exact name, so every
    /// deferred name must appear in the prompt it reads.
    func testEveryDeferredToolIsNamedInItsStablePrompt() {
        let prompts = [
            ("capture", ToolDefinitions.captureRequestTools, ChatToDrafts.stableSystemPrompt),
            ("chat", ToolDefinitions.chatRequestTools, ChatStream.stableSystemPrompt)
        ]
        for (name, tools, prompt) in prompts {
            XCTAssertTrue(prompt.contains(ToolDefinitions.toolLoadingRule), "\(name): no TOOL LOADING rule")
            for tool in tools where tool.deferLoading {
                XCTAssertTrue(
                    prompt.contains("- \(tool.name):"),
                    "\(name): \(tool.name) is deferred and has no entry under AVAILABLE TOOLS"
                )
            }
        }
    }

    // MARK: - Bytes on the wire

    func testDeferLoadingIsSentOnlyWhenTrue() throws {
        let tools = try encodedTools(ToolDefinitions.captureRequestTools)
        let search = try XCTUnwrap(tools.first)
        XCTAssertEqual(Set(search.keys), ["name", "type"], "a server tool is declared by type alone")

        for tool in tools.dropFirst() {
            let name = tool["name"] as? String ?? "?"
            if ToolDefinitions.captureLoadedToolNames.contains(name) {
                XCTAssertNil(tool["defer_loading"], "\(name): a loaded tool keeps its pre-#681 bytes")
            } else {
                XCTAssertEqual(tool["defer_loading"] as? Bool, true, name)
            }
        }
    }

    /// The loaded half renders into the cached prefix, so it must encode to
    /// the same bytes every time (#580).
    func testTheRequestArraysEncodeToTheSameBytesTwice() throws {
        for surface in surfaces {
            let a = try AnthropicClient.encoder.encode(surface.tools)
            let b = try AnthropicClient.encoder.encode(surface.tools)
            XCTAssertEqual(a, b, surface.name)
        }
    }

    // MARK: - The capture loop's replay

    /// A turn that loaded a tool is replayed into the next request with its
    /// `server_tool_use` and `tool_search_tool_result` byte for byte. Mapping
    /// them to empty text, as the decoder used to, made `assistantReplay` drop
    /// them, and the replayed `tool_use` then named a tool the history had
    /// never loaded.
    func testALoadingTurnReplaysItsSearchVerbatim() throws {
        let json = #"""
        {"content":[
          {"type":"thinking","thinking":"","signature":"sig"},
          {"type":"server_tool_use","id":"srvtoolu_1","name":"tool_search_tool_regex","input":{"pattern":"^add_expense$"}},
          {"type":"tool_search_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"tool_search_tool_search_result","tool_references":[{"type":"tool_reference","tool_name":"add_expense"}]}},
          {"type":"tool_use","id":"toolu_1","name":"add_expense","input":{"original_amount":42}}
        ],"stop_reason":"tool_use"}
        """#
        let response = try AnthropicClient.decoder.decode(AnthropicResponse.self, from: Data(json.utf8))
        let replay = AnthropicMessage.assistantReplay(response.content)
        let data = try AnthropicClient.encoder.encode(replay)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let blocks = try XCTUnwrap(object["content"] as? [[String: Any]])

        XCTAssertEqual(
            blocks.compactMap { $0["type"] as? String },
            ["server_tool_use", "tool_search_tool_result", "tool_use"],
            "thinking is dropped, the search pair and the call survive, in order"
        )
        let result = try XCTUnwrap(blocks[1]["content"] as? [String: Any])
        let references = try XCTUnwrap(result["tool_references"] as? [[String: Any]])
        XCTAssertEqual(references.first?["tool_name"] as? String, "add_expense")
        XCTAssertEqual((blocks[0]["input"] as? [String: Any])?["pattern"] as? String, "^add_expense$")
        XCTAssertEqual(blocks[1]["tool_use_id"] as? String, "srvtoolu_1")
    }

    // MARK: - Model per call

    func testOnlyTheMeasuredRoutesRunOnTheLightModel() {
        XCTAssertEqual(AnthropicClient.model, "claude-sonnet-5")
        XCTAssertEqual(AnthropicClient.lightModel, "claude-haiku-4-5")
        XCTAssertEqual(AnthropicClient.mealNamingModel, AnthropicClient.lightModel)
        XCTAssertEqual(HindiScriptNormalizer.model, AnthropicClient.lightModel)
    }

    // MARK: - Helpers

    private func encodedTools(_ tools: [AnthropicTool]) throws -> [[String: Any]] {
        let data = try AnthropicClient.encoder.encode(tools)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}

/// A deferred tool the model called straight from its prompt line, without
/// loading its schema, and without a key that schema requires (#681).
@MainActor
final class UnloadedToolCallTests: XCTestCase {

    private var store: SwiftDataStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-unloaded-tool"))
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        UnloadedToolStub.bodies = []
        super.tearDown()
    }

    func testOnlyADeferredToolIsChecked() {
        let tools = ToolDefinitions.captureRequestTools
        XCTAssertEqual(
            ToolDefinitions.missingRequiredKeys(tool: "draft_trip", input: ["name": .string("Italy")], in: tools),
            ["start_date", "end_date", "notes"]
        )
        XCTAssertEqual(
            ToolDefinitions.missingRequiredKeys(tool: "draft_task", input: [:], in: tools), [],
            "a loaded tool keeps the pre-#681 behaviour whatever it sent"
        )
        XCTAssertEqual(ToolDefinitions.missingRequiredKeys(tool: "no_such_tool", input: [:], in: tools), [])
    }

    /// Rejected, retried with every key, then written once, with no failure
    /// left over.
    func testCaptureSendsAGuessedCallBackAndRunsTheRetry() async throws {
        UnloadedToolStub.bodies = [
            Self.tripCall(id: "toolu_1", keys: #""name":"Italy""#),
            Self.tripCall(
                id: "toolu_2",
                keys: #""name":"Italy","start_date":"2026-10-03","end_date":"2026-10-12","notes":"""#
            ),
            #"{"content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}"#
        ]

        let result = try await makeCapture().run(input: "plan a trip to Italy", timezone: "UTC")

        XCTAssertEqual(result.executed.count, 1, "only the retry runs")
        XCTAssertTrue(result.failed.isEmpty, "a call that was retried is not a failure")
        XCTAssertEqual(tripCount(), 1)
        XCTAssertTrue(
            UnloadedToolStub.secondRequestBody.contains("ERR_TOOL_NOT_LOADED"),
            "the model is told why the call did not run"
        )
    }

    /// Rejected and never retried: nothing is written, and the Shortcut says so.
    func testCaptureReportsAGuessedCallThatWasNeverRetried() async throws {
        UnloadedToolStub.bodies = [
            Self.tripCall(id: "toolu_1", keys: #""name":"Italy""#),
            #"{"content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}"#
        ]

        let result = try await makeCapture().run(input: "plan a trip to Italy", timezone: "UTC")

        XCTAssertTrue(result.executed.isEmpty)
        XCTAssertEqual(result.failed.map(\.tool), ["draft_trip"])
        XCTAssertEqual(tripCount(), 0, "a half-formed trip must not reach the store")
    }

    /// A streamed turn that ran a search samples twice, and only the
    /// cumulative usage on `message_delta` says so. `message_start` alone
    /// reported a searched chat turn at about half its real input.
    func testAStreamedTurnReportsTheCumulativeUsage() async throws {
        UnloadedToolStub.bodies = [
            "event: message_start\n"
                + #"data: {"type":"message_start","message":{"usage":{"input_tokens":1700,"cache_creation_input_tokens":0,"cache_read_input_tokens":11688,"output_tokens":1}}}"#
                + "\n\n"
                + "event: message_delta\n"
                + #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":6000,"cache_creation_input_tokens":0,"cache_read_input_tokens":23376,"output_tokens":900}}"#
                + "\n\n"
                + "event: message_stop\n"
                + #"data: {"type":"message_stop"}"#
                + "\n\n"
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnloadedToolStub.self]
        let client = AnthropicClient(session: URLSession(configuration: config))

        var reported: AnthropicUsage?
        for try await event in client.stream(
            systemPrompt: .uncached("x"),
            messages: [AnthropicMessage(role: "user", content: [.text("hi")])],
            tools: []
        ) {
            if case .done(_, _, let usage, _) = event { reported = usage }
        }

        XCTAssertEqual(reported?.input_tokens, 6000)
        XCTAssertEqual(reported?.cache_read_input_tokens, 23376, "both prefix passes are counted")
        XCTAssertEqual(reported?.output_tokens, 900)
    }

    // MARK: - Helpers

    private static func tripCall(id: String, keys: String) -> String {
        #"{"content":[{"type":"tool_use","id":"\#(id)","name":"draft_trip","input":{\#(keys)}}],"stop_reason":"tool_use"}"#
    }

    private func makeCapture() -> ChatToDrafts {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnloadedToolStub.self]
        return ChatToDrafts(
            anthropic: AnthropicClient(session: URLSession(configuration: config)),
            context: AssistantContextBuilder(store: store),
            executor: ExecuteDraftAction(store: store)
        )
    }

    private func tripCount() -> Int {
        (try? store.context.fetchCount(FetchDescriptor<LocalTrip>())) ?? -1
    }
}

/// Serves canned bodies in order and keeps the second request's body.
private final class UnloadedToolStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bodies: [String] = []
    nonisolated(unsafe) private static var _served = 0
    nonisolated(unsafe) private static var _second = ""

    static var bodies: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _bodies }
        set { lock.lock(); _bodies = newValue; _served = 0; _second = ""; lock.unlock() }
    }

    static var secondRequestBody: String {
        lock.lock(); defer { lock.unlock() }; return _second
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.lock()
        let payload = Self._bodies.isEmpty
            ? #"{"content":[],"stop_reason":"end_turn"}"#
            : Self._bodies[min(Self._served, Self._bodies.count - 1)]
        if Self._served == 1 { Self._second = String(decoding: sent, as: UTF8.self) }
        Self._served += 1
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
