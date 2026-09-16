import XCTest
import SwiftData
@testable import PersonalDashboard

/// Live measurement of what the chat and capture tool loops actually need from
/// `max_tokens` (#554).
///
/// The shared ceiling was 1024, chosen before this model returned a `thinking`
/// block. Thinking spends the SAME output budget the answer needs, so the
/// number was never measured against the model that runs today. #543 already
/// showed what that costs on another path: the meal estimator sat at 2048 and a
/// five-dish description needed 1991 to 3361 output tokens across four live
/// runs, three of which exceeded the cap and surfaced as "couldn't find a JSON
/// block" — a true statement pointing away from the cause.
///
/// This test exists to replace the guess with a distribution. It:
///
///   1. seeds an IN-MEMORY store with a realistic library, so the context block
///      is the size a real device sends,
///   2. builds the SHIPPED system prompt (`ChatToDrafts.systemPrompt` /
///      `ChatStream.systemPrompt`) and the SHIPPED 28 tools,
///   3. sends each scenario several times with a deliberately large ceiling, so
///      nothing truncates and the natural output length is visible,
///   4. prints one line per run plus a per-scenario max.
///
/// It never writes to the real store, and it never executes a tool call: it
/// measures the generation only.
///
/// Skipped unless `DEXTER_MEASURE_TOKENS=1` AND `ANTHROPIC_API_KEY` are set, so
/// an ordinary suite run spends no money and needs no network. Pass the key in
/// with the `TEST_RUNNER_` prefix; a plain `export` does not reach the test
/// process:
///
///     xcodebuild test -project PersonalDashboard.xcodeproj -scheme PersonalDashboard \
///       -destination 'platform=iOS Simulator,name=iPhone 17e' \
///       -only-testing:PersonalDashboardTests/LiveToolLoopTokenBudgetTests \
///       ANTHROPIC_API_KEY=… DEXTER_MEASURE_TOKENS=1
///
/// Both are plain build settings, which the scheme's test action forwards into
/// the process (see the comment beside them in `project.yml`). The documented
/// `TEST_RUNNER_` prefix does NOT reach an app-hosted simulator test here —
/// verified 2026-09-15, the process saw neither variable.
///
/// ## Result, 2026-09-15
///
///   scenario                        n    min   mean   max
///   capture, one task              10    321    416    612
///   capture, three tool calls      10    615   1204   1781
///   capture, one meal               7   1423   1615   1866
///   capture, trip + itinerary       2    550      -   1177
///   loop turn 2 (tool_result)      16     29    145    567
///
/// `AnthropicClient.maxTokens` was set to 8192 from this. The chat rows are
/// missing because the API account ran out of credit part-way through the run;
/// re-run `testChatStreamOutputTokenDistribution` when there is credit.
/// Thrown by `recordSpend` once a run crosses its ceiling. Named, so the
/// failure says which budget stopped it rather than reading as a flake.
struct MeasurementBudgetExceeded: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
final class LiveToolLoopTokenBudgetTests: XCTestCase {

    /// Deliberately far above anything we expect, so a run reports the length
    /// the model WANTED rather than the length it was allowed.
    private static let measurementCeiling = 32000

    /// Runs per scenario. One run measures nothing: #543's four runs spanned
    /// 1991 to 3361 tokens on one identical input.
    ///
    /// Five, not ten. The 2026-09-15 table below was sampled at ten, and the
    /// ranges in it are already wide and clearly separated at half that count.
    /// A cap decision does not need the extra five runs, and the extra five
    /// runs are what turned one measurement session into an empty balance.
    private static let runsPerScenario = 5

    // MARK: - Spend guard (#580)

    /// What one full run of this class may cost before it stops itself.
    ///
    /// This exists because the first measurement run drained the account:
    /// roughly 110 calls at 25k to 26k input tokens each, about 2.2M input
    /// tokens, and nothing in the harness was counting. A test that spends real
    /// money needs a ceiling for the same reason a tool loop needs a max
    /// iteration count.
    ///
    /// Two ceilings, because after #580 one number no longer says what a run
    /// costs. Prompt caching bills a cache READ at about a tenth of the input
    /// rate, so the same token count can cost four times more or less depending
    /// on whether the prefix hit. The dollar budget is the real guard; the token
    /// budget is a backstop against a loop that never terminates.
    private static let costBudgetUSD = 1.50
    private static let tokenBudget = 3_000_000

    /// `claude-sonnet-5`, US dollars per million tokens. A cache write is 1.25x
    /// the input rate at the five-minute TTL and 2x at one hour; this uses 2x
    /// for every write, so the estimate never reads low.
    private static let inputRate = 2.00
    private static let outputRate = 10.00

    private static let spendLock = NSLock()
    nonisolated(unsafe) private static var spentTokens = 0
    nonisolated(unsafe) private static var spentUSD = 0.0

    /// Adds one response to the running total and throws once either ceiling is
    /// crossed. Throwing fails the test with the message, which is the abort:
    /// the scenario loop stops and no further call is made.
    private static func recordSpend(_ usage: AnthropicUsage?, label: String) throws {
        guard let usage else { return }
        let fresh = usage.input_tokens ?? 0
        let written = usage.cache_creation_input_tokens ?? 0
        let read = usage.cache_read_input_tokens ?? 0
        let out = usage.output_tokens ?? 0

        let dollars = (Double(fresh) * inputRate
                       + Double(written) * inputRate * 2.0
                       + Double(read) * inputRate * 0.1
                       + Double(out) * outputRate) / 1_000_000.0

        spendLock.lock()
        spentTokens += fresh + written + read + out
        spentUSD += dollars
        let tokens = spentTokens
        let usd = spentUSD
        spendLock.unlock()

        print(String(
            format: "SPEND %@: +$%.4f  run total $%.4f / $%.2f, %d / %d tokens",
            label, dollars, usd, costBudgetUSD, tokens, tokenBudget
        ))

        if usd > costBudgetUSD {
            throw MeasurementBudgetExceeded(
                message: String(
                    format: "measurement stopped at %@: the run has spent about $%.2f, "
                        + "over its $%.2f budget (LiveToolLoopTokenBudgetTests.costBudgetUSD). "
                        + "Raise the budget deliberately or cut runsPerScenario.",
                    label, usd, costBudgetUSD
                )
            )
        }
        if tokens > tokenBudget {
            throw MeasurementBudgetExceeded(
                message: "measurement stopped at \(label): the run has used \(tokens) tokens, "
                    + "over its \(tokenBudget) budget "
                    + "(LiveToolLoopTokenBudgetTests.tokenBudget)."
            )
        }
    }

    private var store: SwiftDataStore!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        seedRealisticLibrary()
    }

    // MARK: - The scenarios

    /// Realistic inputs, including turns that emit several tool calls.
    private static let captureScenarios: [(name: String, input: String)] = [
        ("capture/one-task",
         "remind me to call the dentist tomorrow at 3"),
        ("capture/three-tools",
         "add milk, eggs and bread to my shopping list, remind me to book the car "
         + "service on Friday, and make a note that the boiler warranty expires in March"),
        ("capture/meal",
         "for dinner I had two parathas, about 250 grams of chicken curry, a cup of "
         + "arhar dal and a cucumber salad"),
        ("capture/trip-plus-itinerary",
         "plan a trip to Italy from the 3rd to the 12th of October, add Hotel Artemide "
         + "in Rome, the Vatican museums on day two, dinner at Roscioli on day two, and "
         + "the train to Florence on day four"),
        ("capture/edit-and-delete",
         "mark the dentist task done, rename my Packing list to Italy packing, and "
         + "delete the note about the boiler")
    ]

    private static let chatScenarios: [(name: String, input: String)] = [
        ("chat/long-note",
         "write me a note listing what I should pack for ten days in Italy in October, "
         + "with sections for clothes, documents and electronics"),
        ("chat/three-tools",
         "add milk, eggs and bread to my shopping list, remind me to book the car "
         + "service on Friday, and make a note that the boiler warranty expires in March"),
        ("chat/meal",
         "for dinner I had two parathas, about 250 grams of chicken curry, a cup of "
         + "arhar dal and a cucumber salad")
    ]

    // MARK: - Capture (non-streaming `send`)

    func testCaptureLoopOutputTokenDistribution() async throws {
        try skipUnlessLive()
        let systemPrompt = await captureSystemPrompt()
        let client = AnthropicClient()
        var table: [String: [Int]] = [:]

        for scenario in Self.captureScenarios {
            for run in 1...Self.runsPerScenario {
                let messages = [AnthropicMessage(role: "user", content: [.text(scenario.input)])]
                let response = try await client.send(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: ToolDefinitions.allTools,
                    maxTokens: Self.measurementCeiling
                )
                try Self.recordSpend(response.usage, label: "\(scenario.name) run \(run)")
                let tokens = response.usage?.output_tokens ?? -1
                let tools = response.content.filter {
                    if case .toolUse = $0 { return true }
                    return false
                }.count
                table[scenario.name, default: []].append(tokens)
                print("MEASURE \(scenario.name) run \(run): output_tokens=\(tokens) "
                      + "stop=\(response.stop_reason ?? "nil") tool_calls=\(tools)")
                XCTAssertNotEqual(
                    response.stop_reason, "max_tokens",
                    "\(scenario.name) truncated even at \(Self.measurementCeiling); raise the measurement ceiling"
                )

                // Second iteration of the loop: the model sees its own tool
                // calls plus the tool_result turn-back and writes the spoken
                // confirmation. Measured too, because it is a real turn against
                // the same ceiling.
                guard tools > 0 else { continue }
                let results: [AnthropicContentBlock] = response.content.compactMap { block in
                    guard case let .toolUse(id, _, _) = block else { return nil }
                    return .toolResult(toolUseId: id, content: "OK: created todo \(UUID().uuidString)", isError: false)
                }
                var followUp = messages
                followUp.append(.assistantReplay(response.content))
                followUp.append(AnthropicMessage(role: "user", content: results))
                let second = try await client.send(
                    systemPrompt: systemPrompt,
                    messages: followUp,
                    tools: ToolDefinitions.allTools,
                    maxTokens: Self.measurementCeiling
                )
                try Self.recordSpend(second.usage, label: "\(scenario.name)/turn-2 run \(run)")
                let secondTokens = second.usage?.output_tokens ?? -1
                table["\(scenario.name)/turn-2", default: []].append(secondTokens)
                print("MEASURE \(scenario.name)/turn-2 run \(run): output_tokens=\(secondTokens) "
                      + "stop=\(second.stop_reason ?? "nil")")
            }
        }
        Self.report(table, label: "CAPTURE")
    }

    // MARK: - Chat (streaming)

    func testChatStreamOutputTokenDistribution() async throws {
        try skipUnlessLive()
        let systemPrompt = await chatSystemPrompt()
        let client = AnthropicClient()
        var table: [String: [Int]] = [:]

        for scenario in Self.chatScenarios {
            for run in 1...Self.runsPerScenario {
                let messages = [AnthropicMessage(role: "user", content: [.text(scenario.input)])]
                var tokens = -1
                var stop: String? = nil
                var toolCalls = 0
                for try await event in client.stream(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: ToolDefinitions.allTools,
                    maxTokens: Self.measurementCeiling
                ) {
                    switch event {
                    case .toolUse: toolCalls += 1
                    case .done(let reason, let output, let usage, _):
                        stop = reason
                        tokens = output ?? -1
                        try Self.recordSpend(usage, label: "\(scenario.name) run \(run)")
                    default: break
                    }
                }
                table[scenario.name, default: []].append(tokens)
                print("MEASURE \(scenario.name) run \(run): output_tokens=\(tokens) "
                      + "stop=\(stop ?? "nil") tool_calls=\(toolCalls)")
                XCTAssertNotEqual(
                    stop, "max_tokens",
                    "\(scenario.name) truncated even at \(Self.measurementCeiling)"
                )
                // Proves the stop_reason plumbing this ticket added actually
                // carries: before #554 every `.done` reported nil.
                XCTAssertNotNil(stop, "the stream must report a stop_reason")
                XCTAssertGreaterThan(tokens, 0, "the stream must report output_tokens")
            }
        }
        Self.report(table, label: "CHAT")
    }

    // MARK: - Prompt cache (#580)

    /// The acceptance criterion for #580, and the only one a stub cannot stand
    /// in for.
    ///
    /// Every shape test in `PromptCacheShapeTests` proves the request LOOKS
    /// right. None of them can prove the cache HIT, because a miss is silent:
    /// the API answers normally and simply bills the full prefix again. Only
    /// `usage.cache_read_input_tokens` says which happened.
    ///
    /// Two calls, identical prefix. The first writes the entry and must report
    /// a non-zero `cache_creation_input_tokens`; the second must report a
    /// non-zero `cache_read_input_tokens`. The tool loop is never fewer than
    /// two calls, so this is the shape of every real capture.
    ///
    /// PENDING CREDIT as of 2026-09-15: written, never run. The account balance
    /// was zero while #580 was built, so no live call was made. Run this first
    /// once there is credit.
    func testCaptureLoopSecondCallReadsTheCache() async throws {
        try skipUnlessLive()
        let systemPrompt = await captureSystemPrompt()
        let client = AnthropicClient()
        let messages = [AnthropicMessage(
            role: "user",
            content: [.text("remind me to call the dentist tomorrow at 3")]
        )]

        let first = try await client.send(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: ToolDefinitions.allTools
        )
        try Self.recordSpend(first.usage, label: "cache/first")
        print("CACHE first: \(first.usage?.logLine ?? "no usage")")

        XCTAssertGreaterThan(
            first.usage?.cache_creation_input_tokens ?? 0, 0,
            "the first call must WRITE the cache; zero here means the prefix never "
            + "reached the model's minimum cacheable length, or the marker was dropped"
        )

        // Same system prompt object, so the same bytes. A real loop's second
        // call also appends the tool_result turn, which sits after the
        // breakpoint and changes nothing about the cached prefix.
        var second = messages
        second.append(.assistantReplay(first.content))
        second.append(AnthropicMessage(role: "user", content: first.content.compactMap { block in
            guard case let .toolUse(id, _, _) = block else { return nil }
            return .toolResult(toolUseId: id, content: "OK", isError: false)
        }))
        let follow = second.count > 1 ? second : messages

        let read = try await client.send(
            systemPrompt: systemPrompt,
            messages: follow,
            tools: ToolDefinitions.allTools
        )
        try Self.recordSpend(read.usage, label: "cache/second")
        print("CACHE second: \(read.usage?.logLine ?? "no usage")")

        XCTAssertGreaterThan(
            read.usage?.cache_read_input_tokens ?? 0, 0,
            "the second call must READ the cache. Zero means something in the prefix "
            + "changed between the two requests — diff the two encoded bodies and look "
            + "for the first difference before the breakpoint."
        )
    }

    // MARK: - Helpers

    private func skipUnlessLive() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DEXTER_MEASURE_TOKENS"] == "1", "set DEXTER_MEASURE_TOKENS=1 to measure")
        try XCTSkipIf((env["ANTHROPIC_API_KEY"] ?? "").isEmpty, "no API key in the environment")
    }

    private func captureSystemPrompt() async -> AnthropicSystemPrompt {
        ChatToDrafts.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: ISO8601DateFormatter().string(from: Date()),
            contextBlock: await AssistantContextBuilder(store: store).build()
        )
    }

    private func chatSystemPrompt() async -> AnthropicSystemPrompt {
        ChatStream.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: ISO8601DateFormatter().string(from: Date()),
            contextBlock: await AssistantContextBuilder(store: store).build()
        )
    }

    private static func report(_ table: [String: [Int]], label: String) {
        print("===== \(label) OUTPUT TOKEN DISTRIBUTION =====")
        for key in table.keys.sorted() {
            let runs = table[key]!.sorted()
            let mean = runs.reduce(0, +) / max(runs.count, 1)
            print("\(key): n=\(runs.count) min=\(runs.first ?? -1) mean=\(mean) "
                  + "max=\(runs.last ?? -1) all=\(runs)")
        }
    }

    /// A library roughly the size of the user's own, so the context block the
    /// model reads is the one it reads in the app.
    private func seedRealisticLibrary() {
        let ctx = store.context
        let titles = [
            "Book the car service", "Renew the passport", "Pay the credit card bill",
            "Call the dentist", "Submit the expense claim", "Fix the kitchen tap",
            "Order new running shoes", "Reply to the landlord", "Plan the Italy trip",
            "Back up the laptop", "Review the insurance quote", "Send the birthday card"
        ]
        for (index, title) in titles.enumerated() {
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
        ctx.insert(LocalList(title: "Packing", items: [
            ChecklistItem(text: "Passport"), ChecklistItem(text: "Chargers")
        ]))
        try? ctx.save()
    }
}
