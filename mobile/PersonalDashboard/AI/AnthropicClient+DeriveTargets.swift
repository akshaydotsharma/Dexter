import Foundation

/// One derivation's answer, exactly as the model returns it (#544).
///
/// Every figure is optional and decoded leniently, the same contract
/// `EstimatedMealItem` holds. The reason is different here, and worth stating:
/// the eight go into an EDITABLE review screen, so a nutrient the model
/// declined to answer for leaves its field as it was and the user types it.
/// A decoder that refused the whole reply over one missing key would throw away
/// seven good numbers and a rationale.
///
/// `nil` and "0" are therefore not the same thing. Nil means the model said
/// nothing; zero means it said the target is zero. `MealTargetDraft.apply`
/// honours the difference.
struct DerivedMealTargets: Decodable, Sendable, Equatable {
    let calories: Double?
    let proteinG: Double?
    let carbsG: Double?
    let fatG: Double?
    let fibreG: Double?
    let sugarG: Double?
    let sodiumMg: Double?
    let satFatG: Double?

    /// How the eight came out of the six, in plain sentences. Stored on the
    /// record beside the numbers it describes, so there is always an audit
    /// trail for why a target is what it is.
    let rationale: String?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG  = "protein_g"
        case carbsG    = "carbs_g"
        case fatG      = "fat_g"
        case fibreG    = "fibre_g"
        case sugarG    = "sugar_g"
        case sodiumMg  = "sodium_mg"
        case satFatG   = "saturated_fat_g"
        case rationale
    }

    /// Explicit rather than synthesised, so every field defaults to nil and a
    /// test can vary one of nine without spelling out the other eight.
    init(
        calories: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        fibreG: Double? = nil,
        sugarG: Double? = nil,
        sodiumMg: Double? = nil,
        satFatG: Double? = nil,
        rationale: String? = nil
    ) {
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.rationale = rationale
    }

    /// One nutrient's proposed figure, so a loop over `Nutrient.allCases`
    /// covers all eight without naming a field. Paired with
    /// `MealTargets.target(for:)`, which reads the same eight back out.
    func value(for nutrient: Nutrient) -> Double? {
        switch nutrient {
        case .calories:     return calories
        case .protein:      return proteinG
        case .carbs:        return carbsG
        case .fat:          return fatG
        case .fibre:        return fibreG
        case .sugar:        return sugarG
        case .sodium:       return sodiumMg
        case .saturatedFat: return satFatG
        }
    }
}

/// Errors surfaced to the targets sheet (#544).
///
/// Case for case with `MealEstimationError`, including the `.truncated` /
/// `.noJSON` split, which is not cosmetic: one of them means "ask again", the
/// other means "the model answered wrongly", and reporting the first as the
/// second makes the Try again button look like superstition when it is the
/// correct move.
enum MealTargetDerivationError: LocalizedError {
    case notConfigured
    case incompleteInputs(String)
    case transport(Error)
    case http(Int, String)
    case noJSON
    /// The generation hit `max_tokens`, so the JSON was cut off mid-object and
    /// no closing fence ever arrived.
    case truncated
    case parse(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API key not configured."
        case .incompleteInputs(let problem):
            return problem
        case .transport(let err):
            return "Couldn't reach Anthropic. \(err.localizedDescription)"
        case .http(let status, let preview):
            return "Anthropic API HTTP \(status). \(preview)"
        case .noJSON:
            return "Couldn't find a JSON block in Claude's response."
        case .truncated:
            return "The derivation was cut off before it finished. Try again."
        case .parse(let err):
            return "Couldn't parse Claude's response. \(err.localizedDescription)"
        }
    }
}

extension AnthropicClient {

    /// Derive the eight daily targets from the six inputs. Exactly ONE API call.
    ///
    /// Deriving is a one-time cost, so there is no call on render, no call to
    /// validate a field, and no second call to check the first. The answer lands
    /// in an editable review screen and nothing is written until Save.
    ///
    /// Built like `estimateMeal(description:)`: a hand-rolled JSON body, a
    /// schema in the prompt, a fenced-JSON reply, a lenient decode.
    func deriveMealTargets(inputs: MealTargetInputs) async throws -> DerivedMealTargets {
        if let problem = inputs.problem {
            throw MealTargetDerivationError.incompleteInputs(problem)
        }

        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw MealTargetDerivationError.notConfigured
        }

        let prompt = Self.mealTargetsPrompt(inputs: inputs)

        // Hand-rolled body for the same reason the meal estimator uses one:
        // `AnthropicRequest` carries the tool-use shape this call does not want.
        //
        // 8192, and NOT a smaller cap sized by how short the answer looks. The
        // reply here is nine fields, so a couple of hundred tokens would seem
        // generous — but this model returns a `thinking` block and thinking
        // spends the SAME max_tokens budget the answer needs. That is precisely
        // how #543 shipped a meal estimator at 2048 that reported "couldn't
        // find a JSON block" for a response that had merely been cut off. A
        // derivation reasons through an energy equation, a deficit or surplus
        // and eight nutrient splits before it writes anything, so its thinking
        // is LONGER than a meal estimate's, not shorter. Sizing this cap by
        // guesswork is the one mistake this call already knows how to make.
        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": .int(8192),
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
        request.timeoutInterval = 60

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw MealTargetDerivationError.parse(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MealTargetDerivationError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MealTargetDerivationError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw MealTargetDerivationError.http(http.statusCode, preview)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try Self.decoder.decode(AnthropicResponse.self, from: data)
        } catch {
            throw MealTargetDerivationError.parse(error)
        }

        let combinedText = decoded.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")

        guard let jsonString = Self.firstJSONBlock(in: combinedText),
              let jsonData = jsonString.data(using: .utf8) else {
            // Order matters: a truncated reply has no closing fence, so it
            // fails the same parse a malformed one does. Ask WHY the fence is
            // missing before reporting it missing.
            if decoded.stop_reason == "max_tokens" { throw MealTargetDerivationError.truncated }
            throw MealTargetDerivationError.noJSON
        }
        do {
            return try Self.decoder.decode(DerivedMealTargets.self, from: jsonData)
        } catch {
            throw MealTargetDerivationError.parse(error)
        }
    }

    // MARK: - Prompt

    /// A measurement as the whole number the form collected. Local rather than
    /// `MealFormat.grams`, which names a nutrient unit and would read as one.
    private static func whole(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    /// Build the derivation prompt.
    ///
    /// Names Mifflin St Jeor explicitly rather than asking for "a reasonable
    /// estimate". The equation is the reason biological sex is one of the six
    /// inputs, and a prompt that leaves the method open gets a different method
    /// on a different day, which would move a user's targets for no reason they
    /// could see.
    static func mealTargetsPrompt(inputs: MealTargetInputs) -> String {
        """
        Work out sensible daily nutrition targets for one person from the six
        facts below. All units are metric.

        - Age: \(inputs.ageYears) years
        - Biological sex: \(inputs.biologicalSex.rawValue)
        - Height: \(Self.whole(inputs.heightCm)) cm
        - Weight: \(Self.whole(inputs.weightKg)) kg
        - Activity level: \(inputs.activityLevel.rawValue) (\(inputs.activityLevel.detail.lowercased()))
        - Goal: \(inputs.goal.rawValue)

        Method, in this order:
        1. Resting energy with the Mifflin St Jeor equation, using the
           sex-specific constant.
        2. Total daily energy by applying the activity multiplier for the band
           named above.
        3. Adjust that total for the goal: a moderate deficit to lose, no change
           to maintain, a small surplus to gain muscle or to gain weight. Keep
           any deficit safe — do not go below the resting energy figure from
           step 1.
        4. Split the energy into protein, carbohydrate and fat, then set fibre,
           and set the three ceilings (sugar, sodium, saturated fat) from
           ordinary public health guidance for that energy level. Protein
           follows the goal: higher to gain muscle, higher again in a deficit to
           protect lean mass.

        Return STRICT JSON inside a ```json fence and nothing else — no prose
        before or after.

        Schema:
        {
          "calories": 2150,
          "protein_g": 140,
          "carbs_g": 235,
          "fat_g": 70,
          "fibre_g": 30,
          "sugar_g": 54,
          "sodium_mg": 2000,
          "saturated_fat_g": 24,
          "rationale": "Mifflin St Jeor puts your resting energy near 1,700 kcal. …"
        }

        Rules:
        - All eight figures are REQUIRED and must be positive whole numbers.
          Never return null, a string, a range or a negative number.
        - Units: "calories" in kcal, "sodium_mg" in milligrams, every other
          figure in grams. Do not restate the unit inside the value.
        - "calories", "carbs_g" and "fat_g" are the MIDDLE of a band: a day far
          under is as much a miss as a day far over.
        - "protein_g" and "fibre_g" are FLOORS: figures to reach.
        - "sugar_g", "sodium_mg" and "saturated_fat_g" are CEILINGS: limits to
          stay under. Give the added-sugar limit, not total sugar.
        - The four energy-bearing figures must be consistent with "calories"
          under the Atwater factors (4 kcal per gram of protein and of
          carbohydrate, 9 per gram of fat). Check the arithmetic before you
          answer.
        - "rationale": three or four plain sentences, in English, naming the
          resting energy figure, the activity multiplier, what the goal changed,
          and why protein landed where it did. Write it for the person whose
          targets these are, in the second person. No markdown, no bullet list,
          no headings.

        Do not invent fields. Do not add commentary outside the JSON fence.
        """
    }
}
