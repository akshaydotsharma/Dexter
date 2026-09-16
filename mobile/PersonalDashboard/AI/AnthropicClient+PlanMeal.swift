import Foundation

/// Everything one call returns about a meal somebody intends to eat (#599).
///
/// Three parts, and only the first of them is shared with the logging path.
/// `estimate` is an ordinary `CheckedMealEstimate`, produced by the SAME schema
/// and graded by the SAME guards a logged meal goes through. The other two are
/// plan-only, because they answer questions a log never asks: a logged meal has
/// already been shopped for and already been cooked.
struct PlannedMealEstimate: Sendable {
    /// The nutrition, decomposed and graded. `MealEstimateGuards` has already
    /// clamped it and may have flagged it.
    let estimate: CheckedMealEstimate

    /// The key ingredients, cleaned. Short by construction — see the tool
    /// description.
    let ingredients: [String]

    /// How to make it, one step per line, or nil when the model offered none.
    let recipe: String?
}

extension AnthropicClient {

    /// Estimate a meal the user is PLANNING to eat.
    ///
    /// ### Why this is a second call and not `estimateMeal`
    ///
    /// It is not a second ESTIMATOR, which is the thing this codebase pays for
    /// when it happens (#475, #500, #522). The schema for the dishes is
    /// `MealToolSchema.itemSchema` verbatim, the rules in the prompt are
    /// `MealToolSchema.estimateRules` verbatim, and the answer is graded by
    /// `MealEstimateGuards.check`, exactly like a logged meal. Change a rule
    /// there and it changes here.
    ///
    /// What differs is the two extra fields and one omission:
    ///
    /// 1. **Ingredients.** A plan is a thing you shop for. "Chicken rice" has to
    ///    become chicken, rice, ginger, cucumber before Thursday.
    /// 2. **A recipe.** A dish suggested on Sunday has to still be makeable on
    ///    Thursday by someone who has forgotten why they wrote it down.
    /// 3. **No web search.** `estimateMeal` declares the search server tool so a
    ///    BRANDED meal can be traced to a published panel, because its figures
    ///    are going into a day's totals. A plan's figures are going into a
    ///    forecast, and the meal gets estimated properly when it is actually
    ///    eaten, so a search here would double the cost of the cheapest
    ///    interaction in the feature to raise the precision of a number that is
    ///    about to be replaced.
    ///
    /// Exactly one API call, with no resume loop, because with no server tool
    /// declared there is no `pause_turn` to resume from.
    ///
    /// - Parameters:
    ///   - title: the dish, as the user typed it.
    ///   - mealType: which part of the day it is for. Always known here — the
    ///     block is being added to a named slot — so unlike the logging path
    ///     there is nothing for the model to infer and no clock to infer it
    ///     from.
    func planMeal(
        title: String,
        mealType: MealType
    ) async throws -> PlannedMealEstimate {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MealEstimationError.emptyDescription }

        let response = try await send(
            systemPrompt: AnthropicSystemPrompt(
                stable: Self.planMealSystemPrompt,
                volatile: nil
            ),
            messages: [
                AnthropicMessage(
                    role: "user",
                    content: [.text("\(mealType.displayName): \(trimmed)")]
                )
            ],
            tools: [Self.planMealTool],
            // The same 8192 `estimateMeal` uses, and for the same measured
            // reason: this model returns a `thinking` block, and thinking spends
            // the SAME budget the answer needs. A five-dish meal that also
            // carries a recipe needs the room (#543).
            maxTokens: 8192
        )

        // A truncated turn is a DIFFERENT failure from a malformed one, and
        // telling the user the reply was malformed when it was merely unfinished
        // makes "Try again" look like superstition (#543).
        if response.stop_reason == "max_tokens" { throw MealEstimationError.truncated }

        let input = response.content.compactMap { block -> [String: AnthropicJSONValue]? in
            guard case let .toolUse(_, name, input) = block, name == Self.planMealToolName else {
                return nil
            }
            return input
        }.first

        guard let input else { throw MealEstimationError.noJSON }

        let checked = MealEstimateGuards.check(
            MealToolSchema.estimatedMeal(from: input),
            fallbackMealType: mealType
        )

        let recipe = input["recipe"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return PlannedMealEstimate(
            estimate: checked,
            // The same cleaner the editor and the service use, so no two paths
            // disagree about what counts as a repeated ingredient.
            ingredients: MealPlanService.cleaned(
                (input["ingredients"]?.arrayValue ?? []).compactMap(\.stringValue)
            ),
            recipe: (recipe?.isEmpty ?? true) ? nil : recipe
        )
    }

    // MARK: - The tool

    static let planMealToolName = "plan_meal"

    /// One tool, called once. `tool_choice` is not set: the prompt says to call
    /// it every time, and a meal that names nothing edible is handled INSIDE the
    /// schema by `no_food_identified`, exactly as the logging path handles it.
    static let planMealTool = AnthropicTool(
        name: planMealToolName,
        description: """
        Break a planned meal down: its nutrition, its key ingredients, and how to make it.

        NUTRITION — follow these rules exactly:
        \(MealToolSchema.estimateRules)

        INGREDIENTS:
        - Three to six KEY ingredients, the ones that decide whether the meal can be \
        made. "chicken thigh, jasmine rice, cucumber, ginger", never every spice in the \
        pan and never salt, pepper, oil or water.
        - This is what the user shops from, so name things as they are BOUGHT: \
        "chicken thigh", not "diced marinated chicken".
        - Return an EMPTY array for a meal that is bought rather than cooked \
        ("lunch at the hawker centre", "Pret chicken caesar wrap"). An empty array is \
        the correct answer there; a made-up list is not.

        RECIPE:
        - Only when the meal is cooked AND the method is not obvious. Omit it for \
        anything bought, and for anything where the title is already the instruction \
        ("scrambled eggs on toast", "porridge with banana").
        - When you do give one: three to six steps, one per line, no numbering, no \
        quantities. Quantities live in the items above and would disagree with them.
        - This is a reminder for someone who liked the idea five days ago, not a recipe \
        card. Short.
        """,
        input_schema: .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "items": MealToolSchema.itemSchema,
                    "description": .string("One object per DISTINCT dish or drink in the meal.")
                ]),
                "ingredients": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Three to six KEY ingredients, as they are bought. Empty for a meal that is bought rather than cooked.")
                ]),
                "recipe": .object([
                    "type": .string("string"),
                    "description": .string("Three to six steps, one per line, no numbering and no quantities. Omit entirely when the method is obvious or the meal is bought.")
                ]),
                "contains_alcohol": .object([
                    "type": .string("boolean"),
                    "description": .string("True if any item is beer, wine, cider, a spirit or a mixed drink. It changes how the numbers are checked.")
                ]),
                "confidence": .object([
                    "type": .string("string"),
                    "enum": .array([.string("high"), .string("medium"), .string("low")]),
                    "description": .string("How sure you are about the PORTIONS specifically.")
                ]),
                "assumptions": .object([
                    "type": .string("string"),
                    "description": .string("One or two plain sentences naming what you assumed and the user never said.")
                ]),
                "no_food_identified": .object([
                    "type": .string("boolean"),
                    "description": .string("True, with an EMPTY items array, when the title names nothing edible. Do not invent a meal to fill the schema.")
                ])
            ]),
            "required": .array([.string("items")])
        ])
    )

    /// The system prompt. Short on purpose: every rule about the numbers is in
    /// the tool description, where it sits beside the schema it governs and
    /// cannot drift from it.
    static let planMealSystemPrompt = """
    You estimate meals the user is PLANNING to eat, inside their own meal-planning app.

    The user's message is a meal type and a dish they have typed into their plan for a \
    future day. Call the plan_meal tool exactly once and say nothing else. No prose, no \
    preamble, no confirmation: the app renders your answer, nobody reads a reply.

    These figures are a forecast, not a record. The meal gets estimated again properly \
    if and when it is actually eaten, so estimate a TYPICAL portion of the dish as \
    normally served, and do not ask for clarification you cannot receive — there is no \
    conversation here.
    """
}
