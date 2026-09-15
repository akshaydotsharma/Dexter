import Foundation

/// One dish inside a logged meal (#542).
///
/// Stored as JSON inside `LocalMeal.itemsData`, the same shape decision
/// `ExpenseSplitEntry` / `LocalExpense.splitsData` and `VisionItem` /
/// `LocalVisionBlock.notesData` already make: SwiftData on iOS 17.0 will not
/// persist an array without a custom transformer, and a blob with a computed
/// accessor is the pattern this codebase trusts. It also means an item can gain
/// a field without a schema migration on a live store.
///
/// ### Why an item carries its own eight values
///
/// The meal's eight totals are not a derived sum that can be recomputed on
/// demand, because the split across items is a guess: "chicken rice and a teh
/// tarik" is one description that an estimate breaks into two dishes, and the
/// user can correct one of them without re-estimating the other. Keeping each
/// item's own numbers is what makes "the rice was actually double" a local
/// edit. The meal's totals stay the stored truth for every roll-up, so a
/// display never has to sum items to draw a day.
///
/// ### Why the portion is a number and a unit, not a string
///
/// The portion is an ASSUMPTION the estimate made ("1 bowl", "250 g"), and it is
/// the single most common thing a user corrects. Splitting it into a quantity
/// and a unit means a correction can scale the item's eight values by a ratio
/// rather than asking for a fresh estimate. A free-text "about a bowl and a
/// bit" cannot be scaled by anything.
struct MealItemEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable id for a list row and for an editor's selection. Minted on
    /// creation and carried through the JSON, so re-decoding a meal does not
    /// reshuffle identity under an open editor.
    let id: UUID

    /// The dish as named by the estimate, e.g. "Hainanese chicken rice".
    var name: String

    /// How much of it was assumed. Paired with `portionUnit`; never a string.
    var portionQuantity: Double

    /// The unit `portionQuantity` is in, verbatim as the estimate stated it
    /// ("bowl", "g", "slice", "cup"). Free text on purpose: a closed unit enum
    /// would force every real-world portion through a vocabulary that does not
    /// fit it, and nothing computes on the unit except the scaling ratio, which
    /// only needs the unit to stay the same between the two sides.
    var portionUnit: String

    /// This item's own share of the eight. Units per `Nutrient.unit`: kcal for
    /// calories, mg for sodium, grams for the rest.
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    init(
        id: UUID = UUID(),
        name: String,
        portionQuantity: Double = 1,
        portionUnit: String = "serving",
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0
    ) {
        self.id = id
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

    /// Decode tolerantly: an item written by a build that did not mint ids, or
    /// one hand-authored in a fixture, still reads rather than failing the whole
    /// meal. A missing id means a new one, which is correct for a value that
    /// only ever identifies a row within one decoded array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        portionQuantity = try container.decodeIfPresent(Double.self, forKey: .portionQuantity) ?? 1
        portionUnit = try container.decodeIfPresent(String.self, forKey: .portionUnit) ?? "serving"
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        proteinG = try container.decodeIfPresent(Double.self, forKey: .proteinG) ?? 0
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG) ?? 0
        fatG = try container.decodeIfPresent(Double.self, forKey: .fatG) ?? 0
        fibreG = try container.decodeIfPresent(Double.self, forKey: .fibreG) ?? 0
        sugarG = try container.decodeIfPresent(Double.self, forKey: .sugarG) ?? 0
        sodiumMg = try container.decodeIfPresent(Double.self, forKey: .sodiumMg) ?? 0
        satFatG = try container.decodeIfPresent(Double.self, forKey: .satFatG) ?? 0
    }

    /// The portion as one readable phrase, e.g. "1 bowl" or "250 g". Whole
    /// numbers print without a decimal point, because "1.0 bowl" reads as a
    /// measurement nobody made.
    var portionDescription: String {
        let quantity = portionQuantity.rounded() == portionQuantity
            ? String(Int(portionQuantity))
            : String(format: "%.1f", portionQuantity)
        return portionUnit.isEmpty ? quantity : "\(quantity) \(portionUnit)"
    }

    /// This item's value for one nutrient. The one accessor every bar, verdict
    /// and callout reads, so a surface never has to switch on eight fields.
    func value(for nutrient: Nutrient) -> Double {
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
