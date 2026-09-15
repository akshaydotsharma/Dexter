import Foundation

/// One estimated dish, exactly as the model returns it (#543).
///
/// Every field is optional and decoded leniently, the same contract
/// `ExtractedExpense` holds: the model is told to return `null` for anything it
/// cannot judge, and one bad field must not take the whole meal down. What the
/// model is NOT allowed to omit is the portion, and that rule lives in
/// `MealEstimateGuards`, not here — a decoder that refused a portionless item
/// would silently drop it and leave a meal whose totals no longer describe the
/// description they came from.
struct EstimatedMealItem: Decodable, Sendable, Equatable {
    let name: String?

    /// How much of this dish the estimate assumed, in `portionUnit`.
    let portionQuantity: Double?

    /// The unit the assumption is stated in. The prompt allows exactly two,
    /// "g" and "ml", because a weight or a volume is the only portion a later
    /// correction can scale by a ratio. "1 bowl" cannot be halved by anyone.
    let portionUnit: String?

    let calories: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fibreG: Double?
    let sugarG: Double?
    let sodiumMg: Double?
    let satFatG: Double?

    /// Explicit rather than synthesised, so every field defaults to nil.
    ///
    /// A `let` optional gets no default in a memberwise initialiser, which would
    /// make every fixture in the guard tests spell out eleven arguments to vary
    /// one of them. The tests are the reason this type is worth constructing by
    /// hand at all.
    init(
        name: String? = nil,
        portionQuantity: Double? = nil,
        portionUnit: String? = nil,
        calories: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        fibreG: Double? = nil,
        sugarG: Double? = nil,
        sodiumMg: Double? = nil,
        satFatG: Double? = nil
    ) {
        self.name = name
        self.portionQuantity = portionQuantity
        self.portionUnit = portionUnit
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
    }

    enum CodingKeys: String, CodingKey {
        case name
        case portionQuantity = "portion_quantity"
        case portionUnit     = "portion_unit"
        case calories
        case proteinG  = "protein_g"
        case carbsG    = "carbs_g"
        case fatG      = "fat_g"
        case fibreG    = "fibre_g"
        case sugarG    = "sugar_g"
        case sodiumMg  = "sodium_mg"
        case satFatG   = "saturated_fat_g"
    }
}

/// One parsed meal estimate (#543).
///
/// ### Why there are no meal-level totals here
///
/// The model returns items and nothing else that is numeric. The meal's eight
/// values are `MealNutrients.sum(of:)` over the items, computed in Swift.
///
/// A model that stated both a total and a breakdown would state them twice, and
/// two numbers for one thing drift: the consistency check would then have to
/// pick which of the two it was testing, and correcting one item would leave a
/// total that no longer matched its own parts. Summing removes the question.
struct EstimatedMeal: Decodable, Sendable, Equatable {
    /// `MealType.rawValue` the model inferred from the description, or nil when
    /// it could not tell. A user-picked type always wins over this.
    let mealType: String?

    let items: [EstimatedMealItem]

    /// True when the meal contains beer, wine, spirits or a mixed drink.
    ///
    /// This one flag is the whole reason the macro consistency check is usable.
    /// Alcohol carries about 7 kcal per gram and is not protein, carbohydrate
    /// or fat, so `4P + 4C + 9F` under-counts a drink's calories by the entire
    /// alcohol content and the check fires on every beer. See
    /// `MealEstimateGuards`.
    let containsAlcohol: Bool?

    /// "high", "medium" or "low". Banded rather than free-scale, because a
    /// model asked for 0.73 returns a number it cannot justify; `numeric`
    /// converts for `LocalMeal.confidence`.
    let confidence: String?

    /// What the estimate assumed and the user never said. Stored on the meal so
    /// a correction has something to argue with.
    let assumptions: String?

    /// True when the description names no identifiable food at all. The meal
    /// still saves — with its description, zero nutrients and a needs-detail
    /// flag — because losing the fact that you ate is worse than losing the
    /// number, and inventing the number is worse than both.
    let noFoodIdentified: Bool?

    enum CodingKeys: String, CodingKey {
        case mealType         = "meal_type"
        case items
        case containsAlcohol  = "contains_alcohol"
        case confidence
        case assumptions
        case noFoodIdentified = "no_food_identified"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mealType         = try c.decodeIfPresent(String.self, forKey: .mealType)
        items            = try c.decodeIfPresent([EstimatedMealItem].self, forKey: .items) ?? []
        containsAlcohol  = try c.decodeIfPresent(Bool.self, forKey: .containsAlcohol)
        confidence       = try c.decodeIfPresent(String.self, forKey: .confidence)
        assumptions      = try c.decodeIfPresent(String.self, forKey: .assumptions)
        noFoodIdentified = try c.decodeIfPresent(Bool.self, forKey: .noFoodIdentified)
    }

    /// Memberwise init for tests and for the needs-detail fallback.
    init(
        mealType: String? = nil,
        items: [EstimatedMealItem] = [],
        containsAlcohol: Bool? = nil,
        confidence: String? = nil,
        assumptions: String? = nil,
        noFoodIdentified: Bool? = nil
    ) {
        self.mealType = mealType
        self.items = items
        self.containsAlcohol = containsAlcohol
        self.confidence = confidence
        self.assumptions = assumptions
        self.noFoodIdentified = noFoodIdentified
    }

    /// The banded confidence as the 0...1 `LocalMeal.confidence` stores.
    ///
    /// An unrecognised or missing band reads as low rather than as zero: zero is
    /// what a meal the model could not estimate at all carries, and a returned
    /// estimate is never that.
    var numericConfidence: Double {
        switch confidence?.lowercased() {
        case "high":   return 0.9
        case "medium": return 0.6
        default:       return 0.3
        }
    }
}

/// Errors surfaced to the Meals UI when an estimate fails (#543).
///
/// Mirrors `ReceiptExtractionError` case for case, and for the same reason: the
/// caller needs to tell "no key configured" (a setup problem the user can fix)
/// from "the model answered something unparseable" (retry) from "no network"
/// (retry later). The meal is never lost to any of them — the composer keeps the
/// typed description and offers to save it with no numbers.
enum MealEstimationError: LocalizedError {
    case notConfigured
    case emptyDescription
    case transport(Error)
    case http(Int, String)
    case noJSON
    case parse(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API key not configured."
        case .emptyDescription:
            return "Describe the meal first."
        case .transport(let err):
            return "Couldn't reach Anthropic. \(err.localizedDescription)"
        case .http(let status, let preview):
            return "Anthropic API HTTP \(status). \(preview)"
        case .noJSON:
            return "Couldn't find a JSON block in Claude's response."
        case .parse(let err):
            return "Couldn't parse Claude's response. \(err.localizedDescription)"
        }
    }
}

extension AnthropicClient {

    /// Estimate one meal from a text description. Exactly ONE API call.
    ///
    /// Built like `extractExpense(imageData:mediaType:)`: a hand-rolled JSON
    /// body, a schema in the prompt, a fenced-JSON reply, a lenient decode. The
    /// difference is only the payload — text in, items out.
    ///
    /// - Parameters:
    ///   - description: what the user typed or spoke, verbatim.
    ///   - mealTypeHint: the type the user picked, or nil to let the model
    ///     infer it from the description and the time of day.
    ///   - loggedAt: the instant the meal is being logged at, so an inferred
    ///     meal type has a clock to reason from. A 21:00 "toast" is supper, not
    ///     breakfast.
    func estimateMeal(
        description: String,
        mealTypeHint: MealType? = nil,
        loggedAt: Date = Date()
    ) async throws -> EstimatedMeal {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MealEstimationError.emptyDescription }

        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw MealEstimationError.notConfigured
        }

        let prompt = Self.mealEstimationPrompt(
            description: trimmed,
            mealTypeHint: mealTypeHint,
            loggedAt: loggedAt
        )

        // Hand-rolled body for the same reason the receipt extractor uses one:
        // `AnthropicRequest` carries the tool-use shape this call does not want.
        //
        // A meal can decompose into a lot of dishes and each one states eleven
        // fields, so the shared 1024-token ceiling is too tight here. 2048 is
        // roughly twelve dishes with an assumptions note, which is more than any
        // single description has produced.
        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": .int(2048),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(prompt)
                        ])
                    ])
                ])
            ])
        ])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // Text in, JSON out. Nothing here is slow the way a PDF read is, but a
        // cold connection on a phone still beats URLSession's 60s default
        // occasionally, and a composer that gives up is worse than one that waits.
        request.timeoutInterval = 60

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw MealEstimationError.parse(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MealEstimationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MealEstimationError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw MealEstimationError.http(http.statusCode, preview)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try Self.decoder.decode(AnthropicResponse.self, from: data)
        } catch {
            throw MealEstimationError.parse(error)
        }

        let combinedText = decoded.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")

        guard let jsonString = Self.firstJSONBlock(in: combinedText),
              let jsonData = jsonString.data(using: .utf8) else {
            throw MealEstimationError.noJSON
        }
        do {
            return try Self.decoder.decode(EstimatedMeal.self, from: jsonData)
        } catch {
            throw MealEstimationError.parse(error)
        }
    }

    // MARK: - Prompt

    /// The meal types advertised to the model, kept in sync with `MealType` so
    /// a returned string always maps back to the enum.
    private static var mealTypeList: String {
        MealType.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }

    /// Build the estimation prompt.
    ///
    /// Note what is NOT asked for: meal totals, a suspect flag, a "does this add
    /// up" self-check. Every one of those is decided in Swift afterwards, in
    /// `MealEstimateGuards`. Prompts drift between model versions; code does
    /// not, and a guard the model grades itself against is not a guard.
    static func mealEstimationPrompt(
        description: String,
        mealTypeHint: MealType?,
        loggedAt: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: loggedAt)

        let typeInstruction: String
        if let mealTypeHint {
            typeInstruction = """
            - "meal_type": the user has already chosen "\(mealTypeHint.rawValue)". \
            Return that exact value.
            """
        } else {
            typeInstruction = """
            - "meal_type": one of \(mealTypeList). Infer it from the description \
            and from the local clock time, which is \(clock). A dish that is \
            eaten at any hour and gives no other signal is "snack".
            """
        }

        return """
        Estimate the nutrition of this meal from its description. The description
        is the only input: there is no database lookup, no portion picker and no
        serving dropdown, so every quantity you use is an assumption you must
        state.

        The description, verbatim:
        \(description)

        Return STRICT JSON inside a ```json fence and nothing else — no prose
        before or after.

        Schema:
        {
          "meal_type": "lunch",
          "items": [
            {
              "name": "Poached egg",
              "portion_quantity": 100,
              "portion_unit": "g",
              "calories": 143,
              "protein_g": 12.6,
              "carbs_g": 0.7,
              "fat_g": 9.5,
              "fibre_g": 0,
              "sugar_g": 0.4,
              "sodium_mg": 142,
              "saturated_fat_g": 3.1
            }
          ],
          "contains_alcohol": false,
          "confidence": "medium",
          "assumptions": "Two medium eggs, one slice of white toast, 10 g butter.",
          "no_food_identified": false
        }

        Rules:
        \(typeInstruction)
        - "items": one object per DISTINCT dish or drink in the description.
          Break the meal down rather than returning one lumped row: "chicken rice
          and a teh tarik" is two items, not one. A decomposed estimate is more
          accurate, and it lets one component be corrected later without
          re-estimating the rest.
        - "portion_quantity" and "portion_unit" are REQUIRED on every item and
          must never be null. "portion_unit" must be exactly "g" or "ml" —
          grams for anything solid, millilitres for anything poured. Do NOT
          return "bowl", "slice", "serving", "cup" or any other household
          measure: a weight or a volume can be scaled by a ratio when the user
          corrects it, and a household measure cannot.
        - "portion_quantity" is the TOTAL amount of that item in the meal. Two
          eggs is one item at 100 g, not two items at 50 g.
        - The eight nutrient values on each item describe THAT item at THAT
          portion. Units: calories in kcal, sodium in mg, everything else in
          grams. Never return a null or a negative number — use 0 for a nutrient
          the food genuinely has none of.
        - Do not return meal totals. The totals are the sum of the items and are
          computed from them.
        - "contains_alcohol": true if any item is beer, wine, cider, a spirit or
          a mixed drink. Get this right even when the alcohol is a small part of
          the meal; it changes how the numbers are checked.
        - "confidence": one of "high", "medium", "low". Reflect how sure you are
          about the PORTIONS specifically, which is where a text-derived estimate
          goes wrong, not about whether you recognised the food.
        - "assumptions": one or two plain sentences naming what you assumed and
          the user never said — portion sizes, cooking oil, a default drink size,
          a default preparation. This is the most useful thing you return.
          Null only if you genuinely assumed nothing.
        - "no_food_identified": true, with an EMPTY "items" array, when the
          description names nothing edible. Do not invent a meal to fill the
          schema. Returning nothing is correct; returning a guess is not.

        Do not invent fields. Do not add commentary outside the JSON fence.
        """
    }
}
