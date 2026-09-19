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

    /// The `LocalFoodItem.clientUUID` of the saved library row this dish IS
    /// (#625), or nil for a dish the model estimated.
    ///
    /// It carries no numbers of its own on purpose. The eight above stay the
    /// model's answer, and `ExecuteDraftAction` replaces them with the stored
    /// row's figures scaled to `portionQuantity`. That ordering is what makes a
    /// hallucinated id cost accuracy and never the log: an id naming no row
    /// leaves the model's own estimate in place.
    ///
    /// Only the tool path ever sets it. The composer's fenced-JSON prompt does
    /// not advertise the field, so a decode of that reply lands nil here.
    let savedItemID: String?

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
        satFatG: Double? = nil,
        savedItemID: String? = nil
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
        self.savedItemID = savedItemID
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
        case savedItemID = "saved_item_id"
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

    /// The dish in a few words, for the row a list draws (#603).
    ///
    /// Asked for in the same call that estimates the meal, so it costs nothing:
    /// the model has already read the description and broken it into dishes by
    /// the time it answers. Nil when the model did not name it, which
    /// `MealDisplayName` handles rather than treating as an error — a meal with
    /// no short name is still a meal.
    let title: String?

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
        case title
        case items
        case containsAlcohol  = "contains_alcohol"
        case confidence
        case assumptions
        case noFoodIdentified = "no_food_identified"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mealType         = try c.decodeIfPresent(String.self, forKey: .mealType)
        title            = try c.decodeIfPresent(String.self, forKey: .title)
        items            = try c.decodeIfPresent([EstimatedMealItem].self, forKey: .items) ?? []
        containsAlcohol  = try c.decodeIfPresent(Bool.self, forKey: .containsAlcohol)
        confidence       = try c.decodeIfPresent(String.self, forKey: .confidence)
        assumptions      = try c.decodeIfPresent(String.self, forKey: .assumptions)
        noFoodIdentified = try c.decodeIfPresent(Bool.self, forKey: .noFoodIdentified)
    }

    /// Memberwise init for tests and for the needs-detail fallback.
    init(
        mealType: String? = nil,
        title: String? = nil,
        items: [EstimatedMealItem] = [],
        containsAlcohol: Bool? = nil,
        confidence: String? = nil,
        assumptions: String? = nil,
        noFoodIdentified: Bool? = nil
    ) {
        self.mealType = mealType
        self.title = title
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

/// An estimate and what, if anything, grounded it (#594).
///
/// Two values rather than a field on `EstimatedMeal` because they come from two
/// different places and must not be allowed to look alike. `estimate` is what
/// the model SAID, decoded from its JSON. `groundingSources` is what the wire
/// SHOWS: the pages its own web search returned. A model cannot write itself a
/// source list here, which is the point.
struct GroundedMealEstimate: Sendable, Equatable {
    let estimate: EstimatedMeal

    /// Empty when the estimate was not grounded, which covers three cases that
    /// are all the same case for the user: no search was needed, the search
    /// found nothing, or the search failed. None of them produced a published
    /// figure to point at.
    let groundingSources: [WebSearchSource]

    init(estimate: EstimatedMeal, groundingSources: [WebSearchSource] = []) {
        self.estimate = estimate
        self.groundingSources = groundingSources
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
    /// The generation hit `max_tokens`, so the JSON was cut off mid-object and
    /// no closing fence ever arrived. Distinct from `noJSON`, which means the
    /// model answered fully and answered wrongly. Conflating them tells the
    /// user the reply was malformed when it was merely unfinished, and makes
    /// the "Try again" button look like superstition when it is the correct
    /// move. `AnthropicClient+ExtractStatement` has drawn this distinction
    /// since #189; this path did not inherit it.
    case truncated
    case parse(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API key not configured."
        case .emptyDescription:
            return "Describe the meal, or add a photo of it."
        case .transport(let err):
            return "Couldn't reach Anthropic. \(err.localizedDescription)"
        case .http(let status, let preview):
            return "Anthropic API HTTP \(status). \(preview)"
        case .noJSON:
            return "Couldn't find a JSON block in Claude's response."
        case .truncated:
            return "The estimate was cut off before it finished. Try again, or shorten the description."
        case .parse(let err):
            return "Couldn't parse Claude's response. \(err.localizedDescription)"
        }
    }
}

extension AnthropicClient {

    /// Estimate one meal from a text description.
    ///
    /// Built like `extractExpense(imageData:mediaType:)`: a hand-rolled JSON
    /// body, a schema in the prompt, a fenced-JSON reply, a lenient decode. The
    /// difference is only the payload — text in, items out.
    ///
    /// ### Why this is no longer exactly one call (#594)
    ///
    /// The request declares Anthropic's web-search server tool, so a branded
    /// description can be answered from the brand's published panel instead of
    /// from the model's memory of it. A turn that uses a server tool can come
    /// back with `stop_reason: "pause_turn"`, which means the turn is not
    /// finished rather than that it was malformed: the assistant's own content
    /// goes back up as an assistant message and the same request is posted
    /// again. `WebSearchGrounding.maxResumes` caps it at two, so a pathological
    /// turn costs three round trips and never loops.
    ///
    /// A generic description ("two eggs on toast") still costs one call and no
    /// search, because the rule the prompt carries says when to look something
    /// up and when not to. A search that fails comes back on an HTTP 200 with an
    /// error object where the results should be, and degrades to exactly the
    /// estimate this function returned before: no sources, a saveable meal.
    ///
    /// - Parameters:
    /// ### Why a photo does not make this a second function (#627)
    ///
    /// Everything below the content array is identical for a described meal and
    /// a photographed one: the same schema, the same guards downstream, the same
    /// resume loop, the same truncation handling. A separate `estimateMealPhoto`
    /// would have to be kept in step with all of it, and the one thing #475 and
    /// #500 each cost a release was a second extraction path that drifted from
    /// the first. So the photos ride the existing call as extra content blocks
    /// and change nothing else.
    ///
    /// - Parameters:
    ///   - description: what the user typed or spoke, verbatim. May be empty
    ///     when `photos` is not: a photograph is a complete input on its own.
    ///   - photos: photographs of the meal, sent as image blocks ahead of the
    ///     prompt. Empty is the ordinary text-only estimate, byte for byte the
    ///     request this function sent before #627.
    ///   - mealTypeHint: the type the user picked, or nil to let the model
    ///     infer it from the description and the time of day.
    ///   - loggedAt: the instant the meal is being logged at, so an inferred
    ///     meal type has a clock to reason from. A 21:00 "toast" is supper, not
    ///     breakfast.
    func estimateMeal(
        description: String,
        photos: [MealPhoto] = [],
        mealTypeHint: MealType? = nil,
        loggedAt: Date = Date()
    ) async throws -> GroundedMealEstimate {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // One or the other, not necessarily both. A plate in front of the camera
        // says as much as a sentence does, and refusing it would make the plus
        // button a decoration on an empty field.
        guard !trimmed.isEmpty || !photos.isEmpty else {
            throw MealEstimationError.emptyDescription
        }

        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw MealEstimationError.notConfigured
        }

        let prompt = Self.mealEstimationPrompt(
            description: trimmed,
            photoCount: photos.count,
            mealTypeHint: mealTypeHint,
            loggedAt: loggedAt
        )

        // Hand-rolled body for the same reason the receipt extractor uses one:
        // `AnthropicRequest` carries the tool-use shape this call does not want.
        //
        // A meal can decompose into a lot of dishes and each one states eleven
        // fields, so the shared 1024-token ceiling is too tight here.
        //
        // 2048 was too tight as well, and the reason is worth stating: this
        // model returns a `thinking` block, and thinking spends the SAME
        // max_tokens budget the answer needs. Measured against the live API, a
        // five-dish Indian dinner ("2 parathas, 250 g chicken gravy, a cup of
        // arhar dal, cucumber salad") needs about 2555 output tokens all in. At
        // 2048 the thinking consumed the budget and the JSON was cut off
        // mid-object, which surfaced to the user as "couldn't find a JSON
        // block" — a true statement about a response that had simply been
        // truncated. 8192 leaves room for the reasoning and a dozen dishes.
        //
        // NOT prompt-cached (#580). The prompt is one user block whose SECOND
        // paragraph is the meal description, so a breakpoint would have to sit
        // after text that differs every meal and would write an entry nothing
        // ever reads. Making it cacheable means moving the description to the
        // end of the prompt, which changes what the model reads first and cannot
        // be validated without live calls. Left alone deliberately, not
        // overlooked. The tool block added in #594 renders ahead of the prompt
        // and carries no marker either, for the same reason: nothing here is
        // cached at all.
        // Images ahead of the text, which is the order Anthropic documents for
        // a vision turn: the model reads the blocks in sequence, so a question
        // asked after the picture is a question about a picture it has already
        // seen. The reverse order asks it to hold an instruction in mind for an
        // image that has not arrived.
        var userContent: [AnthropicJSONValue] = photos.map { photo in
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(photo.mediaType),
                    "data": .string(photo.base64)
                ])
            ])
        }
        userContent.append(.object([
            "type": .string("text"),
            "text": .string(prompt)
        ]))

        var messages: [AnthropicJSONValue] = [
            .object([
                "role": .string("user"),
                "content": .array(userContent)
            ])
        ]

        var groundingSources: [WebSearchSource] = []
        var resumesUsed = 0

        while true {
            let body: AnthropicJSONValue = .object([
                "model": .string(Self.model),
                "max_tokens": .int(8192),
                // Declared on every estimate, used on almost none. The rule in
                // the prompt is what keeps a generic meal from paying for a
                // search; advertising the tool costs only its declaration.
                //
                // `code_execution` is deliberately NOT declared beside it. This
                // web-search variant runs code execution under the hood, and a
                // second declared execution environment confuses the model about
                // which one it is in.
                "tools": .array([WebSearchGrounding.toolJSON]),
                "messages": .array(messages)
            ])

            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            // Text in, JSON out. Nothing here is slow the way a PDF read is, but
            // a cold connection on a phone still beats URLSession's 60s default
            // occasionally, and a composer that gives up is worse than one that
            // waits. A turn that searches spends its time on Anthropic's side of
            // this request, so the ceiling covers the search too.
            //
            // 60 was that ceiling until #594 measured what a grounded turn
            // actually costs: two live runs of "Guzman y Gomez chicken burrito
            // bowl" took 38.5 s and then over 60 s, and the second one died on
            // this line. That is not a slow outlier to be cut off, it is the
            // normal spread of a turn that runs real searches, and cutting it
            // off throws away a working answer and makes the user retype the
            // meal. An ungrounded estimate never approaches either number, so
            // raising this costs the fast path nothing: a request that is going
            // to take 16 s still takes 16 s.
            request.timeoutInterval = 150

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

            // Read as raw JSON rather than through `AnthropicResponse`, because
            // the resume has to hand the assistant's content BACK unchanged and
            // that type models only the four block shapes this app produces
            // itself (#594). A `server_tool_use` and its `web_search_tool_result`
            // must travel together or the replay is rejected, and neither
            // survives the typed decode.
            guard let root = (try? Self.decoder.decode(AnthropicJSONValue.self, from: data))?
                .objectValue else {
                throw MealEstimationError.noJSON
            }
            let content = root["content"]?.arrayValue ?? []
            let stopReason = root["stop_reason"]?.stringValue

            for source in WebSearchGrounding.sources(inContent: content)
            where !groundingSources.contains(source) {
                groundingSources.append(source)
            }

            if WebSearchGrounding.shouldResume(stopReason: stopReason, resumesUsed: resumesUsed) {
                resumesUsed += 1
                // Empty text blocks are dropped for the reason
                // `AnthropicMessage.assistantReplay` gives: the API rejects the
                // whole message with "text content blocks must be non-empty".
                let replayed = content.filter { block in
                    guard let fields = block.objectValue else { return false }
                    guard fields["type"]?.stringValue == "text" else { return true }
                    let text = fields["text"]?.stringValue ?? ""
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                // A pause with nothing to replay would post the same request
                // again and pause again. Fall through and work with what came
                // back instead.
                if !replayed.isEmpty {
                    messages.append(.object([
                        "role": .string("assistant"),
                        "content": .array(replayed)
                    ]))
                    continue
                }
            }

            let combinedText = content.compactMap { block -> String? in
                guard let fields = block.objectValue,
                      fields["type"]?.stringValue == "text" else { return nil }
                return fields["text"]?.stringValue
            }.joined(separator: "\n")

            guard let jsonString = Self.firstJSONBlock(in: combinedText),
                  let jsonData = jsonString.data(using: .utf8) else {
                // Order matters: a truncated reply has no closing fence, so it
                // fails the same parse a malformed one does. Ask WHY the fence is
                // missing before reporting it missing.
                if stopReason == "max_tokens" { throw MealEstimationError.truncated }
                throw MealEstimationError.noJSON
            }
            do {
                return GroundedMealEstimate(
                    estimate: try Self.decoder.decode(EstimatedMeal.self, from: jsonData),
                    groundingSources: groundingSources
                )
            } catch {
                throw MealEstimationError.parse(error)
            }
        }
    }

    // MARK: - Prompt

    /// The meal types advertised to the model, kept in sync with `MealType` so
    /// a returned string always maps back to the enum.
    ///
    /// Forwards to `MealToolSchema` rather than rebuilding the list, so the
    /// composer and the chat / Shortcut tools offer the model the same four
    /// words (#546).
    private static var mealTypeList: String {
        MealToolSchema.mealTypeList
    }

    /// Build the estimation prompt.
    ///
    /// Note what is NOT asked for: meal totals, a suspect flag, a "does this add
    /// up" self-check. Every one of those is decided in Swift afterwards, in
    /// `MealEstimateGuards`. Prompts drift between model versions; code does
    /// not, and a guard the model grades itself against is not a guard.
    static func mealEstimationPrompt(
        description: String,
        photoCount: Int = 0,
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
            // Names the evidence that actually exists. A photo-only turn told to
            // infer the type "from the description" is being pointed at
            // something that is not in the prompt.
            let evidence = description.isEmpty ? "what you can see" : "the description"
            typeInstruction = """
            - "meal_type": one of \(mealTypeList). Infer it from \(evidence) \
            and from the local clock time, which is \(clock). A dish that is \
            eaten at any hour and gives no other signal is "snack".
            """
        }

        // What the model is being asked to read, which is not always the same
        // two things (#627). The opening sentence and the description paragraph
        // are written together here rather than patched independently, because
        // a prompt that announces a description and then encloses none is the
        // one shape that reliably makes a model invent the missing half.
        let hasPhotos = photoCount > 0
        let hasDescription = !description.isEmpty
        let photoNoun = photoCount == 1 ? "photograph" : "photographs"

        let opening: String
        switch (hasPhotos, hasDescription) {
        case (true, true):
            opening = """
            Estimate the nutrition of this meal from the attached \(photoNoun) \
            and the description below. Read both. Where they disagree the \
            description wins; see THE PHOTOGRAPH below.
            """
        case (true, false):
            opening = """
            Estimate the nutrition of this meal from the attached \(photoNoun). \
            The user typed nothing, so the \(photoNoun) and the clock are \
            everything you have; see THE PHOTOGRAPH below.
            """
        case (false, _):
            opening = "Estimate the nutrition of this meal from its description."
        }

        let descriptionBlock = hasDescription
            ? """


            The description, verbatim:
            \(description)
            """
            : ""

        return """
        \(opening) There is no portion picker and no serving dropdown, so every
        quantity you use is an assumption you must state. You have one lookup and
        only one: the web search tool, for a product a brand has published
        figures for. See BRAND LOOKUP below for when to reach for it and when
        not to.
        \(descriptionBlock)

        Return STRICT JSON inside a ```json fence and nothing else — no prose
        before or after.

        Schema:
        {
          "meal_type": "lunch",
          "title": "Eggs on toast and a flat white",
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
        \(MealToolSchema.estimateRules)
        \(hasPhotos ? MealToolSchema.photoRule : "")
        \(MealToolSchema.brandLookupRule)

        Do not invent fields. Do not add commentary outside the JSON fence.
        """
    }
}
