import Foundation

/// The ONE statement of what a meal estimate is, shared by every path that
/// asks a model for one (#546).
///
/// ### Why this file exists at all
///
/// #543 shipped one estimator: `AnthropicClient.mealEstimationPrompt` asks for a
/// fenced JSON object, `EstimatedMeal` decodes it, `MealEstimateGuards.check`
/// grades it, `MealEstimationService.save` writes it. #546 adds two more entry
/// points (chat and the Shortcut) that need the same answer from the same model
/// in a different envelope — a tool call instead of a fenced block.
///
/// The tempting shape is to restate the rules in the tool description. That is
/// a SECOND ESTIMATOR, and a second ingest path that drifts from the first is
/// the defect this repo has paid for in #475 (a two-leg ticket that only the
/// email path knew how to split), #500 (a boarding pass the Wallet attach path
/// decoded differently) and #522. The drift is invisible until one path gets a
/// fix the other never hears about.
///
/// So the rules are stated exactly once, here, and BOTH paths interpolate them:
/// the prompt inlines `estimateRules` into its Rules section, and the tools
/// inline the same string into their descriptions while their input schema is
/// built from `itemSchema`. A rule changed here changes in both places or in
/// neither. The answer then lands in the same `EstimatedMeal`, runs through the
/// same `MealEstimateGuards.check`, and is written by the same
/// `MealEstimationService.save`.
enum MealToolSchema {

    // MARK: - The rules, stated once

    /// Everything the model is told about an estimate EXCEPT which meal type to
    /// pick, which differs per path (the composer hints it, a tool takes it as a
    /// parameter).
    ///
    /// Verbatim from #543's prompt. Do not paraphrase it into a tool
    /// description: paraphrasing is how the two paths start to disagree.
    static let estimateRules = """
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
    """

    /// When to look a product up instead of remembering it, stated once (#594).
    ///
    /// Kept apart from `estimateRules` for one reason: `estimateRules` reaches
    /// all three paths and this rule must reach only the two that can actually
    /// search. The Shortcut declares no web-search tool, because it runs under a
    /// hard 22 s timeout and writes without a preview, and telling a model to
    /// search when it has nothing to search with is how a capture turns into an
    /// apology instead of a meal.
    ///
    /// So this string is interpolated by the composer's prompt and by
    /// `promptSection(canAskQuestions:canSearchWeb:)` when the path can search,
    /// and by nothing else. It is still stated exactly ONCE, which is the whole
    /// point of this file: a second copy in a tool description is the drift
    /// #475 and #500 each cost a release.
    static let brandLookupRule = """
    - BRAND LOOKUP. When the description names a brand, a restaurant chain or a
      packaged supermarket product ("Guzman y Gomez chicken burrito bowl", "a
      Big Mac", "Chobani 0% vanilla", "a grande Starbucks latte"), search the
      web for that product's PUBLISHED nutrition before you estimate, and build
      the item from the figures you find. A branded description looks specific,
      so a figure you recalled reads as a figure you looked up. That is the
      worst kind of wrong number: it invites more trust than a guess and gives
      the user nothing to check it against.
    - Prefer the brand's own published figures. Where the brand publishes
      nothing readable, an established nutrition database is an acceptable
      source. Name in "assumptions" which one you used, because "the chain
      says" and "a database says" are different claims and the user is
      entitled to know which one they are reading.
    - Do NOT search for generic food: "two eggs on toast", "chicken rice", "a
      flat white", "dal and two rotis". There is no published panel to find, a
      search costs money and seconds on every meal, and the portion is what
      decides the answer anyway.
    - A published panel is stated per serving or per 100 g, and the user
      described a portion. Scale the panel to the portion, and say in
      "assumptions" which serving you scaled from. The panel is a fact and the
      portion is still your assumption; do not let the first one dress up the
      second.
    - When the search finds nothing, or the brand publishes nothing for that
      item, estimate the way you would without it and say so in "assumptions".
      Never present a figure you reasoned out as one a brand published.
    """

    /// The meal types advertised to the model, kept in sync with `MealType` so a
    /// returned string always maps back to the enum.
    static var mealTypeList: String {
        MealType.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }

    // MARK: - The system-prompt section

    /// The meal-logging block both orchestrator prompts embed.
    ///
    /// One string for two prompts, for the same reason the rules above are one
    /// string for two paths: `ChatStream` and `ChatToDrafts` already carry a
    /// near-identical prompt as a deliberate duplicate, and letting the meal
    /// rules diverge across that seam is how the Shortcut quietly stops
    /// resolving "last night" a year after chat learns to.
    ///
    /// - Parameter canAskQuestions: true for chat, where a clarifying question
    ///   reaches a human. False for the Shortcut, which has no conversation:
    ///   every branch that would ask there has to resolve without one and say
    ///   what it did, because a silent success is how a day quietly ends up
    ///   half logged.
    /// - Parameter canSearchWeb: true when this path's request declares the
    ///   web-search server tool, which chat does and the Shortcut does not
    ///   (#594). The two are separate flags rather than one "is this chat"
    ///   switch because they answer different questions, and a path could
    ///   plausibly gain one without the other.
    static func promptSection(canAskQuestions: Bool, canSearchWeb: Bool) -> String {
        let vagueRule = canAskQuestions
            ? """
              - A description too vague to estimate ("I had food", "lunch", "something from the canteen") gets NO tool call. Ask exactly ONE short question naming what you need ("What did you have for lunch?") and stop. Do not log a placeholder meal.
            """
            : """
              - A description too vague to estimate ("I had food", "lunch", "something from the canteen") still gets a log_meal call, with an EMPTY items array and no_food_identified true. You cannot ask a question here — there is nobody to answer it — and the fact that they ate is worth keeping even when the number is not recoverable. Never invent numbers to fill the gap.
            """

        let lookupRule = canSearchWeb ? "\n\(brandLookupRule)" : ""

        return """
        MEAL LOGGING (log_meal / update_meal / delete_meal):
        - Any report of eating or drinking is a log_meal call: "two eggs on toast for breakfast", "just had a flat white", "I had pasta last night".
        - ONE CALL PER MEAL. "For breakfast I had X and for lunch Y" is TWO log_meal calls, each with its own fresh id and its own meal_type.
        - Every log_meal carries a FRESH lowercase UUID in `id`. Never reuse an id from the MEALS TODAY context for a new meal — that would rewrite the meal it names.
        - `date` is the day the meal was EATEN. Resolve "yesterday", "last night", "on Tuesday" to an ISO date yourself, the same way you resolve a date for add_expense. Default to today. NEVER emit a future date: a meal is a record of something already eaten, and the device will pull a future date back to today and say so.
        - A meal logged in the small hours stays on TODAY unless the user says otherwise. Do not silently move a 01:30 snack to yesterday; the device offers the user that choice on the card. Guessing wrong there is invisible and unfixable.
        - A correction to a meal already in the MEALS TODAY context is update_meal with that meal's UUID, never a second log_meal. "That latte was oat milk" corrects the latte. Re-estimate the WHOLE meal and return the complete items array.
        - delete_meal removes a meal entirely. Use it only when the user wants the record gone, not when they want it corrected.
        \(vagueRule)\(lookupRule)
        - Answer "how many calories do I have left" and "am I short on protein this week" from the MEALS TODAY block in plain text. Do not call a tool to read.
        """
    }

    // MARK: - The tool input schema

    /// One estimated dish, as a JSON Schema object.
    ///
    /// Key names are `EstimatedMealItem.CodingKeys` verbatim, which is what lets
    /// `estimatedMeal(from:)` hand the tool's own payload to the decoder the
    /// fenced-JSON path already uses.
    static let itemSchema: AnthropicJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("The dish or drink, e.g. \"Poached egg\" or \"Flat white\".")
            ]),
            "portion_quantity": .object([
                "type": .string("number"),
                "description": .string("TOTAL amount of this item in the meal, in portion_unit. Required, never null, always greater than zero.")
            ]),
            "portion_unit": .object([
                "type": .string("string"),
                "description": .string("Exactly \"g\" or \"ml\". Never a household measure.")
            ]),
            "calories": number("Calories for this item at this portion, in kcal."),
            "protein_g": number("Protein for this item at this portion, in grams."),
            "carbs_g": number("Carbohydrate for this item at this portion, in grams."),
            "fat_g": number("Fat for this item at this portion, in grams."),
            "fibre_g": number("Fibre for this item at this portion, in grams."),
            "sugar_g": number("Sugar for this item at this portion, in grams."),
            "sodium_mg": number("Sodium for this item at this portion, in MILLIGRAMS."),
            "saturated_fat_g": number("Saturated fat for this item at this portion, in grams.")
        ]),
        "required": .array([
            .string("name"), .string("portion_quantity"), .string("portion_unit"),
            .string("calories"), .string("protein_g"), .string("carbs_g"),
            .string("fat_g"), .string("fibre_g"), .string("sugar_g"),
            .string("sodium_mg"), .string("saturated_fat_g")
        ])
    ])

    private static func number(_ description: String) -> AnthropicJSONValue {
        .object([
            "type": .string("number"),
            "description": .string(description)
        ])
    }

    // MARK: - Tool input → the shared estimate type

    /// Rebuild an `EstimatedMeal` from a `log_meal` / `update_meal` tool input.
    ///
    /// Deliberately lands on the SAME struct the fenced-JSON path decodes into,
    /// so `MealEstimateGuards.check` is the only grader either path ever meets.
    /// Nothing is validated here: a missing portion, a negative gram, an
    /// implausible total and an empty items array are all the guards' business,
    /// and duplicating any of that judgement here would be the second estimator
    /// this file exists to prevent.
    static func estimatedMeal(from input: [String: AnthropicJSONValue]) -> EstimatedMeal {
        let rawItems = input["items"]?.arrayValue ?? []
        let items = rawItems.compactMap { entry -> EstimatedMealItem? in
            guard let dict = entry.objectValue else { return nil }
            return EstimatedMealItem(
                name: dict["name"]?.stringValue,
                portionQuantity: numberValue(dict["portion_quantity"]),
                portionUnit: dict["portion_unit"]?.stringValue,
                calories: numberValue(dict["calories"]),
                proteinG: numberValue(dict["protein_g"]),
                carbsG: numberValue(dict["carbs_g"]),
                fatG: numberValue(dict["fat_g"]),
                fibreG: numberValue(dict["fibre_g"]),
                sugarG: numberValue(dict["sugar_g"]),
                sodiumMg: numberValue(dict["sodium_mg"]),
                satFatG: numberValue(dict["saturated_fat_g"])
            )
        }

        let assumptions = input["assumptions"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return EstimatedMeal(
            mealType: input["meal_type"]?.stringValue,
            items: items,
            containsAlcohol: boolValue(input["contains_alcohol"]),
            confidence: input["confidence"]?.stringValue,
            assumptions: (assumptions?.isEmpty ?? true) ? nil : assumptions,
            noFoodIdentified: boolValue(input["no_food_identified"])
        )
    }

    /// True when the caller supplied an `items` key at all, whatever is in it.
    ///
    /// The difference between "the model said this meal has no identifiable
    /// food" (an empty array, a real answer) and "the model did not re-estimate"
    /// (no key) matters on the update path only, where the second must not be
    /// allowed to wipe a good estimate down to zeros.
    static func carriesItems(_ input: [String: AnthropicJSONValue]) -> Bool {
        input["items"]?.arrayValue != nil
    }

    /// Tolerate a JSON number or a numeric string. Both shapes have shown up in
    /// practice on the expense tools, and a nutrient parsed as nil is a nutrient
    /// stored as zero.
    private static func numberValue(_ value: AnthropicJSONValue?) -> Double? {
        if let d = value?.doubleValue { return d }
        if let s = value?.stringValue, let d = Double(s) { return d }
        return nil
    }

    private static func boolValue(_ value: AnthropicJSONValue?) -> Bool? {
        if let b = value?.boolValue { return b }
        guard let s = value?.stringValue?.lowercased() else { return nil }
        if s == "true" { return true }
        if s == "false" { return false }
        return nil
    }

    // MARK: - Dates

    /// What a resolved meal day is, and how it got that way.
    struct ResolvedDay: Equatable, Sendable {
        /// The device-local day the meal belongs to. Pass it straight to
        /// `MealService`, which anchors it.
        let day: Date
        /// The model emitted a date in the future and it was pulled back to
        /// today. Surfaced on the card, never silent.
        let wasClampedFromFuture: Bool
    }

    /// Resolve the tool's `date` parameter to the day the meal counts towards.
    ///
    /// Two rules, both about the same failure: a misdated meal corrupts two days
    /// at once and neither one looks wrong.
    ///
    /// 1. An unparseable or absent date falls back to `fallback` (today on the
    ///    log path, the row's existing day on the update path). Never to nil:
    ///    a meal with no day cannot be counted.
    /// 2. A date in the FUTURE clamps to today, and the caller is told so. A
    ///    meal is a record of something eaten, so a future date is always a
    ///    model error — usually a year typo or a relative date resolved the
    ///    wrong way — and storing it hides the meal in a day nobody looks at.
    ///
    /// Comparison is day-to-day, not instant-to-instant, so a meal dated today
    /// at 23:00 in a zone ahead of the device is today, not "the future".
    static func resolveDay(
        isoDate raw: String?,
        now: Date = Date(),
        fallback: Date? = nil
    ) -> ResolvedDay {
        let today = WallClock.dayAnchor(from: now)
        let parsed = parseDay(raw)
        let candidate = parsed ?? fallback ?? now
        let anchored = WallClock.dayAnchor(from: candidate)

        if WallClock.startOfStoredDay(anchored) > today {
            // Only a date the MODEL supplied can be clamped. A stored fallback
            // that is somehow in the future is not this call's business.
            return ResolvedDay(day: now, wasClampedFromFuture: parsed != nil)
        }
        return ResolvedDay(day: candidate, wasClampedFromFuture: false)
    }

    /// Parse the `date` parameter. Accepts a bare `yyyy-MM-dd` and a full ISO
    /// datetime with or without fractional seconds, the three shapes the model
    /// emits for a day-level field.
    static func parseDay(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        if let d = dateOnlyUTC.date(from: trimmed) { return d }
        if let d = iso8601Fractional.date(from: trimmed) { return d }
        if let d = iso8601.date(from: trimmed) { return d }
        return nil
    }

    // MARK: - The small-hours rule

    /// The hour, exclusive, below which a dinner or a snack is offered to
    /// yesterday. 04:00 — by then it is morning by any reading.
    static let smallHoursCutoff = 4

    /// Should this meal offer a one-tap move to yesterday?
    ///
    /// A dinner or a snack logged between 00:00 and 03:59, dated today, almost
    /// always belongs to the day that just ended. It is offered and NEVER moved
    /// automatically, and the asymmetry is the whole point: a 1am snack moved
    /// wrongly is invisible (nothing on either day looks odd) and unfixable
    /// (the user has no reason to go looking). An offer declined costs one tap.
    ///
    /// Breakfast and lunch are excluded because a 01:30 breakfast is a stated
    /// intention, not an ambiguity.
    static func offersYesterdayMove(
        mealType: MealType,
        day: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard mealType == .dinner || mealType == .snack else { return false }
        let hour = calendar.component(.hour, from: now)
        guard hour < smallHoursCutoff else { return false }
        return WallClock.isSameStoredDay(
            WallClock.dayAnchor(from: day),
            WallClock.dayAnchor(from: now)
        )
    }

    // MARK: - Formatters

    private static let dateOnlyUTC: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
