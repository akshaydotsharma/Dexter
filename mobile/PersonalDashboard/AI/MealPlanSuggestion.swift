import Foundation

/// One meal the plan chat has proposed (#599).
///
/// ### It is a proposal and never a write
///
/// Nothing in this feature turns a suggestion into a block on its own. The user
/// asked to "chat through different messages on what I can have" and then
/// decide, so the chat has exactly one tool and that tool PROPOSES. There is no
/// `add_to_plan` tool and there must not be one: a model that could write to the
/// calendar would fill days the user was only thinking out loud about, and the
/// undo for that is deleting blocks one at a time.
///
/// This is the same line `ChatDraft` draws on the main chat surface, one notch
/// stricter. That surface auto-executes its non-destructive drafts; this one
/// executes nothing, because every suggestion here is about a day that has not
/// happened yet and being wrong costs the user a plan rather than a record.
///
/// ### Why its numbers are weaker than a logged meal's
///
/// These figures describe a meal nobody has eaten, estimated without a portion
/// anyone has seen. They are good enough to answer "will this day land near my
/// targets" and they are NOT the meal's real numbers. When the meal actually
/// happens it goes through the composer on Tracking like any other, which
/// re-estimates it from what was actually eaten. So a block made from a
/// suggestion carries `MealPlanSource.chat`, and the card that offers it says
/// the numbers are rough.
struct MealPlanSuggestion: Identifiable, Equatable, Hashable, Sendable {

    /// Minted on arrival, for a list row and for the "added" state. Never the
    /// model's — it does not mint one, and it should not: nothing about this
    /// value is persisted under this id.
    let id: UUID

    /// The meal, as it would read on a block.
    let title: String

    /// Which part of the day it is for.
    let mealType: MealType

    /// The main ingredients, already cleaned. Short by construction — see the
    /// tool description.
    let ingredients: [String]

    /// One line on why this meal, in the model's own words. Shown under the
    /// title, and NOT carried onto the block: it is an argument for a choice,
    /// and once the choice is made it stops being true of the plan.
    let why: String?

    /// The rough estimate, or nil when the model offered none. Nil rather than
    /// zeros, so a block made from it carries no numbers instead of claiming a
    /// fast.
    let nutrients: MealNutrients?

    /// Anything to do ahead of time: soak, marinate, defrost. Carried ONTO the
    /// block as its note, because unlike `why` it stays true after the choice.
    let prepNote: String?

    init(
        id: UUID = UUID(),
        title: String,
        mealType: MealType,
        ingredients: [String] = [],
        why: String? = nil,
        nutrients: MealNutrients? = nil,
        prepNote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.mealType = mealType
        self.ingredients = ingredients
        self.why = why
        self.nutrients = nutrients
        self.prepNote = prepNote
    }

    /// Rebuild a suggestion from a `suggest_meal` tool input.
    ///
    /// Returns nil when there is no title, which is the one field nothing can
    /// stand in for: a card with no meal on it is not a suggestion the user can
    /// act on, and rendering an empty row would read as a bug in the chat.
    /// Everything else degrades instead of failing — a missing meal type falls
    /// back, missing ingredients read as none, missing numbers read as nil.
    ///
    /// Nothing is validated beyond that. A negative gram is caught by
    /// `MealPlanService`, which refuses it on the write, so grading it twice
    /// would put the same judgement in two places that can disagree.
    static func from(
        toolInput input: [String: AnthropicJSONValue],
        fallbackMealType: MealType
    ) -> MealPlanSuggestion? {
        let title = (input["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let mealType = input["meal_type"]?.stringValue
            .flatMap { MealType(rawValue: $0.lowercased()) } ?? fallbackMealType

        let ingredients = MealPlanService.cleaned(
            (input["ingredients"]?.arrayValue ?? []).compactMap(\.stringValue)
        )

        return MealPlanSuggestion(
            title: title,
            mealType: mealType,
            ingredients: ingredients,
            why: trimmedNonEmpty(input["why"]?.stringValue),
            nutrients: nutrients(from: input),
            prepNote: trimmedNonEmpty(input["prep_note"]?.stringValue)
        )
    }

    /// The eight, or nil.
    ///
    /// Keys on the PRESENCE of `calories` rather than on its value. A model that
    /// offered no numbers and a model that said zero are two different answers,
    /// and only one of them means "I did not estimate this". Treating a stated
    /// zero as an absence would also be wrong in the other direction on the day
    /// somebody plans a fast.
    private static func nutrients(from input: [String: AnthropicJSONValue]) -> MealNutrients? {
        guard let calories = input["calories"]?.doubleValue else { return nil }
        return MealNutrients(
            calories: calories,
            proteinG: input["protein_g"]?.doubleValue ?? 0,
            carbsG: input["carbs_g"]?.doubleValue ?? 0,
            fatG: input["fat_g"]?.doubleValue ?? 0,
            fibreG: input["fibre_g"]?.doubleValue ?? 0,
            sugarG: input["sugar_g"]?.doubleValue ?? 0,
            sodiumMg: input["sodium_mg"]?.doubleValue ?? 0,
            satFatG: input["saturated_fat_g"]?.doubleValue ?? 0
        )
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
