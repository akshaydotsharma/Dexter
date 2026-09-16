import XCTest
@testable import DexterMac

/// Live verification that the brand rule actually moves the model (#594).
///
/// Skipped unless both `DEXTER_LIVE_MEAL_GROUNDING=1` and `ANTHROPIC_API_KEY`
/// are set, so an ordinary run never spends money or needs a network.
///
/// ### Why a stub cannot answer this
///
/// Every mechanical half of #594 is pinned in `MealBrandGroundingTests`: the
/// tool encodes by type, the resume fires on `pause_turn`, a result list is read
/// and an error object is not. None of that says whether `claude-sonnet-5`
/// reading the shipped rule decides to search for a burrito bowl and decides not
/// to for eggs on toast. That decision is a property of the model, and the only
/// place it exists is a live call.
///
/// It matters in both directions and they fail differently. A brand that is not
/// searched ships the bug #594 was raised to fix, quietly, because the answer
/// still looks like a number. A generic meal that IS searched costs money and
/// seconds on the one path the whole feature is designed around keeping fast.
///
/// This goes through `AnthropicClient.estimateMeal` rather than a replayed body,
/// because a replay proves what the replay sends. The composer's prompt is built
/// inside that call, and the prompt is the thing under test.
///
/// Hosted on the MAC because `ANTHROPIC_API_KEY` reaches a Mac test process
/// directly. The iOS suite runs app-hosted in a simulator, where the
/// `TEST_RUNNER_` prefix does not carry the variable through.
@MainActor
final class LiveMealBrandGroundingTests: XCTestCase {

    private func liveClient() throws -> AnthropicClient {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["DEXTER_LIVE_MEAL_GROUNDING"] == "1",
            "set DEXTER_LIVE_MEAL_GROUNDING=1 to spend money on a real call"
        )
        try XCTSkipIf((env["ANTHROPIC_API_KEY"] ?? "").isEmpty, "no API key in the environment")
        return AnthropicClient()
    }

    /// A named chain and a named item. The figures exist on the brand's own
    /// site, so there is something findable to find.
    func testABrandedMealIsGroundedInPublishedNutrition() async throws {
        let client = try liveClient()

        let started = Date()
        let result = try await client.estimateMeal(
            description: "Guzman y Gomez chicken burrito bowl"
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(
            result.groundingSources.isEmpty,
            "a named chain and item must be searched, not recalled"
        )
        for source in result.groundingSources {
            XCTAssertFalse(source.url.isEmpty, "a source with no URL cannot be checked")
        }
        XCTAssertFalse(result.estimate.items.isEmpty, "the meal still has to come back")

        print("[#594] branded: \(String(format: "%.1f", elapsed))s, "
              + "\(result.groundingSources.count) source(s)")
        for source in result.groundingSources {
            print("[#594]   \(source.title) <\(source.url)>")
        }
    }

    /// Two brands in one meal, which is the case that shipped broken (#594).
    ///
    /// The real dinner was "zero-cal 100PLUS + SuperYou protein wafer" among
    /// generic Indian food. Both products were searched, but the stored sources
    /// were four 100PLUS pages and no wafer at all, because the cap took the
    /// first four across the whole response and the drink's results came first.
    /// The meal looked perfectly grounded while the evidence for the product the
    /// user actually asked about had been dropped.
    func testAMealNamingTwoBrandsKeepsEvidenceForBoth() async throws {
        let client = try liveClient()

        let result = try await client.estimateMeal(
            description: "250 g chicken curry, 2 parathas, zero-cal 100PLUS and a SuperYou protein wafer"
        )

        let urls = result.groundingSources.map { $0.url.lowercased() + " " + $0.title.lowercased() }
        print("[#594] two-brand: \(result.groundingSources.count) source(s)")
        for source in result.groundingSources { print("[#594]   \(source.title) <\(source.url)>") }

        XCTAssertFalse(result.groundingSources.isEmpty, "a two-brand meal must ground")
        XCTAssertTrue(
            urls.contains { $0.contains("superyou") || $0.contains("super you") },
            "SuperYou lost its evidence again: \(urls)"
        )
        XCTAssertTrue(
            urls.contains { $0.contains("100plus") || $0.contains("100 plus") },
            "100PLUS lost its evidence: \(urls)"
        )
    }

    /// Household food with no panel anywhere. The rule names this exact case as
    /// one not to search, and the cost of getting it wrong lands on every meal.
    func testAGenericMealIsNotSearched() async throws {
        let client = try liveClient()

        let started = Date()
        let result = try await client.estimateMeal(
            description: "two eggs on toast with butter and a flat white"
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(
            result.groundingSources.isEmpty,
            "generic food has no published panel; searching it is latency and money for nothing"
        )
        XCTAssertFalse(result.estimate.items.isEmpty, "the meal still has to come back")

        print("[#594] generic: \(String(format: "%.1f", elapsed))s, "
              + "\(result.groundingSources.count) source(s)")
    }
}
