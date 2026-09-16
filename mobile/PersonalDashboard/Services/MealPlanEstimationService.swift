import Foundation
import SwiftData

/// Everything between "the user typed a dish into a slot" and "a block exists"
/// (#599).
///
/// The plan-side twin of `MealEstimationService`, and split the same way: the
/// one API call lives here, and so does every write path that does NOT make one.
/// That split is the lever on what the feature costs — a block copied from
/// another day, a title corrected without re-estimating, a set of numbers typed
/// by hand are all free.
@MainActor
struct MealPlanEstimationService {
    let client: AnthropicClient
    let plans: MealPlanService

    init(client: AnthropicClient = AnthropicClient(), plans: MealPlanService) {
        self.client = client
        self.plans = plans
    }

    static func `default`() -> MealPlanEstimationService {
        MealPlanEstimationService(plans: .default())
    }

    // MARK: - The one call

    /// Estimate a planned dish: its nutrition, its key ingredients, its recipe.
    ///
    /// Exactly one API call. The guards run inside `AnthropicClient.planMeal`
    /// and add none of their own — they are arithmetic over what came back.
    ///
    /// Nothing is written here. The caller shows the answer, the user confirms
    /// it, and `save` does the write. That order is the whole reason a plan can
    /// be corrected before it exists rather than after.
    func estimate(title: String, mealType: MealType) async throws -> PlannedMealEstimate {
        try await client.planMeal(title: title, mealType: mealType)
    }

    // MARK: - Writes

    /// Write an estimated plan as a block.
    ///
    /// Passing `clientUUID` makes this a correction of the block that id names
    /// rather than a second block — the identity contract `MealPlanService`
    /// already holds (#514). The re-estimate path uses it; the add path does not.
    ///
    /// A needs-detail estimate saves with NO numbers rather than with zeros. The
    /// model could not name a food, and eight zeros would claim it had named a
    /// fast. `MealPlanDay` then counts the block as one it has no numbers for,
    /// which is exactly what it is.
    @discardableResult
    func save(
        _ planned: PlannedMealEstimate,
        title: String,
        day: Date,
        mealType: MealType? = nil,
        notes: String? = nil,
        status: MealPlanStatus = .planned,
        source: String = MealPlanSource.manual,
        clientUUID: String? = nil
    ) throws -> LocalMealPlanEntry {
        try plans.addEntry(
            date: day,
            mealType: mealType ?? planned.estimate.mealType,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ingredients: planned.ingredients,
            notes: notes,
            recipe: planned.recipe,
            status: status,
            nutrients: planned.estimate.needsDetail ? nil : planned.estimate.nutrients,
            items: planned.estimate.items,
            source: source,
            clientUUID: clientUUID
        )
    }

    /// Re-total a block from its items, in Swift.
    ///
    /// No API call. Correcting a portion is arithmetic over numbers the estimate
    /// already gave, and asking the model again would re-guess the components
    /// the user did not touch — the same call `MealEstimationService` makes.
    ///
    /// The guards run again, so a block that was flagged for a reason the edit
    /// has fixed stops being flagged. Nothing on a PLAN acts on that flag today,
    /// which is why it is not stored: the block is re-graded so its numbers stay
    /// coherent, not so a badge can be drawn.
    func recomputeTotals(of entry: LocalMealPlanEntry, from items: [MealItemEntry]) throws {
        let result = MealEstimateGuards.recheckHandEdited(
            items: items,
            // A planned block carries no alcohol flag of its own. `false` is the
            // conservative reading: it leaves the macro consistency check ON, so
            // a genuinely incoherent edit is still clamped. The cost is that a
            // planned beer's calories may be clamped toward its macros, on a
            // forecast that gets re-estimated when the drink is actually logged.
            containsAlcohol: false
        )
        try plans.updateEntry(entry, nutrients: .some(result.totals), items: result.items)
    }
}
