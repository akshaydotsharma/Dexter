import XCTest
@testable import PersonalDashboard

/// Regression coverage for issue #548: `ToolDefinitions.captureExcludedToolNames`
/// was declared with a doc comment claiming it filtered the trip tools out of
/// the capture (Shortcut/voice) auto-execute path, but `ChatToDrafts.run()`
/// always passed `ToolDefinitions.allTools` unconditionally — the guard was
/// never wired up. Git history (`b0582be`, the PR that added it, and
/// `18bccf5`, which later reverted a broader destructive-tool gate for the
/// same capture path) shows the exclusion was abandoned, not merely
/// forgotten, so the fix removed the dead declaration rather than applying
/// it. This test locks in that the capture path keeps advertising the full
/// tool set — including every trip tool — by inspecting the actual HTTP
/// request `ChatToDrafts.run()` sends, so a future filter reintroduced at
/// that call site fails this test rather than silently shipping.
@MainActor
final class CaptureToolSurfaceTests: XCTestCase {

    /// The six tools `captureExcludedToolNames` used to name. If capture
    /// ever stops advertising one of these, this is the list to check first.
    private static let tripToolNames: Set<String> = [
        "draft_trip",
        "add_itinerary_item",
        "edit_trip",
        "delete_trip",
        "edit_itinerary_item",
        "delete_itinerary_item"
    ]

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        RequestCapturingURLProtocol.reset()
        super.tearDown()
    }

    func testAllToolsIncludesEveryTripTool() {
        let advertisedNames = Set(ToolDefinitions.allTools.map(\.name))
        for tripTool in Self.tripToolNames {
            XCTAssertTrue(
                advertisedNames.contains(tripTool),
                "\(tripTool) is missing from ToolDefinitions.allTools"
            )
        }
    }

    func testCapturePathAdvertisesEveryTripToolToTheModel() async throws {
        // Give AnthropicClient a key to work with so `send` reaches the
        // network layer instead of throwing `.notConfigured` up front.
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-capture-tool-surface"))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestCapturingURLProtocol.self]
        let session = URLSession(configuration: config)

        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let sut = ChatToDrafts(
            anthropic: AnthropicClient(session: session),
            context: AssistantContextBuilder(store: store),
            executor: ExecuteDraftAction(store: store)
        )

        _ = try await sut.run(input: "what's on my plate today", timezone: "UTC")

        guard let toolNames = RequestCapturingURLProtocol.lastRequestToolNames else {
            XCTFail("ChatToDrafts.run() never reached the network layer")
            return
        }

        for tripTool in Self.tripToolNames {
            XCTAssertTrue(
                toolNames.contains(tripTool),
                "Capture path no longer advertises \(tripTool) — a filter " +
                "was likely reintroduced at the ChatToDrafts.run() call site."
            )
        }
        // And nothing was silently dropped from the shared pool either.
        XCTAssertEqual(toolNames, Set(ToolDefinitions.allTools.map(\.name)))
    }
}

/// Intercepts the single outgoing request `AnthropicClient.send` makes,
/// records the `tools[].name` values from its body, and answers with a
/// minimal valid `AnthropicResponse` (no tool_use, `end_turn`) so the
/// `ChatToDrafts` loop completes in one iteration without needing a live key.
private final class RequestCapturingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastRequestToolNames: Set<String>?

    static var lastRequestToolNames: Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestToolNames
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastRequestToolNames = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession commonly hands POST bodies to the protocol via
        // `httpBodyStream` rather than `httpBody`, even though the request
        // was built with `.httpBody` set directly. Read whichever is present.
        let body: Data? = request.httpBody ?? Self.drain(request.httpBodyStream)

        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let tools = json["tools"] as? [[String: Any]] {
            let names = Set(tools.compactMap { $0["name"] as? String })
            Self.lock.lock()
            Self._lastRequestToolNames = names
            Self.lock.unlock()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let payload = #"{"content": [], "stop_reason": "end_turn"}"#.data(using: .utf8)!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
