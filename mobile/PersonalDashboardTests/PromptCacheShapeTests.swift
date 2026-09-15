import XCTest
import SwiftData
@testable import PersonalDashboard

/// Shape coverage for prompt caching (#580).
///
/// The failure this file exists to catch is silent. A cache miss does not
/// error: the API answers normally and bills the whole prefix again, so the
/// only ways to find one are `usage.cache_read_input_tokens` on a live call, or
/// an assertion on the bytes the client actually sends. This file is the second
/// one. `LiveToolLoopTokenBudgetTests.testCaptureLoopSecondCallReadsTheCache`
/// is the first, and it needs credit; every test here runs offline.
///
/// What is asserted, and why each one is a real regression risk:
///
///   1. the 28-tool array keeps its order — it renders at position 0 of the
///      cached prefix, so a `Set` or a dictionary iteration anywhere in that
///      path would break the cache with nothing to show for it,
///   2. the encoder sorts object keys — Swift seeds its hasher per process, so
///      unsorted keys would change the tool block's bytes on every app launch,
///   3. the breakpoint sits at the end of the stable text, with the timestamp
///      and the library after it,
///   4. the stable half really is stable: two prompts built a day apart from
///      different libraries must produce identical bytes before the breakpoint.
@MainActor
final class PromptCacheShapeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AnthropicClient.resetPromptCachingForTesting()
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        CacheShapeURLProtocol.reset()
        AnthropicClient.resetPromptCachingForTesting()
        super.tearDown()
    }

    // MARK: - 1. Tool order

    /// The exact order `ToolDefinitions.allTools` renders in. Pinned, not
    /// counted: a test that only checks the count passes while the cache is
    /// silently broken by a reorder.
    private static let expectedToolOrder = [
        "draft_task", "draft_note", "draft_list", "complete_task", "edit_task",
        "edit_note", "edit_list", "add_to_list", "append_to_note", "edit_list_item",
        "remove_list_item", "edit_folder", "delete_task", "delete_note", "delete_list",
        "delete_folder", "draft_trip", "add_itinerary_item", "edit_trip", "delete_trip",
        "edit_itinerary_item", "delete_itinerary_item", "add_expense",
        "add_recurring_expense", "clear_expenses", "log_meal", "update_meal", "delete_meal"
    ]

    func testToolOrderIsPinned() {
        XCTAssertEqual(
            ToolDefinitions.allTools.map(\.name),
            Self.expectedToolOrder,
            "the tool array moved. It renders at position 0 of the cached prefix, so any "
            + "reorder invalidates the cache on every request. If the change is deliberate, "
            + "update this list and expect one cold run."
        )
    }

    /// Two encodes of the same tool array must be byte-identical. Weak on its
    /// own (one process, one hash seed) but it catches anything that builds the
    /// array freshly per call with a non-deterministic step in it.
    func testToolBlockEncodesToTheSameBytesTwice() throws {
        let first = try AnthropicClient.encoder.encode(ToolDefinitions.allTools)
        let second = try AnthropicClient.encoder.encode(ToolDefinitions.allTools)
        XCTAssertEqual(first, second)
    }

    // MARK: - 2. Deterministic key order

    /// The cross-launch half of the same problem, and the one a same-process
    /// comparison cannot see.
    ///
    /// Every `input_schema` is a Swift `Dictionary`. Swift seeds its hasher per
    /// PROCESS, so without `.sortedKeys` the JSON key order is stable inside one
    /// launch and different in the next — the tool block's bytes would change
    /// every time the user reopened Dexter. Twelve keys are used here because
    /// the odds of an unsorted encoder landing on sorted order by chance are one
    /// in 12 factorial.
    func testEncoderSortsObjectKeysSoToolBytesSurviveARelaunch() throws {
        let object = AnthropicJSONValue.object([
            "zulu": .int(1), "yankee": .int(2), "xray": .int(3), "whiskey": .int(4),
            "victor": .int(5), "uniform": .int(6), "tango": .int(7), "sierra": .int(8),
            "romeo": .int(9), "quebec": .int(10), "papa": .int(11), "oscar": .int(12)
        ])
        let json = String(data: try AnthropicClient.encoder.encode(object), encoding: .utf8)

        XCTAssertEqual(
            json,
            #"{"oscar":12,"papa":11,"quebec":10,"romeo":9,"sierra":8,"tango":7,"uniform":6,"victor":5,"whiskey":4,"xray":3,"yankee":2,"zulu":1}"#,
            "AnthropicClient.encoder lost .sortedKeys. Tool schemas are dictionaries, so "
            + "their JSON key order would then change with every app launch and the prompt "
            + "cache would miss on the first request after each relaunch."
        )
    }

    // MARK: - 3. Where the breakpoint sits, on the wire

    func testCaptureRequestMarksTheStablePrefixAndNothingElse() async throws {
        let body = try await captureRequestBody()

        guard let system = body["system"] as? [[String: Any]] else {
            return XCTFail("system must encode as an array of blocks, not a string")
        }
        XCTAssertEqual(system.count, 2, "one stable block, one volatile block")

        let stable = system[0]
        let volatile = system[1]

        guard let cache = stable["cache_control"] as? [String: Any] else {
            return XCTFail("the first system block must carry the cache breakpoint")
        }
        XCTAssertEqual(cache["type"] as? String, "ephemeral")
        XCTAssertNil(
            cache["ttl"],
            "capture runs on the five-minute default, which is sent by omitting the field. "
            + "See the table above ChatToDrafts.systemPrompt: the hour doubles the write "
            + "price and an isolated capture then costs more than no caching at all."
        )

        XCTAssertNil(
            volatile["cache_control"],
            "a second breakpoint after the volatile tail would write an entry nothing "
            + "ever reads back, which is a pure surcharge"
        )

        let stableText = stable["text"] as? String ?? ""
        let volatileText = volatile["text"] as? String ?? ""

        XCTAssertEqual(stableText, ChatToDrafts.stableSystemPrompt)
        XCTAssertFalse(
            stableText.contains("Current time:"),
            "the timestamp must sit AFTER the breakpoint or the cache misses every request"
        )
        XCTAssertFalse(stableText.contains("Timezone:"))
        XCTAssertTrue(volatileText.contains("Current time:"))
        XCTAssertTrue(volatileText.contains("Timezone:"))
    }

    /// Tools render before system, so a volatile tool block would break the
    /// cache even with a perfect system split.
    func testToolsPrecedeTheBreakpointAndAreTheSharedSet() async throws {
        let body = try await captureRequestBody()
        let tools = body["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, Self.expectedToolOrder)
    }

    // MARK: - 4. The stable half really is stable

    /// The property that makes the whole change work: a prompt built at a
    /// different time, from a different library, in a different timezone must
    /// produce identical bytes up to the breakpoint.
    func testStableBlockIsIdenticalAcrossTimeTimezoneAndLibrary() throws {
        let a = ChatToDrafts.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: "2026-09-15T09:00:00.000Z",
            contextBlock: "EXISTING TASKS:\n- one"
        )
        let b = ChatToDrafts.systemPrompt(
            timezone: "Europe/Rome",
            nowIso: "2026-11-02T23:41:07.512Z",
            contextBlock: "EXISTING TASKS:\n- a completely different library\n- with more rows"
        )

        XCTAssertEqual(a.stable, b.stable)
        XCTAssertNotEqual(a.volatile, b.volatile, "the tail is supposed to differ")

        let encodedA = try Self.firstBlockBytes(of: a)
        let encodedB = try Self.firstBlockBytes(of: b)
        XCTAssertEqual(encodedA, encodedB, "the cached block must be byte-identical")
    }

    func testChatStreamSplitsItsPromptTheSameWay() {
        let prompt = ChatStream.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: "2026-09-15T09:00:00.000Z",
            contextBlock: "EXISTING TASKS:\n- one"
        )
        XCTAssertEqual(prompt.stable, ChatStream.stableSystemPrompt)
        XCTAssertEqual(prompt.ttl, .fiveMinutes)
        XCTAssertFalse(prompt.stable.contains("Current time:"))
        XCTAssertTrue(prompt.volatile?.contains("Current time:") ?? false)
    }

    // MARK: - 5. Per-caller decisions

    /// Sonnet 5 writes no cache entry for a prefix under 1024 tokens, and says
    /// nothing when it declines. A marker on the script normaliser's prompt
    /// would therefore be decoration, so it must not carry one.
    func testShortPromptsCarryNoBreakpoint() throws {
        let prompt = AnthropicSystemPrompt.uncached("Convert this to Devanagari.")
        let blocks = try Self.blocks(of: prompt)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertNil(blocks[0]["cache_control"])
    }

    /// Five minutes is the API default, so it must be sent by OMITTING the
    /// field. Restating it would be harmless but the hour must not be: if
    /// `.oneHour` ever stops emitting `"ttl": "1h"`, every caller that opts into
    /// it silently gets five minutes instead.
    func testTheTTLIsOmittedForFiveMinutesAndStatedForAnHour() throws {
        let short = try Self.blocks(
            of: AnthropicSystemPrompt(stable: TicketExtraction.systemPrompt, ttl: .fiveMinutes)
        )
        let shortCache = short[0]["cache_control"] as? [String: Any]
        XCTAssertEqual(shortCache?["type"] as? String, "ephemeral")
        XCTAssertNil(shortCache?["ttl"])

        let long = try Self.blocks(
            of: AnthropicSystemPrompt(stable: TicketExtraction.systemPrompt, ttl: .oneHour)
        )
        let longCache = long[0]["cache_control"] as? [String: Any]
        XCTAssertEqual(longCache?["type"] as? String, "ephemeral")
        XCTAssertEqual(longCache?["ttl"] as? String, "1h")
    }

    // MARK: - 6. The rejection fallback

    /// The defence for a change that could not be verified live. If the API
    /// refuses the markers, one request is wasted and everything after it is
    /// sent plain — instead of every AI call in the app failing.
    func testACacheControlRejectionRetriesOnceWithoutTheMarkers() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-prompt-cache"))
        CacheShapeURLProtocol.rejectFirstRequestAsCacheControlError = true

        let response = try await makeClient().send(
            systemPrompt: AnthropicSystemPrompt(stable: Self.longEnoughPrompt, ttl: .oneHour),
            messages: [AnthropicMessage(role: "user", content: [.text("hi")])],
            tools: ToolDefinitions.allTools
        )

        XCTAssertEqual(response.stop_reason, "end_turn")
        XCTAssertEqual(CacheShapeURLProtocol.bodies.count, 2, "exactly one retry")
        XCTAssertTrue(Self.hasCacheControl(CacheShapeURLProtocol.bodies[0]))
        XCTAssertFalse(
            Self.hasCacheControl(CacheShapeURLProtocol.bodies[1]),
            "the retry must strip the markers, or it fails the same way again"
        )
        XCTAssertFalse(AnthropicClient.promptCachingEnabled, "and stay off for this process")
    }

    /// The retry must not swallow ordinary 400s. A bad tool schema is also a
    /// 400 and has to keep failing.
    func testAnUnrelatedBadRequestIsNotRetried() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-prompt-cache"))
        CacheShapeURLProtocol.rejectEveryRequestWith = (400, #"{"error":{"message":"messages: text content blocks must be non-empty"}}"#)

        do {
            _ = try await makeClient().send(
                systemPrompt: AnthropicSystemPrompt(stable: Self.longEnoughPrompt),
                messages: [AnthropicMessage(role: "user", content: [.text("hi")])],
                tools: ToolDefinitions.allTools
            )
            XCTFail("an unrelated 400 must propagate")
        } catch {
            XCTAssertEqual(CacheShapeURLProtocol.bodies.count, 1, "no retry")
            XCTAssertTrue(AnthropicClient.promptCachingEnabled, "and caching stays on")
        }
    }

    // MARK: - 7. Observability

    /// `usage` is the only ground truth that caching works, so the counters
    /// have to survive decoding rather than being dropped like they were
    /// before #580.
    func testUsageCarriesTheCacheCounters() throws {
        let json = #"""
        {"content":[],"stop_reason":"end_turn","usage":{"input_tokens":412,
        "cache_creation_input_tokens":0,"cache_read_input_tokens":24118,"output_tokens":57}}
        """#
        let decoded = try AnthropicClient.decoder.decode(
            AnthropicResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.usage?.cache_read_input_tokens, 24118)
        XCTAssertEqual(decoded.usage?.cache_creation_input_tokens, 0)
        XCTAssertEqual(decoded.usage?.input_tokens, 412)
        XCTAssertTrue(decoded.usage?.logLine.contains("cache_read=24118") ?? false)
    }

    // MARK: - 8. The measurement (#580, acceptance criterion 1)

    /// Prints the split the design rests on, and asserts the one part of it
    /// that can break silently: the cached prefix must stay comfortably above
    /// Sonnet 5's 1024-token minimum. Below that the API writes no entry and
    /// reports nothing.
    ///
    /// Sizes are bytes. Tokens are stated in the commit message from these
    /// numbers and the 25,248-to-26,152-token figure the Console request log
    /// recorded for the same request on 15 Sep 2026; `count_tokens` was not
    /// called because the account balance was zero.
    func testPromptSizeSplitIsRecordedAndTheCachedPrefixClearsTheMinimum() async throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        seedRealisticLibrary(in: store)
        let contextBlock = await AssistantContextBuilder(store: store).build()

        let tools = try AnthropicClient.encoder.encode(ToolDefinitions.allTools).count
        let stable = ChatToDrafts.stableSystemPrompt.utf8.count
        let volatile = ChatToDrafts.volatileSystemBlock(
            timezone: "Asia/Singapore",
            nowIso: "2026-09-15T09:00:00.000Z",
            contextBlock: contextBlock
        ).utf8.count

        print("SPLIT tools_json_bytes=\(tools)")
        print("SPLIT stable_system_bytes=\(stable)")
        print("SPLIT volatile_system_bytes=\(volatile) (context_block_bytes=\(contextBlock.utf8.count))")
        print("SPLIT cached_prefix_bytes=\(tools + stable) of \(tools + stable + volatile) total")

        // 1024 tokens is the floor; at a conservative 4 bytes per token that is
        // about 4 KB. The real prefix is an order of magnitude past it, and this
        // assertion is what notices if someone ever trims it down to the edge.
        XCTAssertGreaterThan(
            tools + stable, 20_000,
            "the cached prefix shrank. Under about 4 KB it stops caching entirely, in silence."
        )
        XCTAssertGreaterThan(
            tools + stable, volatile,
            "the cached half should dominate the request, or caching buys little"
        )
    }

    // MARK: - Helpers

    private static let longEnoughPrompt = String(
        repeating: "You are a careful assistant. ", count: 400
    )

    private func makeClient() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CacheShapeURLProtocol.self]
        return AnthropicClient(session: URLSession(configuration: config))
    }

    /// Drives the real capture path so the assertions read the body the app
    /// sends, not a body the test rebuilt.
    private func captureRequestBody() async throws -> [String: Any] {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-prompt-cache"))
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let sut = ChatToDrafts(
            anthropic: makeClient(),
            context: AssistantContextBuilder(store: store),
            executor: ExecuteDraftAction(store: store)
        )
        _ = try await sut.run(input: "what's on my plate today", timezone: "Asia/Singapore")

        guard let raw = CacheShapeURLProtocol.bodies.first,
              let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw XCTSkip("the capture path never reached the network layer")
        }
        return json
    }

    private static func blocks(of prompt: AnthropicSystemPrompt) throws -> [[String: Any]] {
        let data = try AnthropicClient.encoder.encode(prompt)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private static func firstBlockBytes(of prompt: AnthropicSystemPrompt) throws -> Data {
        try AnthropicClient.encoder.encode(prompt.stable)
    }

    private static func hasCacheControl(_ body: Data) -> Bool {
        String(data: body, encoding: .utf8)?.contains("cache_control") ?? false
    }

    private func seedRealisticLibrary(in store: SwiftDataStore) {
        let ctx = store.context
        for (index, title) in [
            "Book the car service", "Renew the passport", "Pay the credit card bill",
            "Call the dentist", "Submit the expense claim", "Fix the kitchen tap",
            "Order new running shoes", "Reply to the landlord", "Plan the Italy trip",
            "Back up the laptop", "Review the insurance quote", "Send the birthday card"
        ].enumerated() {
            ctx.insert(LocalTodo(
                title: title,
                dueDate: Date().addingTimeInterval(Double(index) * 86_400),
                tag: index.isMultiple(of: 2) ? "Personal" : "Work"
            ))
        }
        for index in 0..<8 {
            ctx.insert(LocalNote(
                title: "Note \(index + 1)",
                content: "Some captured thinking about item \(index + 1). "
                    + "It runs to a couple of sentences so the context block is realistic."
            ))
        }
        ctx.insert(LocalList(title: "Shopping", items: [
            ChecklistItem(text: "Coffee"), ChecklistItem(text: "Olive oil")
        ]))
        try? ctx.save()
    }
}

/// Records every outgoing body and answers with a minimal finished turn, so a
/// `ChatToDrafts` loop completes in one iteration with no live key. Can also be
/// told to fail the first request the way the API would if it refused the cache
/// markers.
private final class CacheShapeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bodies: [Data] = []
    nonisolated(unsafe) private static var _rejectFirst = false
    nonisolated(unsafe) private static var _rejectAll: (Int, String)?

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }

    static var rejectFirstRequestAsCacheControlError: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _rejectFirst }
        set { lock.lock(); _rejectFirst = newValue; lock.unlock() }
    }

    static var rejectEveryRequestWith: (Int, String)? {
        get { lock.lock(); defer { lock.unlock() }; return _rejectAll }
        set { lock.lock(); _rejectAll = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock()
        _bodies = []
        _rejectFirst = false
        _rejectAll = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: Data = request.httpBody ?? Self.drain(request.httpBodyStream) ?? Data()

        Self.lock.lock()
        Self._bodies.append(body)
        let index = Self._bodies.count - 1
        let rejectFirst = Self._rejectFirst
        let rejectAll = Self._rejectAll
        Self.lock.unlock()

        var status = 200
        // The shape the API returns when it will not take the markers.
        var payload = #"{"content": [], "stop_reason": "end_turn", "usage": {"input_tokens": 12, "output_tokens": 3}}"#
        if let rejectAll {
            status = rejectAll.0
            payload = rejectAll.1
        } else if rejectFirst && index == 0 {
            status = 400
            payload = #"{"type":"error","error":{"type":"invalid_request_error","message":"system.0.cache_control: Extra inputs are not permitted"}}"#
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
