import XCTest
import SwiftData
@testable import PersonalDashboard

/// Everything between "the user filled in six fields" and "a targets row
/// exists" (#544).
///
/// Three things are covered here because all three fail silently:
///
/// 1. **Parsing.** The reply arrives as snake_case JSON inside a fence. A key
///    that stops matching does not throw — it decodes as nil, the field keeps
///    whatever it held, and the user saves a target the derivation never
///    proposed.
/// 2. **Hand-edited flagging.** A figure the user decided has to survive the
///    next derivation. Getting this wrong shows up months later as a number
///    that changed back, with nothing on screen to say why.
/// 3. **Truncation.** A cut-off reply and a malformed one both fail the same
///    parse. Reporting the first as the second tells the user their answer was
///    wrong when it was merely unfinished.
final class MealTargetDerivationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubbedAnthropicURLProtocol.reset()
    }

    override func tearDown() {
        UserAPIKeys.setAnthropic(nil)
        StubbedAnthropicURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func inputs(
        age: Int = 34,
        sex: BiologicalSex = .male,
        height: Double = 178,
        weight: Double = 76,
        activity: ActivityLevel = .moderate,
        goal: MealGoal = .maintain
    ) -> MealTargetInputs {
        MealTargetInputs(
            ageYears: age,
            biologicalSex: sex,
            heightCm: height,
            weightKg: weight,
            activityLevel: activity,
            goal: goal
        )
    }

    private func client() -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubbedAnthropicURLProtocol.self]
        return AnthropicClient(session: URLSession(configuration: config))
    }

    /// A complete, well-formed answer, fenced the way the prompt asks for.
    private static let goodReply = """
    I'll work this through.

    ```json
    {
      "calories": 2450,
      "protein_g": 152,
      "carbs_g": 268,
      "fat_g": 81,
      "fibre_g": 34,
      "sugar_g": 61,
      "sodium_mg": 2000,
      "saturated_fat_g": 27,
      "rationale": "Mifflin St Jeor puts your resting energy near 1,700 kcal."
    }
    ```
    """

    // MARK: - Parsing

    func testParsesEveryFigureAndTheRationale() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-parse"))
        StubbedAnthropicURLProtocol.enqueueText(Self.goodReply)

        let derived = try await client().deriveMealTargets(inputs: inputs())

        XCTAssertEqual(derived.calories, 2450)
        XCTAssertEqual(derived.proteinG, 152)
        XCTAssertEqual(derived.carbsG, 268)
        XCTAssertEqual(derived.fatG, 81)
        XCTAssertEqual(derived.fibreG, 34)
        XCTAssertEqual(derived.sugarG, 61)
        XCTAssertEqual(derived.sodiumMg, 2000)
        XCTAssertEqual(derived.satFatG, 27)
        XCTAssertEqual(
            derived.rationale,
            "Mifflin St Jeor puts your resting energy near 1,700 kcal."
        )
    }

    /// Every one of the eight has to arrive through `value(for:)`, which is how
    /// `MealTargetDraft` reads them. A CodingKey that stopped matching would
    /// leave one nil here and nowhere else.
    func testEveryNutrientIsAddressableByItsEnumCase() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-keys"))
        StubbedAnthropicURLProtocol.enqueueText(Self.goodReply)

        let derived = try await client().deriveMealTargets(inputs: inputs())

        for nutrient in Nutrient.allCases {
            XCTAssertNotNil(
                derived.value(for: nutrient),
                "\(nutrient.rawValue) decoded as nil — its CodingKey no longer matches the prompt's schema"
            )
        }
    }

    /// A key the model omitted decodes as nil rather than as zero, and the
    /// other seven survive. Nil and zero are different answers: one is "said
    /// nothing", the other is "said none".
    func testAMissingFigureIsNilAndDoesNotTakeTheReplyDown() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-partial"))
        StubbedAnthropicURLProtocol.enqueueText("""
        ```json
        {"calories": 2000, "protein_g": 140, "rationale": "Short answer."}
        ```
        """)

        let derived = try await client().deriveMealTargets(inputs: inputs())

        XCTAssertEqual(derived.calories, 2000)
        XCTAssertEqual(derived.proteinG, 140)
        XCTAssertNil(derived.sodiumMg)
        XCTAssertNil(derived.fibreG)
    }

    /// Deriving is a one-time cost, so it is one request. Not one per field,
    /// not one to check the first.
    func testDerivingMakesExactlyOneRequest() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-one-call"))
        StubbedAnthropicURLProtocol.enqueueText(Self.goodReply)

        _ = try await client().deriveMealTargets(inputs: inputs())

        XCTAssertEqual(StubbedAnthropicURLProtocol.requestCount, 1)
    }

    /// The budget the `thinking` block shares with the answer. A cap sized by
    /// how short the JSON looks is the bug this call inherited the fix for.
    func testTheTokenBudgetLeavesRoomForThinking() async throws {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-budget"))
        StubbedAnthropicURLProtocol.enqueueText(Self.goodReply)

        _ = try await client().deriveMealTargets(inputs: inputs())

        XCTAssertEqual(StubbedAnthropicURLProtocol.lastMaxTokens, 8192)
    }

    /// An out-of-range figure is refused before the network, not after it.
    func testAnImpossibleInputIsRefusedWithoutACall() async {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-guard"))

        do {
            _ = try await client().deriveMealTargets(inputs: inputs(age: 3))
            XCTFail("a 3-year-old should not reach the API")
        } catch let error as MealTargetDerivationError {
            guard case .incompleteInputs = error else {
                return XCTFail("expected .incompleteInputs, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(StubbedAnthropicURLProtocol.requestCount, 0)
    }

    /// Biological sex reaches the model. It is in the form because the equation
    /// needs it, and a prompt that quietly dropped it would still return eight
    /// plausible numbers.
    func testTheSixInputsAllReachThePrompt() {
        let prompt = AnthropicClient.mealTargetsPrompt(
            inputs: inputs(age: 41, sex: .female, height: 164, weight: 58, activity: .active, goal: .gainMuscle)
        )
        XCTAssertTrue(prompt.contains("41 years"))
        XCTAssertTrue(prompt.contains("female"))
        XCTAssertTrue(prompt.contains("164 cm"))
        XCTAssertTrue(prompt.contains("58 kg"))
        XCTAssertTrue(prompt.contains("active"))
        XCTAssertTrue(prompt.contains("gain_muscle"))
        XCTAssertTrue(prompt.contains("Mifflin St Jeor"))
    }

    // MARK: - Truncation

    /// A reply cut off at `max_tokens` has no closing fence, so it fails the
    /// same guard a malformed one does. It must be reported as unfinished.
    func testAReplyCutOffAtMaxTokensReportsTruncatedNotMissingJSON() async {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-truncated"))
        StubbedAnthropicURLProtocol.enqueueText(
            """
            ```json
            {
              "calories": 2450,
              "protein_g": 1
            """,
            stopReason: "max_tokens"
        )

        do {
            _ = try await client().deriveMealTargets(inputs: inputs())
            XCTFail("a truncated reply must not decode")
        } catch let error as MealTargetDerivationError {
            guard case .truncated = error else {
                return XCTFail("expected .truncated, got \(error)")
            }
            XCTAssertEqual(
                error.errorDescription,
                "The derivation was cut off before it finished. Try again."
            )
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The other half of the same fork: a complete reply with no JSON in it is
    /// a malformed answer, not an unfinished one.
    func testACompleteReplyWithNoJSONReportsNoJSON() async {
        XCTAssertTrue(UserAPIKeys.setAnthropic("sk-ant-test-targets-nojson"))
        StubbedAnthropicURLProtocol.enqueueText(
            "I'd rather not guess at your targets.",
            stopReason: "end_turn"
        )

        do {
            _ = try await client().deriveMealTargets(inputs: inputs())
            XCTFail("a reply with no JSON must not decode")
        } catch let error as MealTargetDerivationError {
            guard case .noJSON = error else {
                return XCTFail("expected .noJSON, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Hand-edited flagging

    func testAFreshDerivationFlagsNothing() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())

        XCTAssertTrue(draft.handEdited.isEmpty)
        XCTAssertEqual(draft.values.proteinG, 152)
        XCTAssertEqual(draft.rationale, "Because.")
    }

    func testChangingOneFigureFlagsOnlyThatOne() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())

        draft.set(180, for: .protein)

        XCTAssertEqual(draft.handEdited, [.protein])
        XCTAssertEqual(draft.values.proteinG, 180)
        XCTAssertEqual(draft.overriddenSuggestion(for: .protein), 152)
        XCTAssertNil(draft.overriddenSuggestion(for: .carbs))
    }

    /// Typing the suggestion back in is not an override. The flag is computed
    /// from the two figures, so it clears on its own.
    func testTypingTheSuggestionBackClearsTheFlag() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())
        draft.set(180, for: .protein)
        XCTAssertEqual(draft.handEdited, [.protein])

        draft.set(152, for: .protein)

        XCTAssertTrue(draft.handEdited.isEmpty)
    }

    /// The contract the whole feature turns on: a second derivation refreshes
    /// the seven and leaves the one the user decided exactly where it was,
    /// while still recording what it would have suggested.
    func testARederivationRefreshesTheSevenAndKeepsTheOverride() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())
        draft.set(180, for: .protein)

        draft.apply(Self.derivation(calories: 2600, protein: 160, rationale: "New weight."))

        XCTAssertEqual(draft.values.proteinG, 180, "a deliberate choice was overwritten")
        XCTAssertEqual(draft.values.calories, 2600, "an untouched figure was not refreshed")
        XCTAssertEqual(draft.overriddenSuggestion(for: .protein), 160)
        XCTAssertEqual(draft.handEdited, [.protein])
        XCTAssertEqual(draft.rationale, "New weight.")
    }

    /// Calories round to the nearest 10 and the rest to the unit, so a field
    /// showing the rounded figure is not read as an edit of the raw one.
    func testProposedFiguresAreRoundedToTheirFieldsPrecision() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation(calories: 2447, protein: 151.6))

        XCTAssertEqual(draft.values.calories, 2450)
        XCTAssertEqual(draft.values.proteinG, 152)
        XCTAssertTrue(draft.handEdited.isEmpty)
    }

    /// A figure the model omitted keeps whatever the field held. A missing
    /// answer is not a proposal of zero.
    func testAnOmittedFigureIsLeftAloneRatherThanZeroed() {
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())
        draft.set(2100, for: .sodium)

        draft.apply(DerivedMealTargets(calories: 2500, rationale: "Partial."))

        XCTAssertEqual(draft.values.sodiumMg, 2100)
        XCTAssertEqual(draft.values.calories, 2500)
    }

    /// Reopening a stored record carries its flags in, so a figure decided
    /// weeks ago is still protected from the next derivation.
    @MainActor
    func testStoredFlagsSurviveAReopenAndTheNextDerivation() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = MealService(store: store)

        var first = MealTargetDraft(stored: nil)
        first.apply(Self.derivation())
        first.set(180, for: .protein)

        try service.saveTargets(
            targets: first.values,
            ageYears: 34,
            biologicalSex: BiologicalSex.male.rawValue,
            heightCm: 178,
            weightKg: 76,
            activityLevel: ActivityLevel.moderate.rawValue,
            goal: MealGoal.maintain.rawValue,
            rationale: first.rationale,
            handEdited: first.handEdited
        )

        let stored = try XCTUnwrap(service.targets())
        XCTAssertEqual(stored.handEdited, [.protein])
        XCTAssertEqual(stored.proteinG, 180)
        XCTAssertEqual(stored.goal, "maintain")

        // Reopened, with no derivation run yet: the flag is still on protein.
        var second = MealTargetDraft(stored: stored)
        XCTAssertEqual(second.handEdited, [.protein])
        XCTAssertEqual(second.values.proteinG, 180)

        // And a fresh derivation still refuses to overwrite it.
        second.apply(Self.derivation(calories: 2600, protein: 160))
        XCTAssertEqual(second.values.proteinG, 180)
        XCTAssertEqual(second.values.calories, 2600)
        XCTAssertEqual(second.handEdited, [.protein])
    }

    /// Editing a stored figure with no derivation in the session is still an
    /// edit. Without this the sheet could be opened, a number changed, saved,
    /// and the change forgotten the next time targets were derived.
    func testEditingAStoredFigureWithNoDerivationIsStillFlagged() {
        var draft = MealTargetDraft(
            values: Self.storedValues,
            initial: Self.storedValues,
            storedHandEdited: []
        )
        XCTAssertTrue(draft.handEdited.isEmpty)

        draft.set(40, for: .fibre)

        XCTAssertEqual(draft.handEdited, [.fibre])
    }

    /// Eight zeroes are not targets. Saving them would make every reader
    /// believe targets exist and then read every bar against zero.
    func testAnEmptyDraftCannotBeSaved() {
        var draft = MealTargetDraft(stored: nil)
        XCTAssertFalse(draft.hasAnyTarget)

        draft.apply(Self.derivation())
        XCTAssertTrue(draft.hasAnyTarget)
    }

    /// Six inputs go in and come back out unchanged, so re-deriving after a
    /// weight change is one number and one tap rather than six questions again.
    @MainActor
    func testTheSixInputsRoundTripThroughStorage() throws {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let service = MealService(store: store)
        var draft = MealTargetDraft(stored: nil)
        draft.apply(Self.derivation())

        try service.saveTargets(
            targets: draft.values,
            ageYears: 41,
            biologicalSex: BiologicalSex.female.rawValue,
            heightCm: 164,
            weightKg: 58,
            activityLevel: ActivityLevel.veryActive.rawValue,
            goal: MealGoal.gainMuscle.rawValue,
            rationale: draft.rationale
        )

        let read = MealTargetInputs(stored: try XCTUnwrap(service.targets()))
        XCTAssertEqual(read.ageYears, 41)
        XCTAssertEqual(read.biologicalSex, .female)
        XCTAssertEqual(read.heightCm, 164)
        XCTAssertEqual(read.weightKg, 58)
        XCTAssertEqual(read.activityLevel, .veryActive)
        XCTAssertEqual(read.goal, .gainMuscle)
    }

    // MARK: - Draft fixtures

    private static func derivation(
        calories: Double = 2450,
        protein: Double = 152,
        rationale: String = "Because."
    ) -> DerivedMealTargets {
        DerivedMealTargets(
            calories: calories,
            proteinG: protein,
            carbsG: 268,
            fatG: 81,
            fibreG: 34,
            sugarG: 61,
            sodiumMg: 2000,
            satFatG: 27,
            rationale: rationale
        )
    }

    private static let storedValues = MealNutrients(
        calories: 2450, proteinG: 152, carbsG: 268, fatG: 81,
        fibreG: 34, sugarG: 61, sodiumMg: 2000, satFatG: 27
    )
}

/// Answers the one request `deriveMealTargets` makes with a canned Messages API
/// response, and records what was asked.
///
/// A stub rather than a live call for the obvious reason, and for a second one:
/// the truncation path cannot be produced on demand against the real API, so it
/// would otherwise only ever be exercised by the user hitting it.
private final class StubbedAnthropicURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _text = ""
    nonisolated(unsafe) private static var _stopReason = "end_turn"
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _lastMaxTokens: Int?

    static func enqueueText(_ text: String, stopReason: String = "end_turn") {
        lock.lock(); defer { lock.unlock() }
        _text = text
        _stopReason = stopReason
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _text = ""
        _stopReason = "end_turn"
        _requestCount = 0
        _lastMaxTokens = nil
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var lastMaxTokens: Int? {
        lock.lock(); defer { lock.unlock() }
        return _lastMaxTokens
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession commonly hands a POST body to the protocol via
        // `httpBodyStream` even when the request was built with `.httpBody`.
        let body: Data? = request.httpBody ?? Self.drain(request.httpBodyStream)

        Self.lock.lock()
        Self._requestCount += 1
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            Self._lastMaxTokens = json["max_tokens"] as? Int
        }
        let text = Self._text
        let stopReason = Self._stopReason
        Self.lock.unlock()

        let payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
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
        return data.isEmpty ? nil : data
    }
}
