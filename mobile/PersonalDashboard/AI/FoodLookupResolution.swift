import Foundation

/// Turns what the model CLAIMED about its sources into what the device KNOWS
/// about them, and does the arithmetic itself wherever a claim checks out
/// (#653).
///
/// ### Why a verification step exists at all
///
/// The estimate now carries `source_id` and `mass_source`, and both are written
/// by the model. A model asked to report its own provenance can report
/// provenance it does not have — not usually by lying, but by pattern-matching:
/// it looked something up for item one, and item three inherits the shape of
/// the answer. If that went unchecked, the confidence band derived from it
/// would be exactly the thing this whole change set out to remove: a number
/// that sounds sourced and is not.
///
/// So the device keeps its own record. `FoodLookupLedger` holds every candidate
/// id it handed over during the turn, and an id that is not in it was never
/// offered. The same argument `WebSearchGrounding` makes for reading sources
/// off the wire rather than out of the model's prose.
///
/// ### Why the device recomputes the numbers
///
/// Verification alone would leave the model's transcription of the candidate's
/// figures in place, and a transcription is a step that can go wrong silently.
/// When an id checks out, the device throws the model's eight numbers away and
/// computes them from the candidate's own per-100 figures at the stated
/// portion. The model's job becomes choosing the right row and the right
/// amount; the arithmetic is Swift's.
///
/// This is `saved_item_id` (#625) generalised. That mechanism already works
/// exactly this way, and it is the reason the only 1.0-confidence meals in the
/// store came from the library.
enum FoodLookupResolution {

    /// What one item's numbers turned out to be, and where they really came
    /// from.
    struct ResolvedItem: Sendable, Equatable {
        let item: EstimatedMealItem
        let densitySource: MealDensitySource
        let massSource: MealMassSource

        /// The candidate id, kept only when it was verified. A rejected claim
        /// leaves no trace on the item, because a stored id nothing checked
        /// would read exactly like one something did.
        let sourceID: String?
    }

    /// Apply the ledger to an estimate.
    ///
    /// - Parameters:
    ///   - estimate: what the model returned, unverified.
    ///   - ledger: what the device actually offered during this turn. An empty
    ///     ledger is the ordinary case for a path with no lookups, and every
    ///     item then resolves as estimated, which is the truth.
    ///   - wasGrounded: the turn's web search returned at least one page
    ///     (#594). Used only to distinguish `published` from `estimated` for an
    ///     item carrying no candidate id, because a brand's panel arrives as
    ///     prose in a search result and has no id to quote.
    ///   - description: what the user typed, verbatim. Used to recover a mass
    ///     the model was told to report as `stated` and reported as a guess —
    ///     see `statedQuantities(in:)`.
    /// - Returns: the estimate with substituted figures, and the provenance the
    ///   device is prepared to stand behind.
    static func resolve(
        _ estimate: EstimatedMeal,
        ledger: FoodLookupLedger,
        wasGrounded: Bool = false,
        description: String = "",
        portionHistory: [MealPortionHistory.Entry] = []
    ) -> (estimate: EstimatedMeal, resolved: [ResolvedItem]) {
        var resolvedItems: [ResolvedItem] = []
        let stated = statedQuantities(in: description, items: estimate.items)

        for (index, raw) in estimate.items.enumerated() {
            var claimedMass = MealMassSource(rawValue: raw.massSource ?? "") ?? .estimated
            // The device knows better than the model here, and only ever in the
            // one direction: it can prove the user stated a weight, it cannot
            // prove they did not.
            if stated.contains(index), !claimedMass.isSourced {
                claimedMass = .stated
            }
            // #655. A model that says it converted a raw weight and returns
            // the raw number unchanged has contradicted itself, and the
            // contradiction is visible from here: the description holds the
            // figure and the item holds the same one.
            //
            // This is the one raw-versus-cooked error the device can actually
            // catch. It cannot see an unconverted weight the user never wrote
            // down, which is why the key is REQUIRED in the schema rather than
            // asked for in prose — the schema is what makes the model answer,
            // and this only checks the answer.
            if raw.portionBasis == "converted_from_raw", stated.contains(index) {
                claimedMass = .estimated
            }

            // A history claim is checkable for the same reason a portion-table
            // quote is: the device is holding the list the model was shown.
            if claimedMass == .history,
               !MealPortionHistory.supports(
                   name: raw.name,
                   quantity: raw.portionQuantity ?? 0,
                   unit: raw.portionUnit ?? "",
                   in: portionHistory
               ) {
                claimedMass = .estimated
            }

            // A candidate the device really offered. Anything else — an id from
            // a previous turn, an id for a different meal, an id shaped like one
            // — is not in this ledger and is refused.
            guard let id = trimmed(raw.sourceID),
                  let candidate = ledger.candidate(id) else {
                resolvedItems.append(
                    ResolvedItem(
                        item: raw,
                        // A grounded turn's figures may genuinely come from a
                        // published panel, which has no id to check. That is a
                        // weaker guarantee than a verified lookup and is
                        // recorded as its own case rather than folded into
                        // either neighbour.
                        densitySource: wasGrounded ? .published : .estimated,
                        massSource: claimedMass,
                        sourceID: nil
                    )
                )
                continue
            }

            // The candidate's figures are per 100 g or per 100 ml, so the
            // portion has to be a weight or a volume for the ratio to mean
            // anything. `MealEstimateGuards` refuses anything else anyway; here
            // it means the substitution cannot be done and the model's own
            // numbers stand.
            let unit = (raw.portionUnit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let quantity = raw.portionQuantity ?? 0
            guard quantity.isFinite, quantity > 0,
                  MealEstimateGuards.scalableUnits.contains(unit) else {
                resolvedItems.append(
                    ResolvedItem(
                        item: raw,
                        densitySource: candidate.density,
                        massSource: claimedMass,
                        sourceID: id
                    )
                )
                continue
            }

            let computed = MealNutrients.scaled(
                candidate.nutrientsPer100,
                fromBasePortion: 100,
                to: quantity
            )

            // A mass claimed as a standard portion is checked against the
            // candidate's own portion table, because that is the only claim in
            // the set the device can actually verify. A weight matching none of
            // the published rows is a guess wearing a citation.
            let verifiedMass = verify(
                claimedMass,
                quantity: quantity,
                against: candidate
            )

            resolvedItems.append(
                ResolvedItem(
                    item: EstimatedMealItem(
                        // The database's own description is NOT adopted here.
                        // "Chicken curry" is what the dataset calls it; the user
                        // wrote "mum's chicken curry" and that is their record
                        // of the meal. The id preserves the trace either way.
                        name: raw.name,
                        portionQuantity: quantity,
                        portionUnit: unit,
                        calories: computed.calories,
                        proteinG: computed.proteinG,
                        carbsG: computed.carbsG,
                        fatG: computed.fatG,
                        fibreG: computed.fibreG,
                        sugarG: computed.sugarG,
                        sodiumMg: computed.sodiumMg,
                        satFatG: computed.satFatG,
                        savedItemID: raw.savedItemID,
                        sourceID: id,
                        massSource: verifiedMass.rawValue
                    ),
                    densitySource: candidate.density,
                    massSource: verifiedMass,
                    sourceID: id
                )
            )
        }

        let rebuilt = EstimatedMeal(
            mealType: estimate.mealType,
            title: estimate.title,
            items: resolvedItems.map(\.item),
            containsAlcohol: estimate.containsAlcohol,
            confidence: estimate.confidence,
            assumptions: estimate.assumptions,
            noFoodIdentified: estimate.noFoodIdentified
        )
        return (rebuilt, resolvedItems)
    }

    /// Check a `standard_portion` claim against the candidate's portion table.
    ///
    /// Only that one case is checkable. "The user stated it" is a fact about the
    /// description, "a packet published it" is a fact about a packet, and
    /// "history" is a fact about the store; none of them is visible from here,
    /// so each is taken at face value. A standard portion, though, is a claim
    /// about a table the device is holding, and a quantity that appears nowhere
    /// in it is demoted to `estimated`.
    ///
    /// The tolerance is 2%, which is rounding, not latitude: the model is meant
    /// to be quoting a number it was shown, not adapting one.
    static func verify(
        _ claimed: MealMassSource,
        quantity: Double,
        against candidate: FoodLookupCandidate
    ) -> MealMassSource {
        guard claimed == .standardPortion else { return claimed }
        let matches = candidate.portions.contains { portion in
            guard portion.gramWeight > 0 else { return false }
            return abs(portion.gramWeight - quantity) / portion.gramWeight <= 0.02
        }
        return matches ? .standardPortion : .estimated
    }

    /// The indices of items whose portion the USER actually stated (#653).
    ///
    /// ### Why this is in Swift and not in the prompt
    ///
    /// It was in the prompt. `MealToolSchema.estimateRules` tells the model to
    /// set `mass_source` to "stated" when the user gave the weight, and a live
    /// run on 2026-09-22 showed it doing the opposite on the clearest possible
    /// case: the description read "250 g cooked chicken Indian curry", the item
    /// came back at exactly 250 g, and `mass_source` came back "estimated".
    /// Everything else in that estimate was right.
    ///
    /// That is the failure mode #484 to #487 cost four rounds to learn, and the
    /// lesson written down from it was: a rule the model keeps dropping belongs
    /// in the schema or in code, not in prose. This is the code half. The rule
    /// stays in the prompt as well, because a model that gets it right saves
    /// this from having to be clever.
    ///
    /// ### Why it can only ever promote
    ///
    /// The device can prove that a number appears in the description. It cannot
    /// prove the absence of an intention — "a can of coke" states 330 ml to a
    /// human and to a model, and nothing here would see it. So a match upgrades
    /// a guess to `stated` and nothing here ever downgrades a claim.
    ///
    /// ### The ambiguity rule
    ///
    /// A figure that would fit two items is used for neither. "200 g of rice
    /// and 200 g of chicken" states both, but this function cannot tell which
    /// 200 belongs to which row, and attributing one confidently is worse than
    /// attributing neither: it would mark an item as user-stated on the
    /// strength of a coincidence. The model is expected to get that case right
    /// itself; this is a floor, not a replacement.
    static func statedQuantities(in description: String, items: [EstimatedMealItem]) -> Set<Int> {
        guard !description.isEmpty, !items.isEmpty else { return [] }

        let figures = quantities(in: description)
        guard !figures.isEmpty else { return [] }

        var out: Set<Int> = []
        for figure in figures {
            let matches = items.indices.filter { index in
                let item = items[index]
                guard let quantity = item.portionQuantity, quantity > 0 else { return false }
                let unit = (item.portionUnit ?? "").lowercased()
                guard unit == figure.unit else { return false }
                return abs(quantity - figure.value) / figure.value <= 0.02
            }
            // Exactly one, for the reason above.
            if matches.count == 1 { out.insert(matches[0]) }
        }
        return out
    }

    /// Every weight and volume written in a description, normalised to g or ml.
    ///
    /// Deliberately narrow. It reads the two units the app stores and the
    /// common spellings of them, and it does NOT try to read "a cup", "two
    /// slices" or "half a plate": those are the portions this feature exists to
    /// resolve from a portion table, and guessing at them here would put the
    /// device back in the business of inventing masses.
    static func quantities(in description: String) -> [(value: Double, unit: String)] {
        // A number, optional space, then a unit word that ENDS there. The word
        // boundary matters: without it "150 grams" matches "g" and reports 150
        // twice, and "2 gulab jamun" matches "g" and reports a weight nobody
        // wrote.
        let pattern = #"(\d+(?:\.\d+)?)\s*(kg|kgs|g|gm|gms|gram|grams|ml|mls|millilitre|millilitres|milliliter|milliliters|l|litre|litres|liter|liters)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let text = description as NSString
        let matches = regex.matches(in: description, range: NSRange(location: 0, length: text.length))

        return matches.compactMap { match -> (Double, String)? in
            guard match.numberOfRanges == 3,
                  let value = Double(text.substring(with: match.range(at: 1))) else { return nil }
            let rawUnit = text.substring(with: match.range(at: 2)).lowercased()
            switch rawUnit {
            case "kg", "kgs":
                return (value * 1000, "g")
            case "g", "gm", "gms", "gram", "grams":
                return (value, "g")
            case "l", "litre", "litres", "liter", "liters":
                return (value * 1000, "ml")
            default:
                return (value, "ml")
            }
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
