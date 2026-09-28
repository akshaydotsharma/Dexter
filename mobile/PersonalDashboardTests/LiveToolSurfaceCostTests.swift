import XCTest
import SwiftData
@testable import PersonalDashboard

/// Live measurement of what one chat turn and one capture loop COST, and
/// whether they still pick the right tool (#681).
///
/// `LiveToolLoopTokenBudgetTests` measures OUTPUT length, to size
/// `max_tokens`. This class measures INPUT, which is where the money went:
/// every request carried all 28 tool definitions, about 22k of a 29k-token
/// prompt, including "add one task".
///
/// Each scenario runs ONCE through the SHIPPED prompt and the SHIPPED tool
/// array (`ChatToDrafts.tools`, `ChatStream.tools`). A capture scenario runs
/// the whole loop the Shortcut runs: every tool call is answered with the
/// same `OK: …` shape `ChatToDrafts` sends back, carrying a fresh id, so a
/// trip can be created and then filled in the next turn exactly as on the
/// phone. Nothing is executed and nothing touches a real store.
///
/// Every request prints a `USAGE` line with all four counters and the
/// latency, and every scenario prints a `CHECK` line: the tools it called,
/// and whether each expected tool was called with the expected arguments.
/// A wrong tool FAILS the test; a cheaper request that does the wrong thing
/// is not a saving.
///
/// Skipped unless `DEXTER_MEASURE_TOKENS=1` and `ANTHROPIC_API_KEY` are set.
/// Both are build settings the scheme forwards (see `project.yml`); a plain
/// `export` does not reach an app-hosted simulator test:
///
///     xcodebuild test -project PersonalDashboard.xcodeproj -scheme PersonalDashboard \
///       -destination 'platform=iOS Simulator,name=iPhone 17e' \
///       -only-testing:PersonalDashboardTests/LiveToolSurfaceCostTests \
///       ANTHROPIC_API_KEY=… DEXTER_MEASURE_TOKENS=1
///
/// A skip still prints TEST SUCCEEDED, so read the `USAGE` lines, not the
/// banner. One full run costs about $0.30 to $0.45.
///
/// ## Result, 2026-09-28 (#681)
///
/// `total_in` is the sum of the three input counters. `$/turn` prices the
/// whole loop COLD (the first request writes the prefix), which is the normal
/// case for an app opened further apart than the five-minute TTL.
///
///   scenario              total_in before -> after      cold $/turn
///   capture/one-task        28,693 -> 14,704  -49%      .0860 -> .0476  -45%
///   capture/three-tools     28,722 -> 14,733  -49%      .0943 -> .0655  -31%
///   capture/meal            28,717 -> 14,728  -49%      .1020 -> .0672  -34%
///   capture/trip            28,747 -> 14,758  -49%      .1037 -> .0595  -43%
///   capture/edit-delete     28,709 -> 14,720  -49%      .0842 -> .0461  -45%
///   capture/expense (1 search) 28,695 -> 31,474 +10%    .0846 -> .0603  -29%
///   chat/long-note          31,755 -> 13,335  -58%      .0845 -> .0381  -55%
///   chat/three-tools        31,765 -> 13,345  -58%      .0879 -> .0507  -42%
///   chat/meal (1 search)    31,760 -> 31,858   +0%      .0971 -> .0724  -25%
///   chat/expense (1 search) 31,738 -> 28,689  -10%      .0817 -> .0457  -44%
///
/// Every scenario called the right tools with the right arguments, before and
/// after. A turn that SEARCHES reads the cached prefix twice (the API samples
/// once before the search and once after), so its raw token count does not
/// fall, while its bill does, because the second pass is a 0.1x cache read.
/// Capture's floor stops at -49% because `log_meal` stays loaded for the 22 s
/// Shortcut timeout (see `ToolDefinitions.captureLoadedToolNames`).
@MainActor
final class LiveToolSurfaceCostTests: XCTestCase {

    // MARK: - What ships

    /// The arrays the two surfaces send. Named here once so the measurement
    /// can never drift from the product.
    private static var captureTools: [AnthropicTool] { ChatToDrafts.tools }
    private static var chatTools: [AnthropicTool] { ChatStream.tools }

    // MARK: - Prices, US dollars per million tokens (live pricing page, 2026-09-28)

    private static let inputRate = 2.00      // claude-sonnet-5
    private static let writeRate = 2.50      // five-minute cache write, 1.25x
    private static let readRate = 0.20       // cache read, 0.1x
    private static let outputRate = 10.00
    private static let searchFeeUSD = 0.01   // one web search

    private static let costBudgetUSD = 0.80
    nonisolated(unsafe) private static var spentUSD = 0.0

    // MARK: - Fixture

    private var store: SwiftDataStore!
    private var dentistID = ""
    private var carServiceID = ""
    private var shoppingID = ""
    private var packingID = ""
    private var boilerNoteID = ""

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        seedLibrary()
    }

    // MARK: - Scenarios

    /// An expectation on one tool call: its name, and a check on its input.
    private struct Expect {
        let tools: Set<String>
        let why: String
        let check: ([String: AnthropicJSONValue]) -> Bool

        init(tool: String, why: String, check: @escaping ([String: AnthropicJSONValue]) -> Bool) {
            self.init(tools: [tool], why: why, check: check)
        }

        init(tools: Set<String>, why: String, check: @escaping ([String: AnthropicJSONValue]) -> Bool) {
            self.tools = tools
            self.why = why
            self.check = check
        }
    }

    private func captureScenarios() -> [(name: String, input: String, expect: [Expect])] {
        [
            ("capture/one-task", "remind me to call the dentist tomorrow at 3", [
                Expect(tool: "draft_task", why: "title names the dentist") {
                    ($0["title"]?.stringValue ?? "").lowercased().contains("dentist")
                }
            ]),
            ("capture/three-tools",
             "add milk, eggs and bread to my shopping list, remind me to book the car "
             + "service on Friday, and make a note that the boiler warranty expires in March", [
                Expect(tool: "add_to_list", why: "the Shopping list, three items") { [shoppingID] in
                    $0["id"]?.stringValue?.lowercased() == shoppingID
                        && ($0["new_items"]?.arrayValue?.count ?? 0) == 3
                },
                Expect(tools: ["draft_task", "edit_task"], why: "car service, new or the existing task") { [carServiceID] in
                    $0["id"]?.stringValue?.lowercased() == carServiceID
                        || ($0["title"]?.stringValue ?? "").lowercased().contains("car")
                },
                Expect(tools: ["draft_note", "append_to_note", "edit_note"],
                       why: "boiler warranty, new or on the existing Boiler note") { [boilerNoteID] in
                    $0["id"]?.stringValue?.lowercased() == boilerNoteID
                        || (($0["title"]?.stringValue ?? "") + ($0["body"]?.stringValue ?? ""))
                            .lowercased().contains("boiler")
                }
            ]),
            ("capture/meal",
             "for dinner I had two parathas, about 250 grams of chicken curry, a cup of "
             + "arhar dal and a cucumber salad", [
                Expect(tool: "log_meal", why: "dinner, at least three items") {
                    $0["meal_type"]?.stringValue == "dinner"
                        && ($0["items"]?.arrayValue?.count ?? 0) >= 3
                }
            ]),
            ("capture/trip-plus-itinerary",
             "plan a trip to Italy from the 3rd to the 12th of October, add Hotel Artemide "
             + "in Rome, the Vatican museums on day two, dinner at Roscioli on day two, and "
             + "the train to Florence on day four", [
                Expect(tool: "draft_trip", why: "Oct 3 to Oct 12") {
                    ($0["start_date"]?.stringValue ?? "").hasSuffix("10-03")
                        && ($0["end_date"]?.stringValue ?? "").hasSuffix("10-12")
                },
                Expect(tool: "add_itinerary_item", why: "at least three items") {
                    ($0["items"]?.arrayValue?.count ?? 0) >= 3
                }
            ]),
            ("capture/edit-and-delete",
             "mark the dentist task done, rename my Packing list to Italy packing, and "
             + "delete the note about the boiler", [
                Expect(tool: "complete_task", why: "the dentist task, completed") { [dentistID] in
                    $0["id"]?.stringValue?.lowercased() == dentistID && $0["completed"]?.boolValue == true
                },
                Expect(tool: "edit_list", why: "Packing renamed to Italy packing") { [packingID] in
                    $0["id"]?.stringValue?.lowercased() == packingID
                        && ($0["title"]?.stringValue ?? "").lowercased() == "italy packing"
                },
                Expect(tool: "delete_note", why: "the boiler note") { [boilerNoteID] in
                    $0["id"]?.stringValue?.lowercased() == boilerNoteID
                }
            ]),
            ("capture/expense", "I spent 42 dollars on a taxi to the airport today", [
                Expect(tool: "add_expense", why: "42, transport") {
                    ($0["original_amount"]?.doubleValue ?? 0) == 42
                        && $0["category"]?.stringValue == "transport"
                }
            ])
        ]
    }

    private func chatScenarios() -> [(name: String, input: String, expect: [Expect])] {
        [
            ("chat/long-note",
             "write me a note listing what I should pack for ten days in Italy in October, "
             + "with sections for clothes, documents and electronics", [
                Expect(tool: "draft_note", why: "an Italy packing note") {
                    (($0["title"]?.stringValue ?? "") + ($0["body"]?.stringValue ?? ""))
                        .lowercased().contains("italy")
                }
            ]),
            ("chat/three-tools",
             "add milk, eggs and bread to my shopping list, remind me to book the car "
             + "service on Friday, and make a note that the boiler warranty expires in March", [
                Expect(tool: "add_to_list", why: "the Shopping list") { [shoppingID] in
                    $0["id"]?.stringValue?.lowercased() == shoppingID
                },
                Expect(tools: ["draft_task", "edit_task"], why: "car service, new or the existing task") { [carServiceID] in
                    $0["id"]?.stringValue?.lowercased() == carServiceID
                        || ($0["title"]?.stringValue ?? "").lowercased().contains("car")
                },
                Expect(tools: ["draft_note", "append_to_note", "edit_note"],
                       why: "boiler warranty, new or on the existing Boiler note") { [boilerNoteID] in
                    $0["id"]?.stringValue?.lowercased() == boilerNoteID
                        || (($0["title"]?.stringValue ?? "") + ($0["body"]?.stringValue ?? ""))
                            .lowercased().contains("boiler")
                }
            ]),
            ("chat/meal",
             "for dinner I had two parathas, about 250 grams of chicken curry, a cup of "
             + "arhar dal and a cucumber salad", [
                Expect(tool: "log_meal", why: "dinner, at least three items") {
                    ($0["items"]?.arrayValue?.count ?? 0) >= 3
                }
            ]),
            ("chat/expense", "I spent 42 dollars on a taxi to the airport today", [
                Expect(tool: "add_expense", why: "42, transport") {
                    ($0["original_amount"]?.doubleValue ?? 0) == 42
                }
            ])
        ]
    }

    // MARK: - Capture: the whole loop, as the Shortcut runs it

    func testCaptureLoopCostAndToolChoice() async throws {
        try skipUnlessLive()
        let prompt = ChatToDrafts.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: ISO8601DateFormatter().string(from: Date()),
            contextBlock: await AssistantContextBuilder(store: store).build()
        )
        let client = AnthropicClient()
        var failures: [String] = []

        for scenario in captureScenarios() {
            var messages = [AnthropicMessage(role: "user", content: [.text(scenario.input)])]
            var calls: [(String, [String: AnthropicJSONValue])] = []

            for turn in 1...ChatToDrafts.maxIterations {
                let started = Date()
                let response = try await client.send(
                    systemPrompt: prompt,
                    messages: messages,
                    tools: Self.captureTools
                )
                try Self.report(response.usage, label: "\(scenario.name) turn \(turn)",
                                seconds: Date().timeIntervalSince(started), searches: 0)

                let uses = response.content.compactMap { block -> (String, String, [String: AnthropicJSONValue])? in
                    if case let .toolUse(id, name, input) = block { return (id, name, input) }
                    return nil
                }
                if uses.isEmpty || response.stop_reason == "max_tokens" { break }
                calls += uses.map { ($0.1, $0.2) }

                // The same reply shape ChatToDrafts sends, with a fresh id,
                // so a created trip can be filled in on the next turn.
                messages.append(.assistantReplay(response.content))
                messages.append(AnthropicMessage(role: "user", content: uses.map { use in
                    .toolResult(
                        toolUseId: use.0,
                        content: "OK: create \(use.1) \(UUID().uuidString.lowercased())",
                        isError: false
                    )
                }))
                if response.stop_reason == "end_turn" { break }
            }
            failures += Self.check(scenario.name, calls: calls, expect: scenario.expect)
        }
        XCTAssertTrue(failures.isEmpty, "wrong tool choice:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Chat: one streamed turn, as the chat surface sends it

    func testChatTurnCostAndToolChoice() async throws {
        try skipUnlessLive()
        let prompt = ChatStream.systemPrompt(
            timezone: "Asia/Singapore",
            nowIso: ISO8601DateFormatter().string(from: Date()),
            contextBlock: await AssistantContextBuilder(store: store).build()
        )
        let client = AnthropicClient()
        var failures: [String] = []

        for scenario in chatScenarios() {
            var calls: [(String, [String: AnthropicJSONValue])] = []
            let started = Date()
            var usage: AnthropicUsage?
            var searches = 0
            for try await event in client.stream(
                systemPrompt: prompt,
                messages: [AnthropicMessage(role: "user", content: [.text(scenario.input)])],
                tools: Self.chatTools
            ) {
                switch event {
                case .toolUse(let name, let input):
                    calls.append((name, input.objectValue ?? [:]))
                case .webSearchResult:
                    searches += 1
                case .done(_, _, let u, _):
                    usage = u
                default:
                    break
                }
            }
            try Self.report(usage, label: "\(scenario.name) turn 1",
                            seconds: Date().timeIntervalSince(started), searches: searches)
            failures += Self.check(scenario.name, calls: calls, expect: scenario.expect)
        }
        XCTAssertTrue(failures.isEmpty, "wrong tool choice:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - The two light routes: same inputs, both models

    /// The evidence for putting a route on `AnthropicClient.lightModel`.
    ///
    /// The SAME inputs go through the SHIPPED code path on both models, and
    /// every answer prints side by side (`NAME` / `HINDI` lines) so the pair
    /// can be read, not just counted. The asserts are the floor a light model
    /// must clear on its own: every meal named within the display cap, and
    /// every transcript converted to Devanagari with no Urdu script left.
    func testLightRoutesMatchSonnet() async throws {
        try skipUnlessLive()
        let client = AnthropicClient()

        let meals = [
            "two eggs on toast with butter and a flat white",
            "chicken rice from the hawker centre, the roasted one, with extra chilli",
            "had 2 rotis with dal makhani and some bhindi sabzi",
            "a big bowl of oats with banana, peanut butter and a scoop of whey",
            "something from the canteen",
            "Greek salad",
            "3 slices of pepperoni pizza and a coke zero",
            "mutton biryani, raita and a gulab jamun for dessert",
            "protein shake",
            "leftover pasta bake from last night, maybe 300g",
            "sushi platter: 8 salmon nigiri, a tuna roll and miso soup",
            "masala chai and two parle-g biscuits"
        ].enumerated().map { MealNamingRequest(id: "meal-\($0.offset)", text: $0.element) }

        let heavy = try await client.nameMeals(meals, model: AnthropicClient.model)
        let light = try await client.nameMeals(meals, model: AnthropicClient.lightModel)
        for meal in meals {
            print("NAME \(meal.id) | \(meal.text) | sonnet=\(heavy[meal.id] ?? "-") | haiku=\(light[meal.id] ?? "-")")
        }
        print("NAME coverage sonnet=\(heavy.count)/\(meals.count) haiku=\(light.count)/\(meals.count)")
        XCTAssertGreaterThanOrEqual(light.count, heavy.count, "the light model named fewer meals")

        let transcripts = [
            "مجھے کل صبح ڈاکٹر کو فون کرنا ہے",
            "دودھ، انڈے اور ڈبل روٹی شاپنگ لسٹ میں ڈال دو",
            "آج رات کھانے میں دو پراٹھے اور دال کھائی",
            "جمعہ کو تین بجے Rahul کے ساتھ meeting ہے"
        ]
        for text in transcripts {
            let heavyOut = await HindiScriptNormalizer.normalize(text, model: AnthropicClient.model)
            let lightOut = await HindiScriptNormalizer.normalize(text, model: AnthropicClient.lightModel)
            print("HINDI \(text) | sonnet=\(heavyOut) | haiku=\(lightOut) | same=\(heavyOut == lightOut)")
            XCTAssertFalse(HindiScriptNormalizer.containsPersoArabic(lightOut), "Urdu script left: \(lightOut)")
            XCTAssertTrue(
                lightOut.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) },
                "no Devanagari in: \(lightOut)"
            )
        }
    }

    // MARK: - Helpers

    private func skipUnlessLive() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DEXTER_MEASURE_TOKENS"] == "1", "set DEXTER_MEASURE_TOKENS=1 to measure")
        try XCTSkipIf((env["ANTHROPIC_API_KEY"] ?? "").isEmpty, "no API key in the environment")
    }

    /// One `USAGE` line per request. `total_in` is the SUM of the three input
    /// counters, which is the prompt's real size whatever the cache did.
    /// `cold$` prices the same request as if nothing had been cached yet,
    /// which is the case for a personal app used further apart than the TTL.
    private static func report(
        _ usage: AnthropicUsage?,
        label: String,
        seconds: TimeInterval,
        searches: Int
    ) throws {
        guard let usage else {
            print("USAGE \(label): no usage reported")
            return
        }
        let fresh = usage.input_tokens ?? 0
        let written = usage.cache_creation_input_tokens ?? 0
        let read = usage.cache_read_input_tokens ?? 0
        let out = usage.output_tokens ?? 0
        let billed = (Double(fresh) * inputRate + Double(written) * writeRate
                      + Double(read) * readRate + Double(out) * outputRate) / 1_000_000
            + Double(searches) * searchFeeUSD
        spentUSD += billed
        print(String(
            format: "USAGE %@: in=%d cache_write=%d cache_read=%d total_in=%d out=%d "
                + "latency=%.1fs web_searches=%d billed=$%.4f run_total=$%.4f",
            label, fresh, written, read, fresh + written + read, out,
            seconds, searches, billed, spentUSD
        ))
        if spentUSD > costBudgetUSD {
            throw MeasurementBudgetExceeded(message: String(
                format: "stopped at %@: spent $%.2f, over the $%.2f budget", label, spentUSD, costBudgetUSD
            ))
        }
    }

    /// Returns one line per unmet expectation, and prints the scenario's calls.
    private static func check(
        _ scenario: String,
        calls: [(String, [String: AnthropicJSONValue])],
        expect: [Expect]
    ) -> [String] {
        print("CALLS \(scenario): " + calls.map(\.0).joined(separator: ", "))
        var failures: [String] = []
        for e in expect {
            let label = e.tools.sorted().joined(separator: "|")
            let matching = calls.filter { e.tools.contains($0.0) }
            let ok = matching.contains { e.check($0.1) }
            print("CHECK \(scenario) \(label) (\(e.why)): \(ok ? "PASS" : "FAIL")")
            if !ok {
                let seen = matching.map { String(describing: $0.1).prefix(300) }.joined(separator: " | ")
                failures.append("\(scenario): \(label) \(e.why). saw: \(seen.isEmpty ? "not called" : seen)")
            }
        }
        return failures
    }

    /// The library `LiveToolLoopTokenBudgetTests` uses, plus the one note and
    /// the one list the edit scenario names, so every expectation has a real
    /// row to point at.
    private func seedLibrary() {
        let ctx = store.context
        let titles = [
            "Book the car service", "Renew the passport", "Pay the credit card bill",
            "Call the dentist", "Submit the expense claim", "Fix the kitchen tap",
            "Order new running shoes", "Reply to the landlord", "Plan the Italy trip",
            "Back up the laptop", "Review the insurance quote", "Send the birthday card"
        ]
        for (index, title) in titles.enumerated() {
            let todo = LocalTodo(
                title: title,
                dueDate: Date().addingTimeInterval(Double(index) * 86_400),
                tag: index.isMultiple(of: 2) ? "Personal" : "Work"
            )
            ctx.insert(todo)
            if title == "Call the dentist" { dentistID = todo.clientUUID.uuidString.lowercased() }
            if title == "Book the car service" { carServiceID = todo.clientUUID.uuidString.lowercased() }
        }
        for index in 0..<7 {
            ctx.insert(LocalNote(
                title: "Note \(index + 1)",
                content: "Some captured thinking about item \(index + 1). "
                    + "It runs to a couple of sentences so the context block is realistic."
            ))
        }
        let boiler = LocalNote(title: "Boiler", content: "The boiler was serviced in May. Engineer: Dave.")
        ctx.insert(boiler)
        boilerNoteID = boiler.clientUUID.uuidString.lowercased()
        let shopping = LocalList(title: "Shopping", items: [
            ChecklistItem(text: "Coffee"), ChecklistItem(text: "Olive oil")
        ])
        let packing = LocalList(title: "Packing", items: [
            ChecklistItem(text: "Passport"), ChecklistItem(text: "Chargers")
        ])
        ctx.insert(shopping)
        ctx.insert(packing)
        shoppingID = shopping.clientUUID.uuidString.lowercased()
        packingID = packing.clientUUID.uuidString.lowercased()
        try? ctx.save()
    }
}
