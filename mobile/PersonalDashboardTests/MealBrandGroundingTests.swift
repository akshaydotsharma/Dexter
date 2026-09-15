import XCTest
@testable import PersonalDashboard

/// Grounding a branded meal estimate in published nutrition (#594).
///
/// Everything here is decidable without a live API call, which is the line this
/// file draws deliberately. Whether `claude-sonnet-5` chooses to search for
/// "Guzman y Gomez chicken burrito bowl" and not for "two eggs on toast" is a
/// property of the model and is checked by using the app. Whether the app reads
/// a search out of a response correctly, tells the success shape from the
/// failure shape, resumes a paused turn, keeps the Shortcut out of it, and still
/// runs every guard: all of that is arithmetic over bytes and belongs here.
@MainActor
final class MealBrandGroundingTests: XCTestCase {

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        GroundedEstimateProbe.reset()
        super.tearDown()
    }

    // MARK: - Reading a search out of a response

    /// The success shape: `content` is a LIST of results.
    func testSuccessfulSearchYieldsItsSources() {
        let block = Self.resultBlock(results: [
            ("Guzman y Gomez Nutrition", "https://www.guzmanygomez.com.au/nutrition/"),
            ("GYG Burrito Bowl", "https://example.com/gyg-bowl")
        ])

        let sources = WebSearchGrounding.sources(inResultBlock: block)

        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.first?.title, "Guzman y Gomez Nutrition")
        XCTAssertEqual(sources.first?.url, "https://www.guzmanygomez.com.au/nutrition/")
    }

    /// The failure shape: `content` is an OBJECT carrying an error code, on an
    /// HTTP 200. Indexing it as a list is the documented footgun, and nothing
    /// upstream catches it because the request succeeded.
    func testFailedSearchYieldsNoSourcesInsteadOfCrashing() {
        let block = AnthropicJSONValue.object([
            "type": .string(WebSearchGrounding.resultBlockType),
            "tool_use_id": .string("srvtoolu_1"),
            "content": .object(["error_code": .string("max_uses_exceeded")])
        ])

        XCTAssertTrue(WebSearchGrounding.sources(inResultBlock: block).isEmpty)
    }

    /// A result with no usable URL is not a source. A figure whose provenance
    /// cannot be opened is a claim the user cannot check.
    func testResultWithoutAURLIsNotASource() {
        let block = AnthropicJSONValue.object([
            "type": .string(WebSearchGrounding.resultBlockType),
            "content": .array([
                .object(["type": .string("web_search_result"), "title": .string("No link")])
            ])
        ])

        XCTAssertTrue(WebSearchGrounding.sources(inResultBlock: block).isEmpty)
    }

    /// A response that never searched is not grounded, whatever its prose says.
    func testResponseWithoutASearchBlockIsNotGrounded() {
        let content: [AnthropicJSONValue] = [
            .object([
                "type": .string("text"),
                "text": .string("According to the official Guzman y Gomez nutrition panel…")
            ])
        ]

        XCTAssertTrue(WebSearchGrounding.sources(inContent: content).isEmpty)
    }

    /// One product page answers several queries. Listing it twice would read as
    /// two independent sources.
    func testSourcesAreDedupedOnTheURL() {
        let content = [
            Self.resultBlock(results: [("GYG Nutrition", "https://gyg.example/nutrition")]),
            Self.resultBlock(results: [
                ("GYG Nutrition (again)", "https://gyg.example/nutrition"),
                ("Bowl page", "https://gyg.example/bowl")
            ])
        ]

        let sources = WebSearchGrounding.sources(inContent: content)

        XCTAssertEqual(sources.map(\.url), [
            "https://gyg.example/nutrition",
            "https://gyg.example/bowl"
        ])
        XCTAssertEqual(sources.first?.title, "GYG Nutrition", "The first occurrence should win")
    }

    /// The cap the live run earned.
    ///
    /// A stub returns two sources and nothing here would ever have noticed the
    /// problem. A real call for "Guzman y Gomez chicken burrito bowl" came back
    /// with 22 distinct URLs across its three searches, and every one was being
    /// stored on the row, drawn under the meal, written into the archive and
    /// re-broadcast on the next sync pass. This pins the ceiling so a later
    /// change to the reader cannot quietly lift it again.
    func testSourcesAreCappedSoOneMealIsNotABibliography() {
        let many = (1...30).map { ("Result \($0)", "https://example.com/\($0)") }

        let sources = WebSearchGrounding.sources(inContent: [Self.resultBlock(results: many)])

        XCTAssertEqual(sources.count, WebSearchGrounding.maxStoredSources)
        XCTAssertLessThanOrEqual(WebSearchGrounding.maxStoredSources, 6, "a provenance list, not an audit log")
        XCTAssertEqual(
            sources.map(\.url),
            (1...WebSearchGrounding.maxStoredSources).map { "https://example.com/\($0)" },
            "results arrive ranked, so the cap keeps the highest-ranked ones"
        )
    }

    /// The cap counts what is KEPT, not what was seen, so duplicates filling the
    /// early blocks cannot starve it down to fewer real sources.
    func testTheCapCountsDistinctSourcesNotRawResults() {
        let content = [
            Self.resultBlock(results: Array(repeating: ("Same", "https://example.com/same"), count: 9)),
            Self.resultBlock(results: (1...9).map { ("Other \($0)", "https://example.com/o\($0)") })
        ]

        let sources = WebSearchGrounding.sources(inContent: content)

        XCTAssertEqual(sources.count, WebSearchGrounding.maxStoredSources)
        XCTAssertEqual(Set(sources.map(\.url)).count, sources.count, "no duplicate survives the cap")
    }

    // MARK: - The resume decision

    func testOnlyAPausedTurnResumes() {
        XCTAssertTrue(WebSearchGrounding.shouldResume(stopReason: "pause_turn", resumesUsed: 0))
        XCTAssertFalse(WebSearchGrounding.shouldResume(stopReason: "end_turn", resumesUsed: 0))
        XCTAssertFalse(WebSearchGrounding.shouldResume(stopReason: "tool_use", resumesUsed: 0))
        XCTAssertFalse(WebSearchGrounding.shouldResume(stopReason: nil, resumesUsed: 0))
    }

    /// A cut-off turn is a different failure with a different answer
    /// (`MealEstimationError.truncated`). Resuming it would report an unfinished
    /// generation as a paused one.
    func testATruncatedTurnDoesNotResume() {
        XCTAssertFalse(WebSearchGrounding.shouldResume(stopReason: "max_tokens", resumesUsed: 0))
    }

    /// The cap is what stops a pathological turn from looping forever.
    func testResumesStopAtTheCap() {
        XCTAssertTrue(
            WebSearchGrounding.shouldResume(
                stopReason: "pause_turn",
                resumesUsed: WebSearchGrounding.maxResumes - 1
            )
        )
        XCTAssertFalse(
            WebSearchGrounding.shouldResume(
                stopReason: "pause_turn",
                resumesUsed: WebSearchGrounding.maxResumes
            )
        )
    }

    // MARK: - The wire shape

    /// A server tool is declared by TYPE and carries no description and no
    /// schema. Sending it the three client keys is rejected.
    func testServerToolEncodesByTypeOnly() throws {
        let encoded = try AnthropicClient.encoder.encode(ToolDefinitions.webSearch)
        let object = try XCTUnwrap(
            (try AnthropicClient.decoder.decode(AnthropicJSONValue.self, from: encoded)).objectValue
        )

        XCTAssertEqual(object["type"]?.stringValue, WebSearchGrounding.toolType)
        XCTAssertEqual(object["name"]?.stringValue, "web_search")
        XCTAssertEqual(object["max_uses"]?.intValue, WebSearchGrounding.maxUses)
        XCTAssertNil(object["description"], "A server tool must not carry a description")
        XCTAssertNil(object["input_schema"], "A server tool must not carry a schema")
    }

    /// And a client tool is untouched by the change that made room for it.
    func testClientToolStillEncodesItsDescriptionAndSchema() throws {
        let logMeal = try XCTUnwrap(ToolDefinitions.allTools.first { $0.name == "log_meal" })
        let encoded = try AnthropicClient.encoder.encode(logMeal)
        let object = try XCTUnwrap(
            (try AnthropicClient.decoder.decode(AnthropicJSONValue.self, from: encoded)).objectValue
        )

        XCTAssertNil(object["type"], "A client tool must not carry a server type")
        XCTAssertNotNil(object["description"])
        XCTAssertNotNil(object["input_schema"])
    }

    /// The replay a paused turn needs is the block verbatim, not this app's
    /// lossy reading of it.
    func testRawContentBlockEncodesVerbatim() throws {
        let block = Self.resultBlock(results: [("Panel", "https://example.com/panel")])
        let encoded = try AnthropicClient.encoder.encode(AnthropicContentBlock.raw(block))
        let round = try AnthropicClient.decoder.decode(AnthropicJSONValue.self, from: encoded)

        XCTAssertEqual(round, block)
    }

    // MARK: - Which paths can search

    /// Chat advertises the search tool; the Shortcut does not. `CaptureService`
    /// runs under a hard 22 s timeout and auto-executes without a preview, so a
    /// search there costs a timeout on a write nobody reviewed.
    func testOnlyTheChatToolListCarriesWebSearch() {
        XCTAssertFalse(
            ToolDefinitions.allTools.contains { $0.name == WebSearchGrounding.toolName },
            "The capture path's tool list must not carry web search"
        )
        XCTAssertTrue(
            ToolDefinitions.chatTools.contains { $0.name == WebSearchGrounding.toolName }
        )
        XCTAssertEqual(
            ToolDefinitions.chatTools.count,
            ToolDefinitions.allTools.count + 1,
            "chatTools is allTools plus web search, and nothing else"
        )
    }

    /// The rule is stated once and reaches exactly the two paths that can act
    /// on it. A path told to search with nothing to search with answers with an
    /// apology instead of a meal.
    func testTheBrandRuleReachesOnlyTheSearchingPaths() {
        let marker = "BRAND LOOKUP"

        XCTAssertTrue(
            MealToolSchema.promptSection(canAskQuestions: true, canSearchWeb: true).contains(marker),
            "Chat lost the brand-lookup rule"
        )
        XCTAssertFalse(
            MealToolSchema.promptSection(canAskQuestions: false, canSearchWeb: false).contains(marker),
            "The Shortcut was told to search and has no search tool"
        )
        XCTAssertTrue(
            AnthropicClient.mealEstimationPrompt(
                description: "Guzman y Gomez chicken burrito bowl",
                mealTypeHint: .lunch,
                loggedAt: Date()
            ).contains(marker),
            "The composer's prompt lost the brand-lookup rule"
        )
        XCTAssertTrue(
            MealToolSchema.brandLookupRule.contains("Do NOT search for generic food"),
            "The rule must say when NOT to search, or every meal pays for one"
        )
    }

    // MARK: - The guards still run

    /// A published panel can still be transcribed wrong, so grounding buys an
    /// estimate no exemption from any check.
    func testAGroundedEstimateIsStillGraded() {
        let sources = [WebSearchSource(title: "Panel", url: "https://example.com/panel")]
        let estimate = EstimatedMeal(
            mealType: "lunch",
            items: [
                EstimatedMealItem(
                    name: "Burrito bowl",
                    portionQuantity: 500,
                    portionUnit: "g",
                    calories: 9000,
                    proteinG: 40,
                    carbsG: 90,
                    fatG: 30,
                    fibreG: 8,
                    sugarG: 6,
                    sodiumMg: 1400,
                    satFatG: 9
                )
            ],
            containsAlcohol: false,
            confidence: "high",
            assumptions: "Regular bowl."
        )

        let checked = MealEstimateGuards.check(
            estimate,
            fallbackMealType: .lunch,
            groundingSources: sources
        )

        XCTAssertTrue(checked.isSuspect, "9,000 kcal is implausible whoever published it")
        XCTAssertEqual(checked.groundingSources, sources, "The sources survive the grading")
        XCTAssertTrue(checked.isGrounded)
    }

    /// No search means no badge, which is the normal case for a generic meal.
    func testAnUngroundedEstimateReportsItself() {
        let checked = MealEstimateGuards.check(
            EstimatedMeal(
                mealType: "breakfast",
                items: [
                    EstimatedMealItem(
                        name: "Poached egg",
                        portionQuantity: 100,
                        portionUnit: "g",
                        calories: 143,
                        proteinG: 12.6,
                        carbsG: 0.7,
                        fatG: 9.5,
                        fibreG: 0,
                        sugarG: 0.4,
                        sodiumMg: 142,
                        satFatG: 3.1
                    )
                ],
                confidence: "medium"
            ),
            fallbackMealType: .breakfast
        )

        XCTAssertFalse(checked.isGrounded)
        XCTAssertTrue(checked.groundingSources.isEmpty)
    }

    // MARK: - Storage and display

    func testGroundingRoundTripsThroughTheStoredBlob() {
        let meal = LocalMeal(mealType: "lunch", mealDescription: "GYG bowl", source: MealSource.composer)
        XCTAssertFalse(meal.isGrounded)

        meal.groundingSources = [
            WebSearchSource(title: "GYG Nutrition", url: "https://gyg.example/nutrition")
        ]

        XCTAssertTrue(meal.isGrounded)
        XCTAssertEqual(meal.groundingSources.first?.url, "https://gyg.example/nutrition")

        meal.groundingSources = []
        XCTAssertNil(meal.groundingSourcesData, "An empty list clears the blob rather than storing []")
        XCTAssertFalse(meal.isGrounded)
    }

    /// Rounding is a claim about where the number came from. 574 off a
    /// published panel is 574; printing 570 says the app worked it out.
    func testGroundedFiguresAreNotRoundedLikeAGuess() {
        XCTAssertEqual(MealFormat.calories(574), "570")
        XCTAssertEqual(MealFormat.calories(574, .estimate), "570")
        XCTAssertEqual(MealFormat.calories(574, .stated), "574")
        XCTAssertEqual(
            MealFormat.value(574, for: .calories, precision: .stated),
            "574 kcal"
        )
    }

    /// The one decision, made in one place, so no two surfaces round the same
    /// meal differently.
    func testPrecisionFollowsGroundingAndTypedTotals() {
        XCTAssertEqual(MealGrounding.precision(isGrounded: false), .estimate)
        XCTAssertEqual(MealGrounding.precision(isGrounded: true), .stated)
        XCTAssertEqual(
            MealGrounding.precision(isGrounded: false, totalsWereOverridden: true),
            .stated
        )
    }

    // MARK: - The composer path, end to end against a stubbed wire

    /// A paused turn is finished, not abandoned.
    ///
    /// The first response searches and pauses; the second returns the JSON. The
    /// estimate must come back with the grounding from the FIRST call, and the
    /// second request must carry the first turn's content as an assistant
    /// message, or the API would have nothing to continue from.
    func testAPausedComposerTurnResumesAndKeepsItsGrounding() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-grounding"))
        GroundedEstimateProbe.responses = [
            Self.pausedSearchResponse,
            Self.finalEstimateResponse
        ]

        let client = AnthropicClient(session: GroundedEstimateProbe.makeSession())
        let result = try await client.estimateMeal(
            description: "Guzman y Gomez chicken burrito bowl",
            mealTypeHint: .lunch
        )

        XCTAssertEqual(GroundedEstimateProbe.bodies.count, 2, "The paused turn was never resumed")
        XCTAssertEqual(result.estimate.items.count, 1)
        XCTAssertEqual(
            result.groundingSources.map(\.url),
            ["https://gyg.example/nutrition"],
            "Grounding from the paused call was dropped on the resume"
        )

        // The resumed request replays the paused turn.
        let second = try XCTUnwrap(GroundedEstimateProbe.bodies.last?.objectValue)
        let messages = try XCTUnwrap(second["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.objectValue?["role"]?.stringValue, "assistant")
        let replayed = try XCTUnwrap(messages.last?.objectValue?["content"]?.arrayValue)
        XCTAssertTrue(
            replayed.contains { $0.objectValue?["type"]?.stringValue == "server_tool_use" },
            "The search the model ran must travel back with its result"
        )
        XCTAssertTrue(
            replayed.contains {
                $0.objectValue?["type"]?.stringValue == WebSearchGrounding.resultBlockType
            }
        )

        // And every request declares the search tool, by type.
        for body in GroundedEstimateProbe.bodies {
            let tools = try XCTUnwrap(body.objectValue?["tools"]?.arrayValue)
            XCTAssertEqual(tools.first?.objectValue?["type"]?.stringValue, WebSearchGrounding.toolType)
        }
    }

    /// A search that fails comes back on an HTTP 200 with an error object. The
    /// meal must still be saveable; only the badge is lost.
    func testAFailedSearchStillProducesASaveableEstimate() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-grounding"))
        GroundedEstimateProbe.responses = [Self.failedSearchResponse]

        let client = AnthropicClient(session: GroundedEstimateProbe.makeSession())
        let result = try await client.estimateMeal(
            description: "Guzman y Gomez chicken burrito bowl",
            mealTypeHint: .lunch
        )

        XCTAssertEqual(GroundedEstimateProbe.bodies.count, 1)
        XCTAssertTrue(result.groundingSources.isEmpty)
        XCTAssertEqual(result.estimate.items.count, 1, "The estimate itself survived the failed search")
    }

    // MARK: - Fixtures

    private static func resultBlock(results: [(String, String)]) -> AnthropicJSONValue {
        .object([
            "type": .string(WebSearchGrounding.resultBlockType),
            "tool_use_id": .string("srvtoolu_1"),
            "content": .array(results.map { title, url in
                .object([
                    "type": .string("web_search_result"),
                    "title": .string(title),
                    "url": .string(url)
                ])
            })
        ])
    }

    private static let estimateJSON = """
    ```json
    {
      "meal_type": "lunch",
      "items": [
        {
          "name": "GYG chicken burrito bowl",
          "portion_quantity": 500,
          "portion_unit": "g",
          "calories": 574,
          "protein_g": 43,
          "carbs_g": 52,
          "fat_g": 19,
          "fibre_g": 9,
          "sugar_g": 5,
          "sodium_mg": 1290,
          "saturated_fat_g": 7
        }
      ],
      "contains_alcohol": false,
      "confidence": "high",
      "assumptions": "Regular bowl, scaled from the published per-serve panel.",
      "no_food_identified": false
    }
    ```
    """

    private static var pausedSearchResponse: String {
        let payload: [String: Any] = [
            "stop_reason": "pause_turn",
            "content": [
                [
                    "type": "server_tool_use",
                    "id": "srvtoolu_1",
                    "name": "web_search",
                    "input": ["query": "Guzman y Gomez burrito bowl nutrition"]
                ],
                [
                    "type": WebSearchGrounding.resultBlockType,
                    "tool_use_id": "srvtoolu_1",
                    "content": [
                        [
                            "type": "web_search_result",
                            "title": "GYG Nutrition",
                            "url": "https://gyg.example/nutrition"
                        ]
                    ]
                ]
            ]
        ]
        return json(payload)
    }

    private static var finalEstimateResponse: String {
        json([
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": estimateJSON]]
        ])
    }

    private static var failedSearchResponse: String {
        json([
            "stop_reason": "end_turn",
            "content": [
                [
                    "type": WebSearchGrounding.resultBlockType,
                    "tool_use_id": "srvtoolu_1",
                    "content": ["error_code": "max_uses_exceeded"]
                ],
                ["type": "text", "text": estimateJSON]
            ]
        ])
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}

/// Answers `estimateMeal`'s requests from a scripted list and records every
/// body it was sent, so the resume can be checked without a live key.
private final class GroundedEstimateProbe: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responses: [String] = []
    nonisolated(unsafe) private static var _bodies: [AnthropicJSONValue] = []

    static var responses: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _responses }
        set { lock.lock(); _responses = newValue; lock.unlock() }
    }

    static var bodies: [AnthropicJSONValue] {
        lock.lock(); defer { lock.unlock() }
        return _bodies
    }

    static func reset() {
        lock.lock()
        _responses = []
        _bodies = []
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroundedEstimateProbe.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` strips httpBody in favour of a stream, so the body is
        // read back through `httpBodyStream` when the direct property is nil.
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        Self.lock.lock()
        if let body, let value = try? JSONDecoder().decode(AnthropicJSONValue.self, from: body) {
            Self._bodies.append(value)
        }
        let next = Self._responses.isEmpty ? nil : Self._responses.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((next ?? "{}").utf8))
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
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
