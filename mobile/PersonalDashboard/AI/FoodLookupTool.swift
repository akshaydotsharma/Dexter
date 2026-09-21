import Foundation

/// The lookup the meal estimator does instead of remembering (#653).
///
/// ### Why one tool that takes MANY queries
///
/// A meal is several dishes. "Chicken curry, two parathas and a cup of dal" is
/// three lookups, and a tool that takes one query at a time would cost three
/// model round trips to resolve them — each one a full request carrying the
/// prompt, the day's context and the conversation so far. Batched, the same
/// meal costs ONE round trip, and the device fans the queries out concurrently
/// so the wall-clock cost is roughly that of the slowest single lookup.
///
/// The user has authorised extra latency here in exchange for accuracy. That is
/// a licence to spend it on the network, not on avoidable model turns.
///
/// ### Why the device hands back candidates rather than an answer
///
/// Searching "hainanese chicken rice" does not return nothing. It returns five
/// confident wrong answers led by "Chicken curry with rice" — measured, see
/// `FoodDataCentralClient.withPortions(_:)`. Ranking cannot tell those from a
/// hit, because the question is whether two names denote the same dish, which
/// is a language question. So every candidate is shown with its description and
/// its dataset, and the model chooses. It is also allowed to choose NONE, which
/// is the correct answer for a dish no public database holds.
///
/// ### Why the ledger exists
///
/// The model reports which source each number came from, and a model reporting
/// its own provenance is a model that can write itself a citation. The ledger
/// records every candidate id the DEVICE handed over during the turn, so a
/// claimed `fdc_id` can be checked against what was actually offered. The same
/// argument `WebSearchGrounding` makes: read grounding off the wire, never off
/// the model's prose.
enum FoodLookupTool {

    static let name = "look_up_foods"

    /// How many candidates one query returns.
    ///
    /// Three rather than the client's five. Every candidate costs the model
    /// context on a call already carrying a prompt, a photo sometimes, and the
    /// day's meals, and the useful signal is "here are the plausible readings
    /// of this name", which three carries and five only pads.
    static let candidatesPerQuery = 3

    /// How many queries one call may carry.
    ///
    /// Eight is more dishes than a meal has. The cap exists so a confused turn
    /// cannot fan out into fifty requests against an hourly allowance.
    static let maxQueries = 8

    /// The tool, as declared to the API.
    static var toolJSON: AnthropicJSONValue {
        .object([
            "name": .string(name),
            "description": .string("""
            Look food up in USDA FoodData Central: what 100 g of it contains, and what \
            its standard servings weigh. Call this ONCE with every dish in the meal.

            WHEN TO CALL IT: for any dish you would otherwise estimate from memory. That \
            is almost every meal. Skip it only for a branded packaged product, which the \
            web search answers better, and for something already in the SAVED FOOD ITEMS \
            list, which the device holds exact figures for.

            HOW TO WRITE A QUERY: use a GENERIC food description, not the user's words. \
            The database matches tokens, not dishes. "khao soi" finds soy chips. \
            "hainanese chicken rice" finds a chicken curry. Write what the dish IS: \
            "coconut curry noodle soup with chicken", "poached chicken with rice". \
            One query per distinct dish.

            WHAT COMES BACK: up to three candidates per query, each with an id, the \
            database's own description, its dataset, its nutrients per 100 g, and its \
            portion weights.

            READ THE DESCRIPTIONS BEFORE YOU USE A CANDIDATE. A near-miss is common and \
            looks like a hit. If none of the candidates IS the dish, use none of them \
            and estimate it yourself — a wrong row cited as a source is worse than an \
            honest guess, because it invites trust it has not earned.
            """),
            "input_schema": .object([
                "type": .string("object"),
                "properties": .object([
                    "queries": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("One generic food description per distinct dish in the meal. At most \(maxQueries).")
                    ])
                ]),
                "required": .array([.string("queries")])
            ])
        ])
    }

    /// Pull the queries out of a tool input, trimmed, de-duplicated and capped.
    static func queries(from input: [String: AnthropicJSONValue]) -> [String] {
        let raw = (input["queries"]?.arrayValue ?? []).compactMap(\.stringValue)
        var seen = Set<String>()
        var out: [String] = []
        for query in raw {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(trimmed)
            if out.count == maxQueries { break }
        }
        return out
    }
}

/// One food offered to the model, from whichever source found it.
///
/// Deliberately source-agnostic. FoodData Central is the only source wired in
/// today, and the Singapore HPB table and the saved library are next; a model
/// reading two differently-shaped candidate lists would be a second place for
/// the rules to drift, which is the defect `MealToolSchema` exists to prevent.
struct FoodLookupCandidate: Sendable, Equatable {

    /// The id the model quotes back, namespaced by source: `fdc:2706437`.
    ///
    /// Namespaced rather than bare so the device can tell what a returned id
    /// refers to without guessing, and so a second source cannot collide with
    /// the first.
    let id: String

    /// The source's own description of the food. The field the model reads to
    /// decide whether this candidate IS the dish.
    let name: String

    /// Which database and which dataset, so "a survey of what people eat" and
    /// "a laboratory analysis of an ingredient" are not presented as the same
    /// kind of claim.
    let provenance: String

    /// The eight, per 100 g or per 100 ml.
    let nutrientsPer100: MealNutrients

    /// Nutrients this record does not carry, by name. Shown because a zero that
    /// means "not measured" must not be read as a zero that means zero.
    let missingNutrients: [Nutrient]

    /// Household measures and their gram weights. The mass half.
    let portions: [FoodDataCentralPortion]

    init(fdc food: FoodDataCentralFood) {
        self.id = "fdc:\(food.fdcID)"
        self.name = food.description
        self.provenance = "USDA FoodData Central, \(food.dataType?.rawValue ?? "unknown dataset")"
        self.nutrientsPer100 = food.nutrientsPer100
        self.missingNutrients = food.missingNutrients
        self.portions = food.portions
    }
}

/// What one query found.
struct FoodLookupResult: Sendable, Equatable {
    let query: String
    let candidates: [FoodLookupCandidate]

    /// Why there are no candidates, when there are none. Shown to the model so
    /// "this food is not in the database" and "the lookup failed" are different
    /// facts, and only the second is worth re-phrasing a query over.
    let note: String?
}

/// Every candidate id the device handed to the model during one estimate.
///
/// A model's claim that a number came from `fdc:2706437` is worth exactly as
/// much as the device's ability to check it. This is that check: an id not in
/// the ledger was never offered, so it was invented, and the item's density
/// provenance is demoted to "estimated" rather than believed.
///
/// A class rather than a struct because the estimate loop threads it through
/// several turns and every one of them appends to the same record.
final class FoodLookupLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var candidatesByID: [String: FoodLookupCandidate] = [:]

    init() {}

    func record(_ results: [FoodLookupResult]) {
        lock.lock()
        defer { lock.unlock() }
        for result in results {
            for candidate in result.candidates {
                candidatesByID[candidate.id] = candidate
            }
        }
    }

    /// The candidate behind an id, or nil when the id was never offered.
    func candidate(_ id: String) -> FoodLookupCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return candidatesByID[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// True when the device really did offer this id.
    func offered(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return candidate(id) != nil
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidatesByID.isEmpty
    }
}

/// Runs the lookups the tool asks for (#653).
///
/// Concurrent by query AND by candidate, because the portion table lives on a
/// second endpoint: a three-dish meal is one search per dish and up to three
/// detail calls per search, and run in sequence that is twelve round trips the
/// user waits through. Run as a task group it is roughly the slowest one.
struct FoodLookupService: Sendable {

    let fdc: FoodDataCentralClient

    init(fdc: FoodDataCentralClient = FoodDataCentralClient()) {
        self.fdc = fdc
    }

    var isConfigured: Bool { fdc.isConfigured }

    /// Resolve every query, in the order asked.
    ///
    /// Never throws. A lookup that fails comes back as a result with no
    /// candidates and a note saying why, because the estimate must still be
    /// producible: the model's own numbers are the fallback and losing the meal
    /// to a database outage would be a far worse trade than a less precise
    /// figure.
    func lookUp(_ queries: [String]) async -> [FoodLookupResult] {
        guard !queries.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, FoodLookupResult).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { (index, await self.resolve(query)) }
            }
            var out: [(Int, FoodLookupResult)] = []
            for await pair in group { out.append(pair) }
            // Restored to the asked order. A task group yields as tasks finish,
            // and a result list whose order depends on network timing would
            // make the tool's answer differ run to run for one input.
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func resolve(_ query: String) async -> FoodLookupResult {
        let hits: [FoodDataCentralFood]
        do {
            hits = try await fdc.search(query)
        } catch let error as FoodDataCentralError {
            return FoodLookupResult(query: query, candidates: [], note: error.errorDescription)
        } catch {
            return FoodLookupResult(query: query, candidates: [], note: "The lookup did not complete.")
        }

        let top = Array(hits.prefix(FoodLookupTool.candidatesPerQuery))
        guard !top.isEmpty else {
            return FoodLookupResult(
                query: query,
                candidates: [],
                note: "No match. Estimate this one yourself, or try a broader description."
            )
        }

        // The portion table is on the detail endpoint, so each candidate costs a
        // second call. Concurrent for the reason above.
        let detailed = await withTaskGroup(of: (Int, FoodDataCentralFood).self) { group in
            for (index, food) in top.enumerated() {
                group.addTask { (index, await self.fdc.withPortions(food)) }
            }
            var out: [(Int, FoodDataCentralFood)] = []
            for await pair in group { out.append(pair) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return FoodLookupResult(
            query: query,
            candidates: detailed.map(FoodLookupCandidate.init(fdc:)),
            note: nil
        )
    }
}

// MARK: - Rendering the answer

extension FoodLookupTool {

    /// The tool result, as the text block the API carries it in.
    ///
    /// Rendered as compact lines rather than JSON on purpose. The model reads
    /// this to make one choice per dish, and a nested object costs two to three
    /// times the tokens of the same facts written as a line, on a call that is
    /// already carrying a prompt, sometimes a photograph, and the day's meals.
    ///
    /// Every candidate leads with its ID and its NAME, because the name is what
    /// the choice turns on and the id is what has to be quoted back.
    static func render(_ results: [FoodLookupResult]) -> String {
        guard !results.isEmpty else { return "No queries were run." }

        return results.map { result -> String in
            var lines = ["QUERY: \(result.query)"]
            if result.candidates.isEmpty {
                lines.append("  no candidates. \(result.note ?? "")".trimmingCharacters(in: .whitespaces))
                return lines.joined(separator: "\n")
            }
            for candidate in result.candidates {
                lines.append("  id: \(candidate.id)")
                lines.append("    name: \(candidate.name)")
                lines.append("    source: \(candidate.provenance)")
                lines.append("    per 100 g: \(nutrientLine(candidate.nutrientsPer100))")
                if !candidate.missingNutrients.isEmpty {
                    lines.append("    NOT measured (shown as 0): \(candidate.missingNutrients.map(\.displayName).joined(separator: ", "))")
                }
                if candidate.portions.isEmpty {
                    lines.append("    portions: none published — state the mass yourself and say so")
                } else {
                    let portions = candidate.portions
                        .map { "\($0.description) = \(whole($0.gramWeight)) g" }
                        .joined(separator: "; ")
                    lines.append("    portions: \(portions)")
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func nutrientLine(_ n: MealNutrients) -> String {
        "\(whole(n.calories)) kcal, protein \(oneDecimal(n.proteinG)) g, carbs \(oneDecimal(n.carbsG)) g, "
        + "fat \(oneDecimal(n.fatG)) g, fibre \(oneDecimal(n.fibreG)) g, sugar \(oneDecimal(n.sugarG)) g, "
        + "sodium \(whole(n.sodiumMg)) mg, sat fat \(oneDecimal(n.satFatG)) g"
    }

    private static func whole(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
